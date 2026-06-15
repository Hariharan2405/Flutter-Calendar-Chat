import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import '../widgets/link_preview_widget.dart';
import '../widgets/voice_message_player.dart';
import '../widgets/voice_preview_sheet.dart';
import '../widgets/gif_picker_sheet.dart';
import '../widgets/sticker_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:video_compress/video_compress.dart';

import '../constants/app_theme.dart';
import '../models/group_model.dart';
import '../models/message_model.dart';
import '../providers/app_provider.dart';
import '../services/chat_service.dart';
import '../services/group_chat_service.dart';
import '../utils/snack_util.dart';
import 'group_info_screen.dart';

// Set while a GroupChatScreen is on screen — used by AppProvider to suppress
// group notification banners for the currently open group.
class ActiveGroupChatTracker {
  static String? activeGroupId;
}

// ── Pending message ───────────────────────────────────────────────────────────

enum _PendingStatus { sending, failed }

class _PendingItem {
  final String id;
  final MessageType type;
  final File? localFile;
  final int? voiceDuration;
  final String? text;
  final String? gifUrl;
  final String? sticker;
  _PendingStatus status = _PendingStatus.sending;
  _PendingItem({
    required this.id,
    required this.type,
    this.localFile,
    this.voiceDuration,
    this.text,
    this.gifUrl,
    this.sticker,
  });
}

// ── Screen ────────────────────────────────────────────────────────────────────

class GroupChatScreen extends StatefulWidget {
  final String groupId;
  final String currentUid;
  final String initialName;

  const GroupChatScreen({
    super.key,
    required this.groupId,
    required this.currentUid,
    required this.initialName,
  });

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final GroupChatService _service = GroupChatService();
  final TextEditingController _textCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _textFocus = FocusNode();
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  final ImagePicker _imagePicker = ImagePicker();

  late Stream<List<MessageModel>> _messagesStream;
  late Stream<GroupModel?> _groupStream;

  GroupModel? _group;
  StreamSubscription<GroupModel?>? _groupSub;

  final List<_PendingItem> _pending = [];

  bool _isRecording = false;
  bool _showEmojiPicker = false;
  String? _recordingPath;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;

  MessageModel? _replyingTo;
  final ValueNotifier<String?> _playingNotifier = ValueNotifier(null);
  final ValueNotifier<bool> _isPlayingNotifier = ValueNotifier(false);
  final ValueNotifier<Duration> _positionNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration?> _durationNotifier = ValueNotifier(null);
  int? _prevMsgCount;

  // ── Pagination ─────────────────────────────────────────────────────────────
  final List<MessageModel> _olderMessages = [];
  final Set<String> _loadedOlderIds = {};
  bool _hasMore = true;
  bool _isLoadingMore = false;
  // Kept up-to-date by the StreamBuilder; used for auto-play (ascending = oldest first).
  List<MessageModel> _allMessages = [];

  // Chat background — sourced from Firestore so every member sees the same
  static const _defaultBgColor = Color(0xFFF0EDF8);
  static const _bgColors = [
    Color(0xFFF0EDF8), Colors.white,   Color(0xFFE8F5E9), Color(0xFFE3F2FD),
    Color(0xFFFFF8E1), Color(0xFFFCE4EC), Color(0xFFEDE7F6), Color(0xFFE0F7FA),
    Color(0xFF1A1A2E), Color(0xFF2D2D44),
  ];
  bool _uploadingBg = false;

