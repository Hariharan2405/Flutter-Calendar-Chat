import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import '../widgets/link_preview_widget.dart';
import '../widgets/voice_message_player.dart';
import '../widgets/audio_file_message.dart';
import '../widgets/media_viewers.dart';
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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_compress/video_compress.dart';

import '../constants/app_theme.dart';
import '../models/group_model.dart';
import '../models/message_model.dart';
import '../providers/app_provider.dart';
import '../services/chat_service.dart';
import '../services/group_chat_service.dart';
import '../services/media_cache.dart';
import '../services/media_prefetcher.dart';
import '../services/media_save_service.dart';
import '../services/saved_media_store.dart';
import '../services/outbox_service.dart';
import '../utils/responsive.dart';
import '../utils/snack_util.dart';
import '../widgets/caption_input_sheet.dart';
import '../widgets/chat_extras.dart';
import '../widgets/forward_sheet.dart';
import '../widgets/speak_button.dart';
import '../widgets/chat_ui.dart';
import '../services/tts_service.dart';
import '../services/chat_prefs.dart';
import '../utils/tanglish.dart';
import 'message_search_screen.dart';
import 'starred_messages_screen.dart';
import 'group_info_screen.dart';
import 'image_edit_screen.dart';
import '../utils/image_sizing.dart';

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
  final String? fileName;
  final int? fileSizeBytes;
  _PendingStatus status = _PendingStatus.sending;
  _PendingItem({
    required this.id,
    required this.type,
    this.localFile,
    this.voiceDuration,
    this.text,
    this.gifUrl,
    this.sticker,
    this.fileName,
    this.fileSizeBytes,
  });
}

// ── Screen ────────────────────────────────────────────────────────────────────

class GroupChatScreen extends StatefulWidget {
  final String groupId;
  final String currentUid;
  final String initialName;

  /// Shown beside the chat list on a tablet rather than as its own page, so
  /// it has no back button.
  final bool embedded;

  const GroupChatScreen({
    super.key,
    required this.groupId,
    required this.currentUid,
    required this.initialName,
    this.embedded = false,
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
  // Newest message id last seen — detects arrivals despite the capped window.
  String? _newestMsgId;
  // "New messages" jump button — shown when messages arrive while scrolled up.
  bool _showJumpToBottom = false;
  int _unseenCount = 0;

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

  // ── Starred / pinned / typing ──────────────────────────────────────────────
  Set<String> _starredIds = {};
  StreamSubscription<Set<String>>? _starredSub;
  String? get _pinnedMessageId => _group?.pinnedMessageId;
  String? get _pinnedText => _group?.pinnedText;

  /// Names of everyone currently typing, excluding me and anyone whose stamp
  /// has gone stale.
  List<String> get _typingNames {
    final g = _group;
    if (g == null) return [];
    return g.typingAt.entries
        .where((e) =>
            e.key != widget.currentUid && TypingState.isActive(e.value))
        .map((e) => g.typingNames[e.key] ?? _nameCache[e.key] ?? 'Someone')
        .toList();
  }

  DateTime? _lastTypingPing;
  Timer? _typingStopTimer;

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

    _starredSub = ChatService().starredIds(widget.currentUid).listen(
      (ids) { if (mounted) setState(() => _starredIds = ids); },
    );
    _textCtrl.addListener(_onComposeChanged);
    _restoreDraft();
  }

  // ── Drafts ─────────────────────────────────────────────────────────────────
  // On-device only: an unsent message is private until you send it.

  String get _draftKey => 'draft_group_${widget.groupId}';

  Future<void> _restoreDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final draft = prefs.getString(_draftKey);
    if (draft != null && draft.isNotEmpty && mounted) {
      _textCtrl.text = draft;
      _textCtrl.selection =
          TextSelection.collapsed(offset: _textCtrl.text.length);
      setState(() {});
    }
  }