  // Name/photo cache so we don't re-query per bubble
  final Map<String, String> _nameCache = {};
  final Map<String, String?> _photoCache = {};
  List<String> _lastKnownParticipants = []; // to avoid re-loading names on every group update

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    ActiveGroupChatTracker.activeGroupId = widget.groupId;
    // User opened a group chat room — dismiss any lingering notification banner.
    AppProvider.dismissBanner?.call();
    _messagesStream = _service.messages(widget.groupId);
    _groupStream = _service.watchGroup(widget.groupId);
    _groupSub = _groupStream.listen((g) {
      if (mounted && g != null) {
        setState(() => _group = g);
        // Only reload member names when the participant list actually changes —
        // group updates (last message, background, etc.) fire frequently and
        // each previously triggered a full profile fetch for every member.
        if (!_sameParticipants(g.participants, _lastKnownParticipants)) {
          _lastKnownParticipants = List.from(g.participants);
          _loadMemberNames(g.participants);
        }
      }
    });
    _service.markRead(widget.groupId, widget.currentUid);
    // Pre-populate _streamOldest from the stream's first emission so that
    // the load-more button works immediately without waiting for a full build.
    _messagesStream.first.then((msgs) {
      if (mounted && msgs.isNotEmpty) {
        _streamOldest = msgs.first.timestamp;
      }
    }).ignore();
    // Dismiss emoji picker when the system keyboard opens
    _textFocus.addListener(() {
      if (_textFocus.hasFocus && _showEmojiPicker) {
        setState(() => _showEmojiPicker = false);
      }
    });
    // Load more when approaching the top (pixels near maxScrollExtent in reverse list)
    _scrollCtrl.addListener(_onScroll);
    _player.onPositionChanged.listen((pos) { _positionNotifier.value = pos; });
    _player.onDurationChanged.listen((dur) { _durationNotifier.value = dur; });
    _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      final justFinished = _playingNotifier.value;
      _playingNotifier.value = null;
      _isPlayingNotifier.value = false;
      _positionNotifier.value = Duration.zero;
      _durationNotifier.value = null;
      _autoPlayNext(justFinished);
    });
  }

  @override
  void dispose() {
    ActiveGroupChatTracker.activeGroupId = null;
    _service.markRead(widget.groupId, widget.currentUid).ignore();
    _groupSub?.cancel();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _textFocus.dispose();
    _recorder.dispose();
    _player.dispose();
    _playingNotifier.dispose();
    _isPlayingNotifier.dispose();
    _positionNotifier.dispose();
    _durationNotifier.dispose();
    _recordingTimer?.cancel();
    super.dispose();
  }

  // ── Background ────────────────────────────────────────────────────────────

  Future<void> _loadMemberNames(List<String> uids) async {
    final service = ChatService();
    bool changed = false;
    for (final uid in uids) {
      // Skip if we already have a real name (not the fallback UID string).
      if (_nameCache[uid] != null && _nameCache[uid] != uid) continue;
      final profile = await service.getUserProfile(uid);
      if (profile != null) {
        _nameCache[uid] = profile.name;
        _photoCache[uid] = profile.photoUrl;
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
  }

  Future<void> _setBgColor(Color color) async {
    await _service.updateGroupBackground(
      widget.groupId,
      colorValue: color.toARGB32(),
    );
  }

  Future<void> _setBgImage(String localPath) async {
    if (_uploadingBg) return;
    setState(() => _uploadingBg = true);
    try {
      final url = await _service.uploadGroupBackground(
          widget.groupId, File(localPath));
      await _service.updateGroupBackground(
          widget.groupId, imageUrl: url);
    } catch (_) {
      if (mounted) context.showError('Failed to upload background');
    } finally {
      if (mounted) setState(() => _uploadingBg = false);
    }
  }

  Future<void> _resetBackground() =>
      _service.updateGroupBackground(widget.groupId);

  void _showBackgroundPicker() {
    final currentColorVal = _group?.backgroundColor;
    final hasImage        = _group?.backgroundImageUrl != null;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('Chat Background',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 10, runSpacing: 10,
                children: _bgColors.map((c) {
                  final argb = c.toARGB32();
                  final selected = !hasImage && (
                      currentColorVal == argb ||
                      (currentColorVal == null && argb == _defaultBgColor.toARGB32()));
                  return GestureDetector(
                    onTap: () { Navigator.pop(ctx); _setBgColor(c); },
                    child: Container(
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                        color: c, shape: BoxShape.circle,
                        border: Border.all(
                          color: selected ? AppColors.primary : Colors.grey.shade300,
                          width: selected ? 3 : 1.5,
                        ),
                      ),
                      child: selected
                          ? const Icon(Icons.check, size: 18, color: AppColors.primary)
                          : null,
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton.icon(
                  icon: _uploadingBg
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.photo_library_rounded),
                  label: const Text('Gallery'),
                  onPressed: _uploadingBg ? null : () async {
                    Navigator.pop(ctx);
                    final file = await _imagePicker.pickImage(
                        source: ImageSource.gallery);
                    if (file != null) _setBgImage(file.path);
                  },
                ),
                TextButton.icon(
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Reset'),
                  onPressed: () { Navigator.pop(ctx); _resetBackground(); },
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  // ── Mute toggle ───────────────────────────────────────────────────────────

  void _toggleMute() {
    final provider = context.read<AppProvider>();
    provider.setGroupMuted(widget.groupId, !provider.isGroupMuted(widget.groupId));
    context.showSuccess(provider.isGroupMuted(widget.groupId)
        ? 'Notifications muted'
        : 'Notifications unmuted');
  }

  // ── Audio player ──────────────────────────────────────────────────────────

  Future<void> _togglePlay(MessageModel msg) async {
    if (_playingNotifier.value == msg.id) {
      if (_isPlayingNotifier.value) {
        await _player.pause();
        _isPlayingNotifier.value = false;
      } else {
        await _player.resume();
        _isPlayingNotifier.value = true;
      }
    } else {
      _positionNotifier.value = Duration.zero;
      _durationNotifier.value = null;
      _playingNotifier.value = msg.id;
      _isPlayingNotifier.value = true;
      await _player.play(UrlSource(msg.audioUrl!));
    }
  }

  // Auto-play: after a voice message ends, find the next non-mine voice message
  // and start it automatically. _allMessages is ascending (index 0 = oldest),
  // so "next in time" means searching toward higher indices.
  void _autoPlayNext(String? finishedId) {
    if (finishedId == null) return;
    final idx = _allMessages.indexWhere((m) => m.id == finishedId);
    if (idx < 0) return;
    for (int i = idx + 1; i < _allMessages.length; i++) {
      final m = _allMessages[i];
      if (m.type == MessageType.voice &&
          m.senderId != widget.currentUid &&
          m.audioUrl != null) {
        _positionNotifier.value = Duration.zero;
        _durationNotifier.value = null;
        _playingNotifier.value = m.id;
        _isPlayingNotifier.value = true;
        _player.play(UrlSource(m.audioUrl!)).ignore();
        return;
      }
    }
  }

  Future<void> _seekAudio(Duration position) async {
    await _player.seek(position);
    _positionNotifier.value = position;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _senderName(MessageModel msg) =>
      msg.senderName ?? _nameCache[msg.senderId] ?? msg.senderId;

  Widget _buildTick(MessageModel msg) {
    final group = _group;
    if (group == null) return const Icon(Icons.check_rounded, size: 13, color: Colors.white60);
    const white60 = Colors.white60;
    const readColor = Color(0xFF4FC3F7);
    if (group.isReadBy(widget.currentUid, msg.timestamp)) return _doubleTick(readColor);
    if (group.isDeliveredTo(widget.currentUid, msg.timestamp)) return _doubleTick(white60);
    return const Icon(Icons.check_rounded, size: 13, color: white60);
  }

  Widget _doubleTick(Color color) => SizedBox(
    width: 18, height: 13,
    child: Stack(children: [
      Positioned(left: 0, child: Icon(Icons.check_rounded, size: 13, color: color)),
      Positioned(left: 5, child: Icon(Icons.check_rounded, size: 13, color: color)),
    ]),
  );

  // With reverse:true, bottom = pixels 0.
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients || !_hasMore || _isLoadingMore) return;
    // reverse:true: top = maxScrollExtent. Trigger load-more when approaching top.
    if (_scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 250) {
      _loadMoreMessages();
    }
  }

  Future<void> _loadMoreMessages() async {
    if (_isLoadingMore || !_hasMore) return;
    final oldest = _olderMessages.isNotEmpty
        ? _olderMessages.first.timestamp
        : null;
    // If no older messages yet, we need the oldest from the stream.
    // The stream is ascending, so index 0 is the oldest.
    // We'll read it from _streamOldest which is set inside the StreamBuilder.
    final cursor = oldest ?? _streamOldest;
    if (cursor == null) return;

    setState(() => _isLoadingMore = true);
    try {
      final older = await _service.loadOlderMessages(widget.groupId, cursor);
      final fresh = older.where((m) => !_loadedOlderIds.contains(m.id)).toList();
      if (fresh.isEmpty) {
        _hasMore = false;
      } else {
        _loadedOlderIds.addAll(fresh.map((m) => m.id));
        _olderMessages.insertAll(0, fresh); // ascending: oldest first
        if (fresh.length < 20) _hasMore = false;
      }
    } catch (_) {}
    if (mounted) setState(() => _isLoadingMore = false);
  }

  // Set by the StreamBuilder so _loadMoreMessages knows the oldest stream message.
  DateTime? _streamOldest;

  void _cancelReply() => setState(() => _replyingTo = null);

  // ── Send text ─────────────────────────────────────────────────────────────

  Future<void> _sendText() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _group == null) return;
    _textCtrl.clear();
    final reply = _replyingTo;
    _cancelReply();
    final pending = _PendingItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: MessageType.text, text: text);
    setState(() => _pending.add(pending));
    _scrollToBottom();
    try {
      final senderName = _nameCache[widget.currentUid] ?? widget.currentUid;
      await _service.sendTextMessage(
        groupId: widget.groupId,
        senderId: widget.currentUid,
        senderName: senderName,
        participants: _group!.participants,
        text: text,
        replyToId: reply?.id,
        replyToText: reply?.text,
        replyToImageUrl: reply?.imageUrl,
        replyToSenderId: reply?.senderId,
        replyToSenderName: reply?.senderName,
      );
    } catch (e) {
      debugPrint('sendText error: $e');
      if (mounted) { setState(() => _pending.remove(pending)); context.showError('Failed to send'); }
      return;
    }
    if (mounted) setState(() => _pending.remove(pending));
  }

  // ── Send image ────────────────────────────────────────────────────────────

  Future<void> _pickImage(ImageSource source) async {
    Navigator.pop(context);
    final xfile = await _imagePicker.pickImage(source: source, imageQuality: 75);
    if (xfile == null || _group == null || !mounted) return;
    final file = File(xfile.path);
    final reply = _replyingTo;
    _cancelReply();
    final pending = _PendingItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: MessageType.image, localFile: file);
    setState(() => _pending.add(pending));
    _scrollToBottom();
    try {
      final senderName = _nameCache[widget.currentUid] ?? widget.currentUid;
      await _service.sendImageMessage(
        groupId: widget.groupId,
        senderId: widget.currentUid,
        senderName: senderName,
        participants: _group!.participants,
        imageFile: file,
        replyToId: reply?.id,
        replyToText: reply?.text,
        replyToImageUrl: reply?.imageUrl,
        replyToSenderId: reply?.senderId,
        replyToSenderName: reply?.senderName,
      );
    } catch (e) {
      debugPrint('sendImage error: $e');
      if (mounted) {
        setState(() => _pending.remove(pending));
        context.showError('Failed to send image');
      }
      return;
    }
    if (mounted) setState(() => _pending.remove(pending));
  }

  // ── Send keyboard content (sticker / GIF from system keyboard) ─────────────

  Future<void> _onKeyboardContentInserted(KeyboardInsertedContent content) async {
    final bytes = content.data;
    if (bytes == null || _group == null || !mounted) return;
    final dir = await getTemporaryDirectory();
    final ext = content.mimeType.split('/').last.split('+').first;
    final file = File('${dir.path}/kbd_${DateTime.now().millisecondsSinceEpoch}.$ext');
    await file.writeAsBytes(bytes);
    if (!mounted || _group == null) return;
    final reply = _replyingTo;
    _cancelReply();
    final pending = _PendingItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: MessageType.image, localFile: file);
    setState(() => _pending.add(pending));
    _scrollToBottom();
    try {
      final senderName = _nameCache[widget.currentUid] ?? widget.currentUid;
      await _service.sendImageMessage(
        groupId: widget.groupId,
        senderId: widget.currentUid,
        senderName: senderName,
        participants: _group!.participants,
        imageFile: file,
        replyToId: reply?.id,
        replyToText: reply?.text,
        replyToImageUrl: reply?.imageUrl,
        replyToSenderId: reply?.senderId,
        replyToSenderName: reply?.senderName,
      );
    } catch (e) {
      debugPrint('sendKeyboardContent error: $e');
      if (mounted) { setState(() => _pending.remove(pending)); context.showError('Failed to send'); }
      return;
    }
    if (mounted) setState(() => _pending.remove(pending));
  }

  // ── Send video ────────────────────────────────────────────────────────────

  Future<void> _pickVideo() async {
    Navigator.pop(context);
    final xfile = await _imagePicker.pickVideo(source: ImageSource.gallery);
    if (xfile == null || _group == null || !mounted) return;
    final compressed = await VideoCompress.compressVideo(
      xfile.path,
      quality: VideoQuality.MediumQuality,
      deleteOrigin: false,
      includeAudio: true,
    );
    if (compressed?.path == null || !mounted || _group == null) return;
    final file = File(compressed!.path!);
    final reply = _replyingTo;
    _cancelReply();
    final pending = _PendingItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: MessageType.video, localFile: file);
    setState(() => _pending.add(pending));
    _scrollToBottom();
    try {
      final senderName = _nameCache[widget.currentUid] ?? widget.currentUid;
      await _service.sendVideoMessage(
        groupId: widget.groupId,
        senderId: widget.currentUid,
        senderName: senderName,
        participants: _group!.participants,
        videoFile: file,
        replyToId: reply?.id,
        replyToText: reply?.text,
        replyToImageUrl: reply?.imageUrl,
        replyToSenderId: reply?.senderId,
        replyToSenderName: reply?.senderName,
      );
    } catch (e) {
      debugPrint('sendVideo error: $e');
      if (mounted) { setState(() => _pending.remove(pending)); context.showError('Failed to send video'); }
      return;
    }
    if (mounted) setState(() => _pending.remove(pending));
  }

  // ── Send GIF ──────────────────────────────────────────────────────────────

  Future<void> _showGifPicker() async {
    Navigator.pop(context);
    final gifUrl = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const GifPickerSheet(),
    );
    if (gifUrl == null || !mounted || _group == null) return;
    final reply = _replyingTo;
    _cancelReply();
    final pending = _PendingItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: MessageType.gif, gifUrl: gifUrl);
    setState(() => _pending.add(pending));
    _scrollToBottom();
    try {
      final senderName = _nameCache[widget.currentUid] ?? widget.currentUid;
      await _service.sendGifMessage(
        groupId: widget.groupId,
        senderId: widget.currentUid,
        senderName: senderName,
        participants: _group!.participants,
        gifUrl: gifUrl,
        replyToId: reply?.id,
        replyToText: reply?.text,
        replyToImageUrl: reply?.imageUrl,
        replyToSenderId: reply?.senderId,
        replyToSenderName: reply?.senderName,
      );
    } catch (e) {
      debugPrint('sendGif error: $e');
      if (mounted) { setState(() => _pending.remove(pending)); context.showError('Failed to send GIF'); }
      return;
    }
    if (mounted) setState(() => _pending.remove(pending));
  }

  // ── Send sticker ──────────────────────────────────────────────────────────

  Future<void> _showStickerPicker() async {
    Navigator.pop(context);
    final sticker = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const StickerPickerSheet(),
    );
    if (sticker == null || !mounted || _group == null) return;
    final reply = _replyingTo;
    _cancelReply();
    final pending = _PendingItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: MessageType.sticker, sticker: sticker);
    setState(() => _pending.add(pending));
    _scrollToBottom();
    try {
      final senderName = _nameCache[widget.currentUid] ?? widget.currentUid;
      await _service.sendStickerMessage(
        groupId: widget.groupId,
        senderId: widget.currentUid,
        senderName: senderName,
        participants: _group!.participants,
        sticker: sticker,
        replyToId: reply?.id,
        replyToText: reply?.text,
        replyToImageUrl: reply?.imageUrl,
        replyToSenderId: reply?.senderId,
        replyToSenderName: reply?.senderName,
      );
    } catch (e) {
      debugPrint('sendSticker error: $e');
      if (mounted) { setState(() => _pending.remove(pending)); context.showError('Failed to send sticker'); }
      return;
    }
    if (mounted) setState(() => _pending.remove(pending));
  }

  // ── Voice recording ───────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    if (!await Permission.microphone.request().isGranted) return;
    final dir = await getTemporaryDirectory();
    _recordingPath = '${dir.path}/grp_rec_${DateTime.now().millisecondsSinceEpoch}.aac';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: _recordingPath!);
    _recordingSeconds = 0;
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recordingSeconds++);
    });
    setState(() => _isRecording = true);
  }

  Future<void> _stopForPreview() async {
    if (!_isRecording) return;
    _recordingTimer?.cancel();
    final path = await _recorder.stop();
    if (mounted) setState(() => _isRecording = false);
    if (path == null || _recordingSeconds < 1) return;
    final dur = _recordingSeconds;
    if (!mounted) return;
    final group = _group;
    if (group == null) return;
    final reply = _replyingTo;
    _cancelReply();

    final pending = _PendingItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: MessageType.voice,
      localFile: File(path),
      voiceDuration: dur,
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => VoicePreviewSheet(
        audioPath: path,
        durationSeconds: dur,
        onSend: () async {
          if (!mounted) return;
          setState(() => _pending.add(pending));
          _scrollToBottom();
          final senderName = _nameCache[widget.currentUid] ?? widget.currentUid;
          try {
            await _service.sendVoiceMessage(
              groupId: widget.groupId,
              senderId: widget.currentUid,
              senderName: senderName,
              participants: group.participants,
              audioFile: File(path),
              durationSeconds: dur,
              replyToId: reply?.id,
              replyToText: reply?.text,
              replyToSenderId: reply?.senderId,
              replyToSenderName: reply?.senderName,
            );
            if (mounted) setState(() => _pending.remove(pending));
          } catch (_) {
            if (mounted) {
              setState(() => _pending.remove(pending));
              context.showError('Failed to send voice message');
            }
          }
        },
      ),
    );
  }

  // ── Long-press menu ───────────────────────────────────────────────────────

  void _onLongPress(MessageModel msg) {
    final isMine = msg.senderId == widget.currentUid;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 36, height: 4, margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
          ),
          ListTile(
            leading: const Icon(Icons.reply_rounded),
            title: const Text('Reply'),
            onTap: () { Navigator.pop(ctx); setState(() => _replyingTo = msg); },
          ),
          if (isMine && msg.type == MessageType.text)
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('Edit'),
              onTap: () { Navigator.pop(ctx); _editMessage(msg); },
            ),
          if (isMine)
            ListTile(
              leading: const Icon(Icons.delete_rounded, color: Colors.red),
              title: const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () { Navigator.pop(ctx); _deleteMessage(msg); },
            ),
        ]),
      ),
    );
  }

  Future<void> _editMessage(MessageModel msg) async {
    final ctrl = TextEditingController(text: msg.text ?? '');
    final newText = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(controller: ctrl, autofocus: true, maxLines: null),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newText != null && newText.isNotEmpty) {
      await _service.editMessage(widget.groupId, msg.id, newText);
    }
  }

  Future<void> _deleteMessage(MessageModel msg) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete message?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _service.deleteMessage(
        widget.groupId,
        msg.id,
        audioUrl: msg.audioUrl,
        imageUrl: msg.imageUrl,
        videoUrl: msg.videoUrl,
      );
    }
  }

  // ── Emoji picker toggle ───────────────────────────────────────────────────

  void _toggleEmojiPicker() {
    if (_showEmojiPicker) {
      setState(() => _showEmojiPicker = false);
    } else {
      _textFocus.unfocus();
      setState(() => _showEmojiPicker = true);
    }
  }

  // ── Attachment sheet ──────────────────────────────────────────────────────

  void _showAttachmentSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(color: AppColors.divider, borderRadius: BorderRadius.circular(2)),
            ),
            ListTile(
              leading: _attachIcon(Icons.camera_alt_rounded),
              title: const Text('Camera'),
              onTap: () => _pickImage(ImageSource.camera),
            ),
            ListTile(
              leading: _attachIcon(Icons.photo_library_rounded),
              title: const Text('Gallery'),
              onTap: () => _pickImage(ImageSource.gallery),
            ),
            ListTile(
              leading: _attachIcon(Icons.videocam_rounded),
              title: const Text('Video'),
              onTap: _pickVideo,
            ),
            ListTile(
              leading: _attachIcon(Icons.gif_rounded, size: 26),
              title: const Text('GIF'),
              onTap: _showGifPicker,
            ),
            ListTile(
              leading: Container(
                width: 40, height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle),
                child: const Text('😊', style: TextStyle(fontSize: 22)),
              ),
              title: const Text('Sticker'),
              onTap: _showStickerPicker,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _attachIcon(IconData icon, {double size = 22}) => Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.1),
            shape: BoxShape.circle),
        child: Icon(icon, color: AppColors.primary, size: size),
      );

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final group = _group;
    final groupName = group?.name ?? widget.initialName;
    final memberCount = group?.participants.length ?? 0;
    final isMuted = context.watch<AppProvider>().isGroupMuted(widget.groupId);

    if (group != null) {
      for (final uid in group.participants) {
        // putIfAbsent so we don't overwrite real names already loaded
        _nameCache.putIfAbsent(uid, () => uid);
      }
    }

    Widget body = Column(children: [
      // ── Messages ───────────────────────────────────────────────────────
      Expanded(
        child: StreamBuilder<List<MessageModel>>(
          stream: _messagesStream,
          builder: (ctx, snap) {
            // Stream returns ascending (oldest first). Track oldest for load-more cursor.
            final streamMsgs = snap.data ?? [];
            if (streamMsgs.isNotEmpty) _streamOldest = streamMsgs.first.timestamp;

            // Auto-scroll and mark-read only when new messages arrive.
            if (_prevMsgCount != null &&
                streamMsgs.length > _prevMsgCount! &&
                !_isLoadingMore) {
              _scrollToBottom();
              // New messages arrived while screen is open — mark as read once.
              _service.markRead(widget.groupId, widget.currentUid).ignore();
            }
            _prevMsgCount = streamMsgs.length;
            // markRead is called in initState and dispose — NOT here, because
            // calling it on every StreamBuilder rebuild creates unnecessary
            // Firestore writes (one per stream event).

            // Stream-based dedup: when a sent message appears in the stream,
            // remove the matching pending bubble immediately so there's never
            // a persistent duplicate regardless of async timing.
            if (_pending.isNotEmpty) {
              final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
              final confirmed = _pending
                  .where((p) => streamMsgs.any((m) =>
                      m.senderId == widget.currentUid &&
                      m.timestamp.isAfter(cutoff) &&
                      m.type == p.type &&
                      (p.type != MessageType.text || m.text == p.text)))
                  .toList();
              if (confirmed.isNotEmpty) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && confirmed.any(_pending.contains)) {
                    setState(() => _pending.removeWhere(confirmed.contains));
                  }
                });
              }
            }

            // Merge: stream (ascending) + older pages (ascending), deduplicated.
            final streamIds = streamMsgs.map((m) => m.id).toSet();
            final olderFiltered =
                _olderMessages.where((m) => !streamIds.contains(m.id)).toList();
            final allMsgs = [...streamMsgs, ...olderFiltered]; // ascending
            _allMessages = allMsgs; // kept for auto-play lookups

            // Reverse for the reverse:true ListView (index 0 = newest = bottom).
            final msgsDesc = allMsgs.reversed.toList();

            // Build items: pending at bottom (index 0), then messages, then load indicator.
            final pendingCount = _pending.length;
            final msgCount = msgsDesc.length;
            final showLoader = _hasMore || _isLoadingMore;
            final totalCount = pendingCount + msgCount + (showLoader ? 1 : 0);

            if (totalCount == 0 || (msgsDesc.isEmpty && pendingCount == 0)) {
              return Center(
                child: Text('No messages yet\nSay hello!',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: AppColors.textSecondary.withValues(alpha: 0.6))),
              );
            }

            return ListView.builder(
              controller: _scrollCtrl,
              reverse: true,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: totalCount,
              itemBuilder: (ctx, i) {
                // Loading indicator at the very top (last index in reverse list).
                if (showLoader && i == totalCount - 1) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: _isLoadingMore
                          ? const SizedBox(
                              width: 20, height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const SizedBox.shrink(),
                    ),
                  );
                }

                // Pending bubbles at the bottom (newest end).
                if (i < pendingCount) {
                  return _buildPendingBubble(_pending[pendingCount - 1 - i]);
                }

                final msgI = i - pendingCount;
                final msg = msgsDesc[msgI];
                final isMine = msg.senderId == widget.currentUid;

                // Date divider: in descending list, show when next item is a different day.
                // "Next" = higher index = older message = visually above.
                Widget? divider;
                final nextMsg = (msgI + 1 < msgsDesc.length)
                    ? msgsDesc[msgI + 1]
                    : null;
                if (nextMsg == null || !_sameDay(msg.timestamp, nextMsg.timestamp)) {
                  divider = _DateDivider(date: msg.timestamp);
                }

                return Column(children: [
                  _SwipeToReply(
                    onReply: () => setState(() => _replyingTo = msg),
                    child: GestureDetector(
                      onLongPress: () {
                        HapticFeedback.mediumImpact();
                        _onLongPress(msg);
                      },
                      child: _MessageBubble(
                        msg: msg,
                        isMine: isMine,
                        senderName: _senderName(msg),
                        photoUrl: _photoCache[msg.senderId],
                        showSenderInfo: !isMine,
                        playingIdNotifier: _playingNotifier,
                        isPlayingNotifier: _isPlayingNotifier,
                        positionNotifier: _positionNotifier,
                        durationNotifier: _durationNotifier,
                        onToggleVoice: () => _togglePlay(msg),
                        onSeekAudio: _seekAudio,
                        onReply: () => setState(() => _replyingTo = msg),
                        allMessages: allMsgs,
                        tickWidget: isMine ? _buildTick(msg) : null,
                      ),
                    ),
                  ),
                  if (divider != null) divider,
                ]);
              },
            );
          },
        ),
      ),

      // ── Recording bar ────────────────────────────────────────────────
      if (_isRecording)
        _RecordingBar(
          seconds: _recordingSeconds,
          onSlideDown: _stopForPreview,
        ),

      // ── Reply bar ────────────────────────────────────────────────────
      if (_replyingTo != null) _ReplyBar(msg: _replyingTo!, onCancel: _cancelReply),

      // ── Input bar ────────────────────────────────────────────────────
      _InputBar(
        controller: _textCtrl,
        focusNode: _textFocus,
        onSend: _sendText,
        onAttach: _showAttachmentSheet,
        onMicTap: _isRecording ? _stopForPreview : _startRecording,
        isRecording: _isRecording,
        onEmojiToggle: _toggleEmojiPicker,
        showEmojiPicker: _showEmojiPicker,
        onKeyboardContent: _onKeyboardContentInserted,
      ),
      // ── Emoji picker ─────────────────────────────────────────────────
      if (_showEmojiPicker)
        SizedBox(
          height: 256,
          child: EmojiPicker(
            textEditingController: _textCtrl,
            config: Config(
              height: 256,
              checkPlatformCompatibility: true,
              emojiViewConfig: EmojiViewConfig(
                emojiSizeMax: 28 * (Platform.isIOS ? 1.20 : 1.0),
                columns: 8,
              ),
              skinToneConfig: const SkinToneConfig(),
              categoryViewConfig: const CategoryViewConfig(
                  initCategory: Category.RECENT),
              bottomActionBarConfig: BottomActionBarConfig(
                backgroundColor: Colors.white,
                buttonColor: Colors.white,
                buttonIconColor: AppColors.primary,
              ),
            ),
          ),
        ),
    ]);

    final bgImageUrl = _group?.backgroundImageUrl;
    final bgColorVal = _group?.backgroundColor;

    if (bgImageUrl != null) {
      body = Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: CachedNetworkImageProvider(bgImageUrl),
            fit: BoxFit.cover,
          ),
        ),
        child: body,
      );
    }

    return Scaffold(
      backgroundColor: bgColorVal != null ? Color(bgColorVal) : _defaultBgColor,
      appBar: AppBar(
        titleSpacing: 0,
        title: GestureDetector(
          onTap: group != null
              ? () => Navigator.push(context, MaterialPageRoute(
                    builder: (_) => GroupInfoScreen(group: group, currentUid: widget.currentUid)))
              : null,
          child: Row(children: [
            GestureDetector(
              onTap: group?.iconUrl != null
                  ? () => Navigator.push(context, MaterialPageRoute(
                        builder: (_) => Scaffold(
                          backgroundColor: Colors.black,
                          appBar: AppBar(
                            backgroundColor: Colors.transparent,
                            iconTheme: const IconThemeData(color: Colors.white),
                          ),
                          body: Center(
                            child: InteractiveViewer(
                              child: CachedNetworkImage(
                                imageUrl: group!.iconUrl!,
                                placeholder: (_, __) =>
                                    const Center(child: CircularProgressIndicator()),
                              ),
                            ),
                          ),
                        ),
                      ))
                  : null,
              child: CircleAvatar(
                radius: 18,
                backgroundColor: Colors.white.withValues(alpha: 0.3),
                backgroundImage: group?.iconUrl != null
                    ? CachedNetworkImageProvider(group!.iconUrl!) : null,
                child: group?.iconUrl == null
                    ? const Icon(Icons.group_rounded, color: Colors.white, size: 20) : null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(groupName,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis),
                if (memberCount > 0)
                  Text('$memberCount members',
                      style: const TextStyle(fontSize: 11, color: Colors.white70)),
              ]),
            ),
          ]),
        ),
        actions: [
          if (isMuted)
            const Padding(
              padding: EdgeInsets.only(right: 2),
              child: Icon(Icons.notifications_off_rounded, color: Colors.white70, size: 18),
            ),
          if (group != null)
            IconButton(
              icon: const Icon(Icons.info_outline_rounded),
              onPressed: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => GroupInfoScreen(group: group, currentUid: widget.currentUid))),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (v) {
              if (v == 'wallpaper') _showBackgroundPicker();
              if (v == 'mute') _toggleMute();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'wallpaper',
                child: Row(children: [
                  Icon(Icons.wallpaper_rounded, size: 20, color: Colors.grey.shade700),
                  const SizedBox(width: 10),
                  const Text('Wallpaper'),
                ]),
              ),
              PopupMenuItem(
                value: 'mute',
                child: Row(children: [
                  Icon(isMuted ? Icons.notifications_rounded : Icons.notifications_off_rounded,
                      size: 20, color: Colors.grey.shade700),
                  const SizedBox(width: 10),
                  Text(isMuted ? 'Unmute notifications' : 'Mute notifications'),
                ]),
              ),
            ],
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _buildPendingBubble(_PendingItem item) {
    if (item.type == MessageType.sticker) {
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Opacity(
            opacity: 0.6,
            child: Text(item.sticker ?? '😊', style: const TextStyle(fontSize: 56)),
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.all(10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(16),
        ),
        child: item.status == _PendingStatus.failed
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.error_outline_rounded, color: Colors.red, size: 16),
                const SizedBox(width: 6),
                const Text('Failed', style: TextStyle(color: Colors.red, fontSize: 12)),
              ])
            : item.type == MessageType.voice
                ? Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      width: 32, height: 32,
                      decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
                      child: const Icon(Icons.mic_rounded, color: Colors.white, size: 18),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Voice message',
                            style: TextStyle(color: Colors.white, fontSize: 13)),
                        if (item.voiceDuration != null)
                          Text(
                            '${item.voiceDuration! ~/ 60}:${(item.voiceDuration! % 60).toString().padLeft(2, '0')}',
                            style: const TextStyle(color: Colors.white70, fontSize: 11),
                          ),
                      ],
                    ),
                    const SizedBox(width: 10),
                    const SizedBox(width: 12, height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white70)),
                  ])
                : (item.type == MessageType.image || item.type == MessageType.video) &&
                    item.localFile != null
                ? Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(item.localFile!, width: 180, height: 180, fit: BoxFit.cover),
                    ),
                    if (item.type == MessageType.video)
                      const Positioned.fill(
                        child: Center(
                          child: Icon(Icons.play_circle_fill_rounded,
                              color: Colors.white70, size: 40),
                        ),
                      ),
                    const Positioned(
                      bottom: 6, right: 6,
                      child: SizedBox(width: 12, height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white70)),
                    ),
                  ])
                : item.gifUrl != null
                    ? Stack(children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: CachedNetworkImage(
                              imageUrl: item.gifUrl!, width: 180, height: 140, fit: BoxFit.cover),
                        ),
                        const Positioned(
                          bottom: 6, right: 6,
                          child: SizedBox(width: 12, height: 12,
                              child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white70)),
                        ),
                      ])
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(item.text ?? _typeLabel(item.type),
                            style: const TextStyle(color: Colors.white, fontSize: 15)),
                        const SizedBox(width: 8),
                        const SizedBox(width: 12, height: 12,
                            child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white70)),
                      ]),
      ),
    );
  }

  String _typeLabel(MessageType t) {
    switch (t) {
      case MessageType.voice:   return '🎤 Voice message';
      case MessageType.image:   return '📷 Photo';
      case MessageType.gif:     return '🎞️ GIF';
      case MessageType.sticker: return '😊 Sticker';
      case MessageType.video:   return '🎬 Video';
      default: return '';
    }
  }

  static bool _sameParticipants(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final sa = Set<String>.from(a);
    return b.every(sa.contains);
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

// ── Swipe-to-reply ────────────────────────────────────────────────────────────

class _SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
  const _SwipeToReply({required this.child, required this.onReply});

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> {
  static const _threshold = 60.0;
  double _offset = 0;
  bool _triggered = false;
  Offset? _start; // tracks the pointer-down position

  void _down(PointerDownEvent e)   { _start = e.localPosition; _triggered = false; }
  void _cancel(PointerCancelEvent e) { _start = null; _triggered = false; if (_offset != 0) setState(() => _offset = 0); }

  void _move(PointerMoveEvent e) {
    if (_start == null) return;
    final dx = e.localPosition.dx - _start!.dx;
    final dy = (e.localPosition.dy - _start!.dy).abs();
    // Only handle rightward, horizontally-dominant swipes — vertical scrolls reset.
    if (dy > dx) { if (_offset != 0) setState(() => _offset = 0); return; }
    if (dx <= 0) return;
    final next = dx.clamp(0.0, _threshold + 12);
    setState(() => _offset = next);
    if (next >= _threshold && !_triggered) {
      _triggered = true;
      HapticFeedback.lightImpact();
    }
  }

  void _up(PointerUpEvent e) {
    if (_triggered) widget.onReply();
    _triggered = false;
    _start = null;
    if (_offset != 0) setState(() => _offset = 0);
  }

  @override
  Widget build(BuildContext context) {
    // Use Listener (raw pointer events) instead of GestureDetector so we
    // do NOT enter the gesture arena — this lets TapGestureRecognizer inside
    // LinkableText receive taps and open URLs without competition.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown:   _down,
      onPointerMove:   _move,
      onPointerUp:     _up,
      onPointerCancel: _cancel,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Transform.translate(offset: Offset(_offset, 0), child: widget.child),
          if (_offset > 6)
            Positioned(
              left: 0, top: 0, bottom: 0,
              child: Center(
                child: Opacity(
                  opacity: (_offset / _threshold).clamp(0.0, 1.0),
                  child: const Icon(Icons.reply_rounded, color: AppColors.primary, size: 22),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Message bubble ────────────────────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final MessageModel msg;
  final bool isMine;
  final String senderName;
  final String? photoUrl;
  final bool showSenderInfo;
  final ValueNotifier<String?> playingIdNotifier;
  final ValueNotifier<bool> isPlayingNotifier;
  final ValueNotifier<Duration> positionNotifier;
  final ValueNotifier<Duration?> durationNotifier;
  final VoidCallback onToggleVoice;
  final void Function(Duration) onSeekAudio;
  final VoidCallback onReply;
  final List<MessageModel> allMessages;
  final Widget? tickWidget;

  const _MessageBubble({
    required this.msg,
    required this.isMine,
    required this.senderName,
    this.photoUrl,
    required this.showSenderInfo,
    required this.playingIdNotifier,
    required this.isPlayingNotifier,
    required this.positionNotifier,
    required this.durationNotifier,
    required this.onToggleVoice,
    required this.onSeekAudio,
    required this.onReply,
    required this.allMessages,
    this.tickWidget,
  });

  static const _senderColors = [
    Color(0xFF6C63FF), Color(0xFFE91E63), Color(0xFF00897B),
    Color(0xFFFF6D00), Color(0xFF1565C0), Color(0xFF6A1B9A),
  ];

  // Named users get fixed colors for both their avatar/label and their bubble.
  static const _namedColors = <String, Color>{
    'buji':  Color(0xFF212121),       // black
    'harry': Color(0xFF388E3C),       // green
    'sandy': Color(0xFF7B1FA2),       // purple
  };

  Color _colorForName(String name) {
    final c = _namedColors[name.toLowerCase()];
    if (c != null) return c;
    return _senderColors[name.hashCode.abs() % _senderColors.length];
  }

  @override
  Widget build(BuildContext context) {
    // Stickers: bypass Container/ClipRRect entirely — just the emoji floating
    // on the chat background, identical to how private chat renders stickers.
    if (msg.type == MessageType.sticker) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (showSenderInfo) ...[
              CircleAvatar(
                radius: 14,
                backgroundColor: _colorForName(senderName),
                backgroundImage: photoUrl != null ? CachedNetworkImageProvider(photoUrl!) : null,
                child: photoUrl == null
                    ? Text(senderName.isNotEmpty ? senderName[0].toUpperCase() : '?',
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold))
                    : null,
              ),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Column(
                crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showSenderInfo)
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 2),
                      child: Text(senderName,
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                              color: _colorForName(senderName))),
                    ),
                  Text(msg.text ?? '😊', style: const TextStyle(fontSize: 56)),
                  Text(_fmtTime(msg.timestamp),
                      style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                ],
              ),
            ),
            if (isMine) const SizedBox(width: 6),
          ],
        ),
      );
    }

    // Named users (Buji/Harry/Sandy) always use their fixed color regardless
    // of whether the message is mine or from someone else.
    final namedColor = _namedColors[senderName.toLowerCase()];
    final bubbleColor = namedColor ?? (isMine ? AppColors.primary : Colors.white);
    final textColor  = (namedColor != null || isMine) ? Colors.white : AppColors.textPrimary;
    // Images and GIFs render without a bubble background.
    final noBg = msg.type == MessageType.image || msg.type == MessageType.gif;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (showSenderInfo) ...[
            CircleAvatar(
              radius: 14,
              backgroundColor: _colorForName(senderName),
              backgroundImage: photoUrl != null ? CachedNetworkImageProvider(photoUrl!) : null,
              child: photoUrl == null
                  ? Text(senderName.isNotEmpty ? senderName[0].toUpperCase() : '?',
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold))
                  : null,
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (showSenderInfo)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 2),
                    child: Text(senderName,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                            color: _colorForName(senderName))),
                  ),
                Container(
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
                  decoration: noBg
                      ? null
                      : BoxDecoration(
                          color: bubbleColor,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(16),
                            topRight: const Radius.circular(16),
                            bottomLeft: Radius.circular(isMine ? 16 : 4),
                            bottomRight: Radius.circular(isMine ? 4 : 16),
                          ),
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 4)],
                        ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isMine ? 16 : 4),
                      bottomRight: Radius.circular(isMine ? 4 : 16),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (msg.replyToId != null) _ReplyPreview(msg: msg, isMine: isMine),
                      Padding(
                        padding: noBg
                            ? EdgeInsets.zero
                            : const EdgeInsets.fromLTRB(10, 8, 10, 6),
                        child: _buildContent(context, textColor),
                      ),
                    ]),
                  ),
                ),
              ],
            ),
          ),
          if (isMine) const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context, Color textColor) {
    final timeRow = Row(mainAxisSize: MainAxisSize.min, children: [
      if (msg.isEdited)
        Text('edited  ', style: TextStyle(color: textColor.withValues(alpha: 0.55), fontSize: 10)),
      Text(_fmtTime(msg.timestamp),
          style: TextStyle(color: textColor.withValues(alpha: 0.55), fontSize: 10)),
      if (tickWidget != null) ...[const SizedBox(width: 3), tickWidget!],
    ]);

    switch (msg.type) {
      case MessageType.text:
        return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          LinkableText(
            text: msg.text ?? '',
            style: TextStyle(color: textColor, fontSize: 15, height: 1.35),
          ),
          if (containsUrl(msg.text ?? ''))
            LinkPreviewWidget(
              key: ValueKey('lp_${msg.id}'),
              url: extractFirstUrl(msg.text ?? '')!,
              isMine: isMine,
            ),
          const SizedBox(height: 2),
          timeRow,
        ]);

      case MessageType.image:
        return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (msg.imageUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: msg.imageUrl!,
                width: 220,
                fit: BoxFit.fitWidth,
                placeholder: (_, __) => Container(
                    width: 220, height: 160, color: Colors.black12,
                    child: const Center(child: CircularProgressIndicator(strokeWidth: 2))),
                errorWidget: (_, __, ___) => Container(
                    width: 220, height: 60, color: Colors.black12,
                    child: const Icon(Icons.broken_image_outlined, color: Colors.white54)),
              ),
            ),
          const SizedBox(height: 4),
          timeRow,
        ]);

      case MessageType.gif:
        return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (msg.imageUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: msg.imageUrl!,
                width: 220,
                fit: BoxFit.fitWidth,
                placeholder: (_, __) => Container(
                    width: 220, height: 160, color: Colors.black12,
                    child: const Center(child: CircularProgressIndicator(strokeWidth: 2))),
              ),
            ),
          const SizedBox(height: 4),
          timeRow,
        ]);

      case MessageType.sticker:
        // Handled by early return in build() — never reaches here.
        return const SizedBox.shrink();

      case MessageType.video:
        return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (msg.videoUrl != null)
            Container(
              width: 220, height: 160,
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                child: Icon(Icons.play_circle_fill_rounded,
                    color: Colors.white, size: 52),
              ),
            ),
          const SizedBox(height: 4),
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.videocam_rounded, size: 10, color: Colors.grey),
            const SizedBox(width: 3),
            timeRow,
          ]),
        ]);

      case MessageType.voice:
        // Use white colors whenever the bubble background is dark (named-color
        // or own message). textColor is already Colors.white for dark bubbles.
        return VoiceMessagePlayer(
          messageId: msg.id,
          audioUrl: msg.audioUrl,
          totalSeconds: msg.audioDurationSeconds ?? 0,
          isMine: textColor == Colors.white,
          playingIdNotifier: playingIdNotifier,
          isPlayingNotifier: isPlayingNotifier,
          positionNotifier: positionNotifier,
          durationNotifier: durationNotifier,
          onToggle: onToggleVoice,
          onSeek: onSeekAudio,
        );

    }
  }

  static String _fmtTime(DateTime dt) => DateFormat('h:mm a').format(dt);
}

// ── Reply preview ─────────────────────────────────────────────────────────────

class _ReplyPreview extends StatelessWidget {
  final MessageModel msg;
  final bool isMine;
  const _ReplyPreview({required this.msg, required this.isMine});

  @override
  Widget build(BuildContext context) {
    final bg = isMine
        ? Colors.white.withValues(alpha: 0.18)
        : AppColors.primary.withValues(alpha: 0.08);
    final accent = isMine ? Colors.white70 : AppColors.primary;
    final name = msg.replyToSenderName ?? msg.replyToSenderId ?? '';
    return Container(
      margin: const EdgeInsets.fromLTRB(6, 6, 6, 0),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (name.isNotEmpty)
          Text(name, style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w700)),
        if (msg.replyToImageUrl != null)
          Row(children: [
            const Icon(Icons.image_rounded, size: 14, color: Colors.grey),
            const SizedBox(width: 4),
            Text('Photo', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
          ])
        else
          Text(msg.replyToText ?? '',
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
      ]),
    );
  }
}

// ── Reply bar above input ─────────────────────────────────────────────────────

class _ReplyBar extends StatelessWidget {
  final MessageModel msg;
  final VoidCallback onCancel;
  const _ReplyBar({required this.msg, required this.onCancel});

  String _replyPreview(MessageModel m) {
    switch (m.type) {
      case MessageType.voice:   return '🎤 Voice message';
      case MessageType.image:   return '📷 Photo';
      case MessageType.gif:     return '🎞️ GIF';
      case MessageType.sticker: return m.text ?? '😊 Sticker';
      case MessageType.video:   return '🎬 Video';
      case MessageType.text:    return m.text ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = msg.senderName ?? msg.senderId;
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        Container(width: 3, height: 36, color: AppColors.primary,
            margin: const EdgeInsets.only(right: 8)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.primary)),
            Text(_replyPreview(msg),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ]),
        ),
        IconButton(icon: const Icon(Icons.close, size: 18), onPressed: onCancel),
      ]),
    );
  }
}