  Future<void> _saveDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final text = _textCtrl.text.trim();
    if (text.isEmpty) {
      await prefs.remove(_draftKey);
    } else {
      await prefs.setString(_draftKey, text);
    }
  }

  // ── Typing ─────────────────────────────────────────────────────────────────

  void _onComposeChanged() {
    _maybeUpdateMentionQuery();
    final now = DateTime.now();
    if (_textCtrl.text.isEmpty) {
      _typingStopTimer?.cancel();
      _setTyping(false);
      _lastTypingPing = null;
      return;
    }
    if (_lastTypingPing == null ||
        now.difference(_lastTypingPing!) > const Duration(seconds: 3)) {
      _lastTypingPing = now;
      _setTyping(true);
    }
    _typingStopTimer?.cancel();
    _typingStopTimer = Timer(const Duration(seconds: 5), () {
      _lastTypingPing = null;
      _setTyping(false);
    });
  }

  void _setTyping(bool typing) {
    final name = context.read<AppProvider>().profile?.name ?? '';
    _service
        .setTyping(widget.groupId, widget.currentUid, name, typing: typing)
        .ignore();
  }

  // ── @mentions ──────────────────────────────────────────────────────────────

  /// Members matching the @token currently under the caret, or empty when the
  /// user isn't composing a mention.
  List<MapEntry<String, String>> _mentionSuggestions = [];

  /// Detects a trailing `@word` at the caret and offers matching members.
  void _maybeUpdateMentionQuery() {
    final sel = _textCtrl.selection;
    final text = _textCtrl.text;
    if (!sel.isValid || sel.baseOffset != sel.extentOffset) {
      _clearMentions();
      return;
    }
    final upto = text.substring(0, sel.baseOffset);
    final at = upto.lastIndexOf('@');
    // Must be at a word boundary, and the token can't contain a space.
    if (at == -1 || (at > 0 && upto[at - 1].trim().isNotEmpty)) {
      _clearMentions();
      return;
    }
    final token = upto.substring(at + 1);
    if (token.contains(' ') || token.contains('\n')) {
      _clearMentions();
      return;
    }
    final q = token.toLowerCase();
    final matches = _nameCache.entries
        .where((e) =>
            e.key != widget.currentUid && e.value.toLowerCase().startsWith(q))
        .take(6)
        .toList();
    if (matches.length != _mentionSuggestions.length ||
        !matches.every((m) => _mentionSuggestions.any((s) => s.key == m.key))) {
      setState(() => _mentionSuggestions = matches);
    }
  }

  void _clearMentions() {
    if (_mentionSuggestions.isNotEmpty) {
      setState(() => _mentionSuggestions = []);
    }
  }

  /// Replaces the in-progress @token with the chosen member's name.
  void _applyMention(String uid, String name) {
    final sel = _textCtrl.selection;
    final text = _textCtrl.text;
    final upto = text.substring(0, sel.baseOffset);
    final at = upto.lastIndexOf('@');
    if (at == -1) return;
    final replaced = '${text.substring(0, at)}@$name ${text.substring(sel.baseOffset)}';
    _textCtrl.value = TextEditingValue(
      text: replaced,
      selection: TextSelection.collapsed(offset: at + name.length + 2),
    );
    _clearMentions();
  }

  /// UIDs whose name appears as @name in [text].
  List<String> _extractMentions(String text) {
    final lower = text.toLowerCase();
    return _nameCache.entries
        .where((e) =>
            e.key != widget.currentUid &&
            e.value.isNotEmpty &&
            lower.contains('@${e.value.toLowerCase()}'))
        .map((e) => e.key)
        .toList();
  }

  @override
  void dispose() {
    if (ActiveGroupChatTracker.activeGroupId == widget.groupId) {
      ActiveGroupChatTracker.activeGroupId = null;
    }
    TtsService.instance.stop().ignore();
    _service.markRead(widget.groupId, widget.currentUid).ignore();
    _groupSub?.cancel();
    _starredSub?.cancel();
    _typingStopTimer?.cancel();
    _saveDraft().ignore();
    _setTyping(false);
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
      await _playFromCacheOrUrl(msg.audioUrl!);
    }
  }

  /// Plays from the locally cached file when available (instant, offline) and
  /// falls back to streaming from the URL.
  Future<void> _playFromCacheOrUrl(String url) async {
    final file = await getCachedMediaFile(url);
    if (file != null) {
      await _player.play(DeviceFileSource(file.path));
    } else {
      await _player.play(UrlSource(url));
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
        _playFromCacheOrUrl(m.audioUrl!).ignore();
        return;
      }
    }
  }

  Future<void> _seekAudio(Duration position) async {
    await _player.seek(position);
    _positionNotifier.value = position;
  }

  Future<void> _saveToGallery(String url, String messageId,
      {required bool isVideo}) async {
    // Reuse the cached file (no re-download) and save into the gallery.
    final saved = await MediaSaveService.saveReusingCache(
      url: url,
      messageId: messageId,
      kind: isVideo ? SavedMediaKind.video : SavedMediaKind.image,
    );
    if (saved != null && mounted) {
      setState(() => _savedPresent[messageId] = true);
    }
    if (!mounted) return;
    if (saved != null) {
      context.showSuccess('Saved to gallery');
    } else {
      context.showError('Save failed');
    }
  }

  Future<bool> _downloadAudio(MessageModel msg) async {
    if (msg.audioUrl == null) return false;
    // Reuse the locally cached file (no re-download) and save into Music.
    final saved = await MediaSaveService.saveReusingCache(
      url: msg.audioUrl!,
      messageId: msg.id,
      kind: SavedMediaKind.audio,
      fileName: msg.fileName,
    );
    if (saved != null && mounted) {
      setState(() => _savedPresent[msg.id] = true);
    }
    if (!mounted) return saved != null;
    if (saved != null) {
      context.showSuccess('Saved to Music');
    } else {
      context.showError('Download failed');
    }
    return saved != null;
  }

  // Tracks which media messages are saved to the device (and still present).
  // Checked lazily per session; existsFor() self-heals if the file was deleted.
  final Map<String, bool> _savedPresent = {};

  void _ensureSavedChecked(String messageId) {
    if (_savedPresent.containsKey(messageId)) return;
    _savedPresent[messageId] = false;
    SavedMediaStore.existsFor(messageId).then((present) {
      if (present && mounted) setState(() => _savedPresent[messageId] = true);
    });
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
    if (!_scrollCtrl.hasClients) return;
    // Reached the bottom — clear the "new messages" button.
    if (_showJumpToBottom && _scrollCtrl.position.pixels <= 80) {
      setState(() {
        _showJumpToBottom = false;
        _unseenCount = 0;
      });
    }
    if (!_hasMore || _isLoadingMore) return;
    // reverse:true: top = maxScrollExtent. Trigger load-more when approaching top.
    if (_scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 250) {
      _loadMoreMessages();
    }
  }

  void _jumpToNewMessages() {
    setState(() {
      _showJumpToBottom = false;
      _unseenCount = 0;
    });
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(0,
        duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  Widget _buildJumpToBottomButton() =>
      JumpToBottomButton(unseen: _unseenCount, onTap: _jumpToNewMessages);

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

  // Per-message keys + highlight for reply "jump to original message".
  final Map<String, GlobalKey> _messageKeys = {};
  String? _highlightedMessageId;
  List<MessageModel> _msgsDesc = const []; // current on-screen order (newest→oldest)

  /// Short preview label stored on a reply so media replies (voice, audio,
  /// image, video…) show a meaningful line instead of a blank one.
  String? _replyLabel(MessageModel? m) =>
      m == null ? null : replyLabelForMessage(m);

  Future<void> _scrollToMessage(String messageId) async {
    final key = _messageKeys[messageId];
    if (key?.currentContext != null) {
      await Scrollable.ensureVisible(key!.currentContext!,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut, alignment: 0.3);
      _highlightMessage(messageId);
      return;
    }
    // Not rendered — estimate an offset in the reverse list, then snap.
    final index = _msgsDesc.indexWhere((m) => m.id == messageId);
    if (index == -1 || !_scrollCtrl.hasClients) return;
    const avgItemHeight = 76.0;
    final estimated =
        (index * avgItemHeight).clamp(0.0, _scrollCtrl.position.maxScrollExtent);
    await _scrollCtrl.animateTo(estimated,
        duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
    await WidgetsBinding.instance.endOfFrame;
    if (key?.currentContext != null) {
      await Scrollable.ensureVisible(key!.currentContext!,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut, alignment: 0.3);
    }
    _highlightMessage(messageId);
  }

  void _highlightMessage(String messageId) {
    setState(() => _highlightedMessageId = messageId);
    Future.delayed(const Duration(milliseconds: 3500), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
  }

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
        replyToText: _replyLabel(reply),
        replyToImageUrl: reply?.imageUrl,
        replyToSenderId: reply?.senderId,
        replyToSenderName: reply?.senderName,
        mentions: _extractMentions(text),
      );
    } catch (e) {
      debugPrint('sendText error: $e');
      _queueFailed(pending);
      if (mounted) { setState(() => _pending.remove(pending)); context.showError('Failed to send — queued for retry'); }
      return;
    }
    if (mounted) setState(() => _pending.remove(pending));
  }

  // ── Send image ────────────────────────────────────────────────────────────

  Future<void> _pickImage(ImageSource source) async {
    Navigator.pop(context);
    final xfile = await _imagePicker.pickImage(source: source, imageQuality: 75);
    if (xfile == null || _group == null || !mounted) return;

    // Editor (crop/draw) + optional caption before sending.
    final edited = await Navigator.push<ImageEditResult>(
      context,
      MaterialPageRoute(
          builder: (_) => ImageEditScreen(imageFile: File(xfile.path))),
    );
    if (edited == null || _group == null || !mounted) return;
    final file = edited.file;
    final caption = edited.caption;
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
        text: caption,
        replyToId: reply?.id,
        replyToText: _replyLabel(reply),
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
        replyToText: _replyLabel(reply),
        replyToImageUrl: reply?.imageUrl,
        replyToSenderId: reply?.senderId,
        replyToSenderName: reply?.senderName,
      );
    } catch (e) {
      debugPrint('sendKeyboardContent error: $e');
      _queueFailed(pending);
      if (mounted) { setState(() => _pending.remove(pending)); context.showError('Failed to send — queued for retry'); }
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

    final caption = await showCaptionSheet(context);
    if (caption == null || !mounted || _group == null) return;
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
        text: caption.isEmpty ? null : caption,
        replyToId: reply?.id,
        replyToText: _replyLabel(reply),
        replyToImageUrl: reply?.imageUrl,
        replyToSenderId: reply?.senderId,
        replyToSenderName: reply?.senderName,
      );
    } catch (e) {
      debugPrint('sendVideo error: $e');
      _queueFailed(pending);
      if (mounted) { setState(() => _pending.remove(pending)); context.showError('Failed to send video — queued for retry'); }
      return;
    }
    if (mounted) setState(() => _pending.remove(pending));
  }

  // ── Send audio file ─────────────────────────────────────────────────────────

  Future<void> _pickAudioFile() async {
    Navigator.pop(context);
    final result = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (result == null || result.files.isEmpty || !mounted || _group == null) return;
    final picked = result.files.single;
    if (picked.path == null) return;

    final dur = await _probeAudioDuration(picked.path!);
    if (!mounted || _group == null) return;

    final file = File(picked.path!);
    final reply = _replyingTo;
    _cancelReply();
    final pending = _PendingItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: MessageType.audioFile,
      localFile: file,
      fileName: picked.name,
      fileSizeBytes: picked.size,
      voiceDuration: dur,
    );
    setState(() => _pending.add(pending));
    _scrollToBottom();
    try {
      final senderName = _nameCache[widget.currentUid] ?? widget.currentUid;
      await _service.sendAudioFileMessage(
        groupId: widget.groupId,
        senderId: widget.currentUid,
        senderName: senderName,
        participants: _group!.participants,
        audioFile: file,
        fileName: picked.name,
        fileSizeBytes: picked.size,
        durationSeconds: dur,
        replyToId: reply?.id,
        replyToText: _replyLabel(reply),
        replyToSenderId: reply?.senderId,
        replyToSenderName: reply?.senderName,
      );
    } catch (e) {
      debugPrint('sendAudioFile error: $e');
      _queueFailed(pending);
      if (mounted) { setState(() => _pending.remove(pending)); context.showError('Failed to send audio — queued for retry'); }
      return;
    }
    if (mounted) setState(() => _pending.remove(pending));
  }

  /// Any file type — the receiving device opens it with whatever app handles
  /// that extension.
  Future<void> _pickDocument() async {
    Navigator.pop(context);
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null || result.files.isEmpty || !mounted || _group == null) {
      return;
    }
    final picked = result.files.single;
    if (picked.path == null) return;

    const maxBytes = 50 * 1024 * 1024;
    if (picked.size > maxBytes) {
      context.showError('File is too large (max 50 MB)');
      return;
    }

    final file = File(picked.path!);
    final reply = _replyingTo;
    _cancelReply();
    final pending = _PendingItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: MessageType.document,
      localFile: file,
      fileName: picked.name,
      fileSizeBytes: picked.size,
    );
    setState(() => _pending.add(pending));
    _scrollToBottom();
    try {
      final senderName = _nameCache[widget.currentUid] ?? widget.currentUid;
      await _service.sendDocumentMessage(
        groupId: widget.groupId,
        senderId: widget.currentUid,
        senderName: senderName,
        participants: _group!.participants,
        file: file,
        fileName: picked.name,
        fileSizeBytes: picked.size,
        replyToId: reply?.id,
        replyToText: _replyLabel(reply),
        replyToSenderId: reply?.senderId,
        replyToSenderName: reply?.senderName,
      );
    } catch (e) {
      debugPrint('sendDocument error: $e');
      _queueFailed(pending);
      if (mounted) {
        setState(() => _pending.remove(pending));
        context.showError('Failed to send document — queued for retry');
      }
      return;
    }
    if (mounted) setState(() => _pending.remove(pending));
  }

  // Best-effort duration probe so the bubble can show total time before play.
  Future<int> _probeAudioDuration(String path) async {
    final probe = AudioPlayer();
    try {
      await probe.setSource(DeviceFileSource(path));
      for (var i = 0; i < 10; i++) {
        final d = await probe.getDuration();
        if (d != null && d.inMilliseconds > 0) return d.inSeconds;
        await Future.delayed(const Duration(milliseconds: 100));
      }
    } catch (_) {
    } finally {
      await probe.dispose();
    }
    return 0;
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
        replyToText: _replyLabel(reply),
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
        replyToText: _replyLabel(reply),
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
              replyToText: _replyLabel(reply),
              replyToImageUrl: reply?.imageUrl,
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
        child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 36, height: 4, margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
          ),
          ReactionPickerRow(
            current: msg.reactions[widget.currentUid],
            onPick: (emoji) {
              Navigator.pop(ctx);
              _service.toggleReaction(
                groupId: widget.groupId,
                messageId: msg.id,
                reactorUid: widget.currentUid,
                emoji: emoji,
                current: msg.reactions[widget.currentUid],
              ).ignore();
            },
          ),
          const Divider(height: 12),
          ListTile(
            leading: const Icon(Icons.reply_rounded),
            title: const Text('Reply'),
            onTap: () { Navigator.pop(ctx); setState(() => _replyingTo = msg); },
          ),
          ListTile(
            leading: const Icon(Icons.shortcut_rounded),
            title: const Text('Forward'),
            onTap: () { Navigator.pop(ctx); _forwardMessage(msg); },
          ),
          ListTile(
            leading: Icon(
              _starredIds.contains(msg.id)
                  ? Icons.star_rounded
                  : Icons.star_outline_rounded,
              color: Colors.amber.shade700,
            ),
            title: Text(_starredIds.contains(msg.id) ? 'Unstar' : 'Star'),
            onTap: () { Navigator.pop(ctx); _toggleStar(msg); },
          ),
          ListTile(
            leading: Icon(
              _pinnedMessageId == msg.id
                  ? Icons.push_pin_rounded
                  : Icons.push_pin_outlined,
            ),
            title: Text(_pinnedMessageId == msg.id ? 'Unpin' : 'Pin'),
            onTap: () { Navigator.pop(ctx); _togglePin(msg); },
          ),
          if (msg.type == MessageType.text && isSpeakable(msg.text ?? ''))
            ListTile(
              leading: const Icon(Icons.volume_up_rounded,
                  color: AppColors.primary),
              title: const Text('Read aloud'),
              onTap: () {
                Navigator.pop(ctx);
                TtsService.instance.speak(msg.id, msg.text!);
              },
            ),
          if (msg.type == MessageType.text && (msg.text ?? '').isNotEmpty)
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: msg.text!));
                context.showSuccess('Copied');
              },
            ),
          if ((msg.type == MessageType.image || msg.type == MessageType.gif) &&
              msg.imageUrl != null)
            ListTile(
              leading: const Icon(Icons.download_rounded),
              title: const Text('Save to Gallery'),
              onTap: () {
                Navigator.pop(ctx);
                _saveToGallery(msg.imageUrl!, msg.id, isVideo: false);
              },
            ),
          if (msg.type == MessageType.video && msg.videoUrl != null)
            ListTile(
              leading: const Icon(Icons.download_rounded),
              title: const Text('Save to Gallery'),
              onTap: () {
                Navigator.pop(ctx);
                _saveToGallery(msg.videoUrl!, msg.id, isVideo: true);
              },
            ),
          if (isMine && msg.type == MessageType.text)
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('Edit'),
              onTap: () { Navigator.pop(ctx); _editMessage(msg); },
            ),
          ListTile(
            leading: const Icon(Icons.delete_rounded, color: Colors.red),
            title: const Text('Delete', style: TextStyle(color: Colors.red)),
            onTap: () { Navigator.pop(ctx); _deleteMessage(msg, isMine: isMine); },
          ),
        ]),
        ),
      ),
    );
  }

  void _openSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MessageSearchScreen(
          title: _group?.name ?? widget.initialName,
          onSearch: (q) => _service.searchMessages(widget.groupId, q),
          onOpen: (m) => _scrollToMessage(m.id),
        ),
      ),
    );
  }

  void _openStarred() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StarredMessagesScreen(uid: widget.currentUid),
      ),
    );
  }

  /// Persists a failed send so it survives leaving the screen or the app being
  /// killed. GIFs and stickers are skipped — they carry no local file and are
  /// trivial to re-send by hand.
  void _queueFailed(_PendingItem item, {String? text}) {
    if (item.type == MessageType.gif || item.type == MessageType.sticker) return;
    unawaited(OutboxService.instance.enqueue(OutboxEntry(
      id: item.id,
      type: item.type,
      senderUid: widget.currentUid,
      groupId: widget.groupId,
      senderName: _nameCache[widget.currentUid] ?? widget.currentUid,
      participants: _group?.participants ?? const [],
      text: text ?? item.text,
      localPath: item.localFile?.path,
      fileName: item.fileName,
      fileSizeBytes: item.fileSizeBytes,
      durationSeconds: item.voiceDuration,
    )));
  }

  // ── New message actions ────────────────────────────────────────────────────

  Future<void> _forwardMessage(MessageModel msg) async {
    final target = await showForwardSheet(context, currentUid: widget.currentUid);
    if (target == null || !mounted) return;
    final myName = context.read<AppProvider>().profile?.name ?? '';
    try {
      if (target.isGroup) {
        await _service.forwardMessage(
          source: msg,
          groupId: target.group!.id,
          senderId: widget.currentUid,
          senderName: myName,
          participants: target.group!.participants,
          preview: ChatService.messagePreview(msg),
        );
      } else {
        await ChatService().forwardMessage(
          source: msg,
          senderUid: widget.currentUid,
          receiverUid: target.user!.uid,
        );
      }
      if (mounted) context.showSuccess('Forwarded to ${target.label}');
    } catch (_) {
      if (mounted) context.showError('Could not forward message');
    }
  }

  Future<void> _toggleStar(MessageModel msg) async {
    final chatService = ChatService();
    try {
      if (_starredIds.contains(msg.id)) {
        await chatService.unstarMessage(widget.currentUid, msg.id);
        if (mounted) context.showSuccess('Removed from starred');
      } else {
        await chatService.starMessage(
          uid: widget.currentUid,
          msg: msg,
          chatLabel: _group?.name ?? widget.initialName,
        );
        if (mounted) context.showSuccess('Starred');
      }
    } catch (_) {
      if (mounted) context.showError('Could not update starred messages');
    }
  }

  Future<void> _togglePin(MessageModel msg) async {
    try {
      if (_pinnedMessageId == msg.id) {
        await _service.unpinMessage(widget.groupId);
      } else {
        await _service.pinMessage(
          groupId: widget.groupId,
          msg: msg,
          pinnedBy: widget.currentUid,
          preview: ChatService.messagePreview(msg),
        );
      }
    } catch (_) {
      if (mounted) context.showError('Could not update the pinned message');
    }
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

  /// "For everyone" is offered only on your own messages.
  Future<void> _deleteMessage(MessageModel msg, {required bool isMine}) async {
    final choice =
        await showDeleteChoice(context, canDeleteForEveryone: isMine);
    if (choice == null || !mounted) return;

    if (choice == DeleteChoice.forMe) {
      await _service.deleteMessageForMe(
          widget.groupId, msg.id, widget.currentUid);
      return;
    }

    {
      await _service.deleteMessage(
        widget.groupId,
        msg.id,
        audioUrl: msg.audioUrl,
        imageUrl: msg.imageUrl,
        videoUrl: msg.videoUrl,
        videoThumbUrl: msg.videoThumbUrl,
        documentUrl: msg.documentUrl,
      );
      if (_pinnedMessageId == msg.id) {
        await _service.unpinMessage(widget.groupId);
      }
      evictMediaFromCache(
          [msg.audioUrl, msg.imageUrl, msg.videoUrl, msg.videoThumbUrl, msg.documentUrl]);
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
              leading: _attachIcon(Icons.audiotrack_rounded),
              title: const Text('Audio'),
              onTap: _pickAudioFile,
            ),
            ListTile(
              leading: _attachIcon(Icons.description_rounded),
              title: const Text('Document'),
              subtitle: const Text('PDF, Word, Excel, and more',
                  style: TextStyle(fontSize: 11)),
              onTap: _pickDocument,
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
      if (_pinnedText != null && _pinnedText!.isNotEmpty)
        PinnedBanner(
          text: _pinnedText!,
          onTapJump: () {
            final id = _pinnedMessageId;
            if (id != null) _scrollToMessage(id);
          },
          onUnpin: () => _service.unpinMessage(widget.groupId).ignore(),
        ),
      // ── Messages ───────────────────────────────────────────────────────
      Expanded(
        child: Stack(children: [
          StreamBuilder<List<MessageModel>>(
          stream: _messagesStream,
          builder: (ctx, snap) {
            // Stream returns ascending (oldest first). Track oldest for load-more
            // cursor; newest (last) detects arrivals despite the capped window.
            final streamMsgs = snap.data ?? [];
            if (streamMsgs.isNotEmpty) {
              _streamOldest = streamMsgs.first.timestamp;
            }
            final newestId = streamMsgs.isNotEmpty ? streamMsgs.last.id : null;
            final newMessageArrived = _newestMsgId != null &&
                newestId != null &&
                newestId != _newestMsgId;
            if (newMessageArrived && !_isLoadingMore && _scrollCtrl.hasClients) {
              if (_scrollCtrl.position.pixels <= 300) {
                // At/near the bottom — keep following new messages.
                _scrollToBottom();
              } else {
                // Scrolled up — hold position and surface the jump button.
                final pixelsBefore = _scrollCtrl.position.pixels;
                final maxBefore = _scrollCtrl.position.maxScrollExtent;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted || !_scrollCtrl.hasClients) return;
                  final delta = _scrollCtrl.position.maxScrollExtent - maxBefore;
                  if (delta != 0) {
                    _scrollCtrl.jumpTo((pixelsBefore + delta)
                        .clamp(0.0, _scrollCtrl.position.maxScrollExtent));
                  }
                });
                if (streamMsgs.last.senderId != widget.currentUid) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() {
                      _showJumpToBottom = true;
                      _unseenCount++;
                    });
                  });
                }
              }
            }
            if (newMessageArrived) {
              // New messages arrived while screen is open — mark as read.
              _service.markRead(widget.groupId, widget.currentUid).ignore();
              // Read it aloud if the user turned that on. Guarded on arrival
              // so an unrelated rebuild does not repeat the message.
              final latest = streamMsgs.last;
              if (latest.senderId != widget.currentUid &&
                  latest.type == MessageType.text &&
                  !latest.isDeleted) {
                TtsService.instance
                    .maybeAutoRead(latest.id, latest.text ?? '')
                    .ignore();
              }
            }
            _newestMsgId = newestId;
            // markRead is also called in initState and dispose.

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

            // Merge: older pages first, then the live stream window — both are
            // ascending, and the older pages are chronologically before the
            // stream, so they must come first to keep the list sorted.
            final streamIds = streamMsgs.map((m) => m.id).toSet();
            final olderFiltered =
                _olderMessages.where((m) => !streamIds.contains(m.id)).toList();
            // Messages this user removed for themselves remain in Firestore
            // for everyone else but must never appear here.
            final allMsgs = [...olderFiltered, ...streamMsgs]
                .where((m) => !m.isHiddenFor(widget.currentUid))
                .toList(); // ascending
            _allMessages = allMsgs; // kept for auto-play lookups

            // Prefetch visible image/video/audio/voice media so it displays and
            // plays instantly and stays cached locally for ~24h.
            MediaPrefetcher.prefetch(streamMsgs.map((m) {
              switch (m.type) {
                case MessageType.image:
                case MessageType.gif:
                  return m.imageUrl;
                case MessageType.video:
                  return m.videoUrl;
                case MessageType.voice:
                case MessageType.audioFile:
                  return m.audioUrl;
                default:
                  return null;
              }
            }));

            // Reverse for the reverse:true ListView (index 0 = newest = bottom).
            final msgsDesc = allMsgs.reversed.toList();
            _msgsDesc = msgsDesc; // for reply "jump to message" lookups

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

                if (msg.type == MessageType.audioFile) {
                  _ensureSavedChecked(msg.id);
                }

                final rowKey = _messageKeys.putIfAbsent(msg.id, () => GlobalKey());
                return AnimatedContainer(
                  key: rowKey,
                  duration: const Duration(milliseconds: 300),
                  color: _highlightedMessageId == msg.id
                      ? AppColors.primary.withValues(alpha: 0.40)
                      : Colors.transparent,
                  child: Column(children: [
                  _SwipeToReply(
                    onReply: () => setState(() => _replyingTo = msg),
                    child: GestureDetector(
                      onLongPress: msg.isDeleted
                          ? null
                          : () {
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
                        onDownloadAudio: _downloadAudio,
                        isSaved: _savedPresent[msg.id] ?? false,
                        onReply: () => setState(() => _replyingTo = msg),
                        onReplyTap: msg.replyToId == null
                            ? null
                            : () => _scrollToMessage(msg.replyToId!),
                        allMessages: allMsgs,
                        tickWidget: isMine ? _buildTick(msg) : null,
                      ),
                    ),
                  ),
                  if (msg.reactions.isNotEmpty)
                    Align(
                      alignment:
                          isMine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.only(
                            left: isMine ? 0 : 48, right: isMine ? 8 : 0),
                        child: ReactionChips(
                          reactions: msg.reactions,
                          onTap: () => _onLongPress(msg),
                        ),
                      ),
                    ),
                  if (divider != null) divider,
                ]),
                );
              },
            );
          },
          ),
          if (_showJumpToBottom)
            Positioned(
                right: 12, bottom: 12, child: _buildJumpToBottomButton()),
        ]),
      ),

      if (_typingNames.isNotEmpty)
        TypingIndicator(
          label: _typingNames.length == 1
              ? '${_typingNames.first} is typing…'
              : '${_typingNames.length} people are typing…',
        ),

      // Mention autocomplete sits directly above the composer so the caret and
      // the choices stay in the same field of view.
      if (_mentionSuggestions.isNotEmpty)
        Container(
          constraints: const BoxConstraints(maxHeight: 168),
          color: Colors.white,
          child: ListView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: _mentionSuggestions.length,
            itemBuilder: (ctx, i) {
              final e = _mentionSuggestions[i];
              return ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 15,
                  backgroundColor: AppColors.primary,
                  backgroundImage: _photoCache[e.key] != null
                      ? avatarImage(_photoCache[e.key]!, radius: 15)
                      : null,
                  child: _photoCache[e.key] == null
                      ? Text(
                          e.value.isNotEmpty ? e.value[0].toUpperCase() : '?',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                        )
                      : null,
                ),
                title: Text(e.value, style: const TextStyle(fontSize: 14)),
                onTap: () => _applyMention(e.key, e.value),
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

    // On a tablet keep the conversation column a readable width and centred.
    // Applied before the wallpaper wrap so the background still fills the screen.
    body = ContentWidth(maxWidth: 900, child: body);

    final bgImageUrl = _group?.backgroundImageUrl;
    final bgColorVal = _group?.backgroundColor;

    if (bgImageUrl == null && bgColorVal == null) {
      body = ChatCanvas(child: body);
    }

    if (bgImageUrl != null) {
      body = Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: CachedNetworkImageProvider(bgImageUrl,
                maxWidth: 1080),
            fit: BoxFit.cover,
          ),
        ),
        child: body,
      );
    }

    return Scaffold(
      backgroundColor: bgColorVal != null ? Color(bgColorVal) : _defaultBgColor,
      appBar: AppBar(
        titleSpacing: widget.embedded ? 16 : 0,
        automaticallyImplyLeading: !widget.embedded,
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: const ChatHeaderBackground(),
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
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.55), width: 1.5),
                ),
                child: CircleAvatar(
                  radius: 19,
                  backgroundColor: Colors.white.withValues(alpha: 0.22),
                  backgroundImage: group?.iconUrl != null
                      ? avatarImage(group!.iconUrl!, radius: 19) : null,
                  child: group?.iconUrl == null
                      ? const Icon(Icons.groups_rounded,
                          color: Colors.white, size: 22)
                      : null,
                ),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(groupName,
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.1),
                    overflow: TextOverflow.ellipsis),
                if (memberCount > 0)
                  Text('$memberCount members',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Colors.white.withValues(alpha: 0.75))),
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
              if (v == 'search') _openSearch();
              if (v == 'starred') _openStarred();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'search',
                child: Row(children: [
                  Icon(Icons.search_rounded, size: 20, color: Colors.grey.shade700),
                  const SizedBox(width: 10),
                  const Text('Search messages'),
                ]),
              ),
              PopupMenuItem(
                value: 'starred',
                child: Row(children: [
                  Icon(Icons.star_outline_rounded, size: 20, color: Colors.grey.shade700),
                  const SizedBox(width: 10),
                  const Text('Starred messages'),
                ]),
              ),
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

    if (item.type == MessageType.audioFile) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.all(10),
          constraints: BoxConstraints(maxWidth: context.bubbleMaxWidth),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 32, height: 32,
              decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
              child: const Icon(Icons.audiotrack_rounded, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(item.fileName ?? 'Audio',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
            const SizedBox(width: 10),
            item.status == _PendingStatus.failed
                ? const Icon(Icons.error_outline_rounded, color: Colors.red, size: 16)
                : const SizedBox(width: 12, height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white70)),
          ]),
        ),
      );
    }

    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.all(10),
        constraints: BoxConstraints(maxWidth: context.bubbleMaxWidth),
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
                              imageUrl: item.gifUrl!,
                              memCacheWidth: 540,
                              width: 180, height: 140, fit: BoxFit.cover),
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
  final Future<bool> Function(MessageModel) onDownloadAudio;
  final bool isSaved;
  final VoidCallback onReply;
  final VoidCallback? onReplyTap;
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
    required this.onDownloadAudio,
    this.isSaved = false,
    required this.onReply,
    this.onReplyTap,
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
                backgroundImage: photoUrl != null ? avatarImage(photoUrl!, radius: 14) : null,
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

    // A message that is only 1-3 emoji is shown large, without a bubble.
    final jumbo = !msg.isDeleted &&
            msg.type == MessageType.text &&
            msg.replyToId == null
        ? jumboEmojiCount(msg.text ?? '')
        : 0;
    if (jumbo > 0) {
      return Padding(
        padding: EdgeInsets.only(top: showSenderInfo ? 8 : 2, bottom: 1),
        child: Row(
          mainAxisAlignment:
              isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (showSenderInfo) ...[
              CircleAvatar(
                radius: 15,
                backgroundColor: _colorForName(senderName),
                backgroundImage:
                    photoUrl != null ? avatarImage(photoUrl!, radius: 15) : null,
                child: photoUrl == null
                    ? Text(senderName.isNotEmpty ? senderName[0].toUpperCase() : '?',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold))
                    : null,
              ),
              const SizedBox(width: 7),
            ],
            Column(
              crossAxisAlignment:
                  isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showSenderInfo)
                  Text(senderName,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _colorForName(senderName))),
                Text(msg.text!.trim(),
                    style: TextStyle(
                        fontSize: jumboEmojiSize(jumbo), height: 1.15)),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: BubbleMeta(
                      time: msg.timestamp, isMe: false, ticks: tickWidget),
                ),
              ],
            ),
            if (isMine) const SizedBox(width: 6),
          ],
        ),
      );
    }

    // Named users (Buji/Harry/Sandy) always use their fixed color regardless
    // of whether the message is mine or from someone else.
    final namedColor = _namedColors[senderName.toLowerCase()];
    final textColor = (namedColor != null || isMine) ? Colors.white : ChatStyle.ink;
    final isMedia = !msg.isDeleted &&
        (msg.type == MessageType.image ||
            msg.type == MessageType.gif ||
            msg.type == MessageType.video);

    return Padding(
      padding: EdgeInsets.only(top: showSenderInfo ? 8 : 2, bottom: 1),
      child: Row(
        mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (showSenderInfo) ...[
            CircleAvatar(
              radius: 15,
              backgroundColor: _colorForName(senderName),
              backgroundImage: photoUrl != null ? avatarImage(photoUrl!, radius: 15) : null,
              child: photoUrl == null
                  ? Text(senderName.isNotEmpty ? senderName[0].toUpperCase() : '?',
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold))
                  : null,
            ),
            const SizedBox(width: 7),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Container(
                  constraints: BoxConstraints(maxWidth: context.bubbleMaxWidth),
                  child: BubbleFrame(
                    isMe: isMine,
                    color: namedColor,
                    padding: isMedia ? const EdgeInsets.all(4) : EdgeInsets.zero,
                    child: Column(
                      // Media fills the bubble's width; text bubbles hug
                      // their text, or every "ok" would be full width.
                      crossAxisAlignment: isMedia
                          ? CrossAxisAlignment.stretch
                          : CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // The name rides inside the first bubble of a run.
                        if (showSenderInfo)
                          Padding(
                            padding: isMedia
                                ? const EdgeInsets.fromLTRB(8, 4, 8, 4)
                                : const EdgeInsets.fromLTRB(13, 8, 12, 0),
                            child: Text(senderName,
                                style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: namedColor != null
                                        ? Colors.white.withValues(alpha: 0.9)
                                        : _colorForName(senderName))),
                          ),
                        if (msg.replyToId != null)
                          Padding(
                            padding: isMedia
                                ? const EdgeInsets.fromLTRB(2, 2, 2, 5)
                                : const EdgeInsets.fromLTRB(8, 8, 8, 0),
                            child: _ReplyPreview(
                              msg: msg,
                              isMine: isMine || namedColor != null,
                              allMessages: allMessages,
                              onTap: onReplyTap,
                            ),
                          ),
                        Padding(
                          padding: isMedia
                              ? EdgeInsets.zero
                              : const EdgeInsets.fromLTRB(13, 8, 12, 7),
                          child: _buildContent(context, textColor),
                        ),
                      ],
                    ),
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
    final onDark = textColor == Colors.white;
    final timeRow = BubbleMeta(
      time: msg.timestamp,
      isMe: onDark,
      edited: msg.isEdited,
      ticks: tickWidget,
      leading: [
        if (!msg.isDeleted && msg.type == MessageType.text) ...[
          SpeakButton(messageId: msg.id, text: msg.text ?? '', onDark: onDark),
          const SizedBox(width: 2),
        ],
      ],
    );

    // A tombstone replaces whatever the message used to be.
    if (msg.isDeleted) {
      return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        DeletedBubble(isMe: isMine),
        const SizedBox(height: 2),
        timeRow,
      ]);
    }

    switch (msg.type) {
      case MessageType.document:
        return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          DocumentBubble(
            fileName: msg.fileName ?? 'Document',
            sizeBytes: msg.fileSizeBytes,
            isMe: isMine,
            onOpen: () {
              final url = msg.documentUrl;
              if (url == null || url.isEmpty) return;
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)
                  .then((ok) {
                if (!ok && context.mounted) {
                  context.showError('No app can open this file');
                }
              });
            },
          ),
          const SizedBox(height: 3),
          timeRow,
        ]);

      case MessageType.text:
        return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Align(
            alignment: Alignment.centerLeft,
            widthFactor: 1,
            child: LinkableText(
              text: msg.text ?? '',
              style: ChatStyle.body(onDark).copyWith(color: textColor),
            ),
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
      case MessageType.gif:
      case MessageType.video:
        return _buildMedia(context, textColor);

      case MessageType.sticker:
        // Handled by early return in build() — never reaches here.
        return const SizedBox.shrink();

      case MessageType.voice:
        // Use white colors whenever the bubble background is dark (named-color
        // or own message). textColor is already Colors.white for dark bubbles.
        return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          VoiceMessagePlayer(
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
          ),
          const SizedBox(height: 2),
          timeRow,
        ]);

      case MessageType.audioFile:
        return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          AudioFileMessage(
            messageId: msg.id,
            audioUrl: msg.audioUrl,
            fileName: msg.fileName ?? 'Audio',
            fileSizeBytes: msg.fileSizeBytes,
            totalSeconds: msg.audioDurationSeconds ?? 0,
            isMine: textColor == Colors.white,
            isSaved: isSaved,
            playingIdNotifier: playingIdNotifier,
            isPlayingNotifier: isPlayingNotifier,
            positionNotifier: positionNotifier,
            durationNotifier: durationNotifier,
            onToggle: onToggleVoice,
            onSeek: onSeekAudio,
            onDownload: () => onDownloadAudio(msg),
          ),
          const SizedBox(height: 2),
          timeRow,
        ]);

    }
  }

  /// Photo, GIF or video, inset in the bubble with the caption inside it.
  Widget _buildMedia(BuildContext context, Color textColor) {
    final onDark = textColor == Colors.white;
    final hasCaption =
        msg.type != MessageType.gif && (msg.text?.isNotEmpty ?? false);
    final Widget media;
    if (msg.type == MessageType.video && msg.videoUrl != null) {
      media = VideoPreview(
        videoUrl: msg.videoUrl!,
        thumbUrl: msg.videoThumbUrl,
        durationMs: msg.videoDurationMs,
        isMe: onDark,
        onTap: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => FullScreenVideoViewer(
                url: msg.videoUrl!, messageId: msg.id))),
      );
    } else if (msg.imageUrl != null) {
      media = BubblePhoto(
        url: msg.imageUrl!,
        isMe: onDark,
        onTap: msg.type == MessageType.gif
            ? null
            : () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => FullScreenImageViewer(
                    url: msg.imageUrl!, messageId: msg.id))),
      );
    } else {
      media = const SizedBox(height: 120);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(children: [
          media,
          if (!hasCaption)
            Positioned(
              right: 8,
              bottom: 8,
              child: BubbleMeta(
                time: msg.timestamp,
                isMe: onDark,
                ticks: tickWidget,
                onMedia: true,
              ),
            ),
        ]),
        if (hasCaption)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: LinkableText(
                    text: msg.text!,
                    style: ChatStyle.body(onDark).copyWith(color: textColor),
                  ),
                ),
                const SizedBox(height: 3),
                BubbleMeta(
                  time: msg.timestamp,
                  isMe: onDark,
                  edited: msg.isEdited,
                  ticks: tickWidget,
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _fmtTime(DateTime dt) => DateFormat('h:mm a').format(dt);
}

// ── Reply preview ─────────────────────────────────────────────────────────────

/// Short preview label for a replied-to message (media get a typed label so the
/// snippet is never blank).
String replyLabelForMessage(MessageModel m) {
  if (m.isDeleted) return '🚫 This message was deleted';
  switch (m.type) {
    case MessageType.voice:     return '🎤 Voice message';
    case MessageType.audioFile: return '🎵 ${m.fileName ?? 'Audio'}';
    case MessageType.document:  return '📄 ${m.fileName ?? 'Document'}';
    case MessageType.image:     return '📷 Photo';
    case MessageType.gif:       return '🎞️ GIF';
    case MessageType.sticker:   return m.text ?? '😊 Sticker';
    case MessageType.video:     return '🎬 Video';
    case MessageType.text:      return m.text ?? '';
  }
}

class _ReplyPreview extends StatelessWidget {
  final MessageModel msg;
  final bool isMine;
  final VoidCallback? onTap;
  final List<MessageModel> allMessages;
  const _ReplyPreview({
    required this.msg,
    required this.isMine,
    required this.allMessages,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final name = msg.replyToSenderName ?? msg.replyToSenderId ?? '';

    // Resolve the actual replied-to message when it's loaded, so we can show a
    // real thumbnail and always derive a correct label (even for older
    // replies whose stored text was blank).
    MessageModel? replied;
    for (final m in allMessages) {
      if (m.id == msg.replyToId) {
        replied = m;
        break;
      }
    }

    final String? thumbUrl = replied != null
        ? switch (replied.type) {
            MessageType.image || MessageType.gif => replied.imageUrl,
            MessageType.video => replied.videoThumbUrl,
            _ => null,
          }
        : msg.replyToImageUrl;

    final String label = replied != null
        ? replyLabelForMessage(replied)
        : ((msg.replyToText == null || msg.replyToText!.isEmpty)
            ? 'Message'
            : msg.replyToText!);

    return ReplyQuote(
      label: name.isNotEmpty ? name : 'Message',
      text: label,
      isMe: isMine,
      imageUrl: thumbUrl,
      thumbBase64: msg.replyToThumb,
      isVideo: replied?.type == MessageType.video ||
          ReplyQuote.looksLikeVideo(label),
      onTap: onTap,
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
      case MessageType.voice:     return '🎤 Voice message';
      case MessageType.audioFile: return '🎵 ${m.fileName ?? 'Audio'}';
      case MessageType.document:  return '📄 ${m.fileName ?? 'Document'}';
      case MessageType.image:     return '📷 Photo';
      case MessageType.gif:       return '🎞️ GIF';
      case MessageType.sticker:   return m.text ?? '😊 Sticker';
      case MessageType.video:     return '🎬 Video';
      case MessageType.text:      return m.text ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = msg.senderName ?? msg.senderId;
    final String? thumbUrl = switch (msg.type) {
      MessageType.image || MessageType.gif => msg.imageUrl,
      MessageType.video => msg.videoThumbUrl,
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      child: Container(
        decoration: composerDecoration(),
        padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
        child: Row(children: [
          Expanded(
            child: ReplyQuote(
              label: 'Replying to $name',
              text: _replyPreview(msg),
              isMe: false,
              imageUrl: thumbUrl,
              isVideo: msg.type == MessageType.video,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20, color: ChatStyle.mist),
            onPressed: onCancel,
          ),
        ]),
      ),
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
    Widget icon(IconData data, VoidCallback onTap, {Color color = ChatStyle.mist}) =>
        GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(width: 40, height: 48, child: Icon(data, color: color, size: 24)),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: SafeArea(
        top: false,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Container(
              decoration: composerDecoration(),
              padding: const EdgeInsets.only(left: 4, right: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                icon(
                  showEmojiPicker ? Icons.keyboard_rounded : Icons.emoji_emotions_outlined,
                  onEmojiToggle,
                  color: showEmojiPicker ? ChatStyle.violet : ChatStyle.mist,
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    maxLines: 5, minLines: 1,
                    textCapitalization: TextCapitalization.sentences,
                    style: const TextStyle(fontSize: 15.5, color: ChatStyle.ink, height: 1.35),
                    // Receive stickers / GIFs inserted from the system keyboard
                    contentInsertionConfiguration: ContentInsertionConfiguration(
                      allowedMimeTypes: const [
                        'image/gif', 'image/jpeg', 'image/png', 'image/webp',
                      ],
                      onContentInserted: onKeyboardContent,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Message',
                      hintStyle: TextStyle(color: ChatStyle.mist, fontSize: 15.5),
                      filled: false,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 13),
                      border: InputBorder.none,
                    ),
                    // Settings → Chats → "Enter key sends". Without the
                    // send action a multi-line field never submits.
                    textInputAction: ChatPrefs.instance.enterSends
                        ? TextInputAction.send
                        : TextInputAction.newline,
                    onSubmitted:
                        ChatPrefs.instance.enterSends ? (_) => onSend() : null,
                  ),
                ),
                icon(Icons.attach_file_rounded, onAttach),
              ]),
            ),
          ),
          const SizedBox(width: 8),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (ctx, value, _) {
              final hasText = value.text.trim().isNotEmpty;
              if (hasText) {
                return GradientCircleButton(icon: Icons.send_rounded, onTap: onSend);
              }
              return GradientCircleButton(
                icon: isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                onTap: onMicTap,
                size: isRecording ? 56 : 50,
                color: isRecording ? AppColors.holiday : null,
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

  @override
  Widget build(BuildContext context) => DatePill(date: date);
}