// ── Recording bar ─────────────────────────────────────────────────────────────

class _RecordingBar extends StatelessWidget {
  final int seconds;
  final VoidCallback onSlideDown;
  const _RecordingBar({required this.seconds, required this.onSlideDown});

  String get _time =>
      '${(seconds ~/ 60).toString().padLeft(1, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragUpdate: (d) {
        if (d.delta.dy > 6) onSlideDown();
      },
      child: Container(
        color: AppColors.holiday.withValues(alpha: 0.08),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(children: [
          Container(
            width: 10, height: 10,
            decoration: const BoxDecoration(color: AppColors.holiday, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Text('Recording  $_time',
              style: const TextStyle(
                  color: AppColors.holiday, fontWeight: FontWeight.w600, fontSize: 14)),
          const Spacer(),
          const Text('↓ Slide down to finish',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
        ]),
      ),
    );
  }
}

// ── Input bar ─────────────────────────────────────────────────────────────────

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onMicTap;
  final bool isRecording;
  final VoidCallback onEmojiToggle;
  final bool showEmojiPicker;
  final void Function(KeyboardInsertedContent) onKeyboardContent;

  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onAttach,
    required this.onMicTap,
    required this.isRecording,
    required this.onEmojiToggle,
    required this.showEmojiPicker,
    required this.onKeyboardContent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
      child: SafeArea(
        top: false,
        child: Row(children: [
          // Emoji toggle
          GestureDetector(
            onTap: onEmojiToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                showEmojiPicker
                    ? Icons.keyboard_rounded
                    : Icons.emoji_emotions_rounded,
                color: showEmojiPicker ? AppColors.primary : AppColors.textSecondary,
                size: 24,
              ),
            ),
          ),
          // Text field
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF0EDF8),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    maxLines: 5, minLines: 1,
                    textCapitalization: TextCapitalization.sentences,
                    // Receive stickers / GIFs inserted from the system keyboard
                    contentInsertionConfiguration: ContentInsertionConfiguration(
                      allowedMimeTypes: const [
                        'image/gif', 'image/jpeg', 'image/png', 'image/webp',
                      ],
                      onContentInserted: onKeyboardContent,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Message',
                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      border: InputBorder.none,
                    ),
                    onSubmitted: (_) => onSend(),
                  ),
                ),
                // Attach button inside the field pill
                GestureDetector(
                  onTap: onAttach,
                  child: const Padding(
                    padding: EdgeInsets.only(right: 10, left: 4),
                    child: Icon(Icons.attach_file_rounded,
                        color: AppColors.textSecondary, size: 20),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(width: 6),
          // Send / mic
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (ctx, value, _) {
              final hasText = value.text.trim().isNotEmpty;
              return hasText
                  ? GestureDetector(
                      onTap: onSend,
                      child: Container(
                        width: 42, height: 42,
                        decoration: const BoxDecoration(
                            color: AppColors.primary, shape: BoxShape.circle),
                        child: const Icon(Icons.send_rounded,
                            color: Colors.white, size: 20),
                      ),
                    )
                  : GestureDetector(
                      onTap: onMicTap,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: isRecording ? 50 : 42,
                        height: isRecording ? 50 : 42,
                        decoration: BoxDecoration(
                          color: isRecording ? AppColors.holiday : AppColors.primary,
                          shape: BoxShape.circle,
                          boxShadow: isRecording
                              ? [BoxShadow(
                                  color: AppColors.holiday.withValues(alpha: 0.4),
                                  blurRadius: 12, spreadRadius: 4)]
                              : [],
                        ),
                        child: Icon(
                          isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                          color: Colors.white,
                          size: isRecording ? 24 : 20,
                        ),
                      ),
                    );
            },
          ),
        ]),
      ),
    );
  }
}

// ── Date divider ──────────────────────────────────────────────────────────────

class _DateDivider extends StatelessWidget {
  final DateTime date;
  const _DateDivider({required this.date});

  String get _label {
    final now = DateTime.now();
    if (date.year == now.year && date.month == now.month && date.day == now.day) return 'Today';
    final yesterday = now.subtract(const Duration(days: 1));
    if (date.year == yesterday.year && date.month == yesterday.month && date.day == yesterday.day) {
      return 'Yesterday';
    }
    return DateFormat('d MMM y').format(date);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 4)],
            ),
            child: Text(_label,
                style: const TextStyle(fontSize: 11, color: AppColors.textSecondary,
                    fontWeight: FontWeight.w600)),
          ),
        ),
        const Expanded(child: Divider()),
      ]),
    );
  }
}
