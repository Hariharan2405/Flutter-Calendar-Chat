import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../widgets/link_preview_widget.dart';
import '../widgets/voice_message_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/app_theme.dart';
import '../models/group_model.dart';
import '../models/message_model.dart';
import '../providers/app_provider.dart';
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
  final String? text;
  _PendingStatus status = _PendingStatus.sending;
  _PendingItem({required this.id, required this.type, this.localFile, this.text});
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
  String? _recordingPath;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;

  MessageModel? _replyingTo;
  final ValueNotifier<String?> _playingNotifier = ValueNotifier(null);
  final ValueNotifier<bool> _isPlayingNotifier = ValueNotifier(false);
  final ValueNotifier<Duration> _positionNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration?> _durationNotifier = ValueNotifier(null);
  int? _prevMsgCount;

  // Chat background
  static const _defaultBgColor = Color(0xFFF0EDF8);
  static const _bgColors = [
    Color(0xFFF0EDF8), Colors.white,   Color(0xFFE8F5E9), Color(0xFFE3F2FD),
    Color(0xFFFFF8E1), Color(0xFFFCE4EC), Color(0xFFEDE7F6), Color(0xFFE0F7FA),
    Color(0xFF1A1A2E), Color(0xFF2D2D44),
  ];
  Color? _bgColor;
  String? _bgImagePath;

  // Name/photo cache so we don't re-query per bubble
  final Map<String, String> _nameCache = {};
  final Map<String, String?> _photoCache = {};

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    ActiveGroupChatTracker.activeGroupId = widget.groupId;
    _messagesStream = _service.messages(widget.groupId);
    _groupStream = _service.watchGroup(widget.groupId);
    _groupSub = _groupStream.listen((g) {
      if (mounted && g != null) setState(() => _group = g);
    });
    _service.markRead(widget.groupId, widget.currentUid);
    _player.onPositionChanged.listen((pos) { _positionNotifier.value = pos; });
    _player.onDurationChanged.listen((dur) { _durationNotifier.value = dur; });
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        _playingNotifier.value = null;
        _isPlayingNotifier.value = false;
        _positionNotifier.value = Duration.zero;
        _durationNotifier.value = null;
      }
    });
    _loadBackground();
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

  Future<void> _loadBackground() async {
    final prefs = await SharedPreferences.getInstance();
    final colorVal = prefs.getInt('group_bg_color_${widget.groupId}');
    final imagePath = prefs.getString('group_bg_image_${widget.groupId}');
    if (mounted) {
      setState(() {
        _bgColor = colorVal != null ? Color(colorVal) : null;
        _bgImagePath = imagePath;
      });
    }
  }

  Future<void> _saveBgColor(Color color) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('group_bg_color_${widget.groupId}', color.toARGB32());
    await prefs.remove('group_bg_image_${widget.groupId}');
    if (mounted) setState(() { _bgColor = color; _bgImagePath = null; });
  }

  Future<void> _saveBgImage(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('group_bg_image_${widget.groupId}', path);
    await prefs.remove('group_bg_color_${widget.groupId}');
    if (mounted) setState(() { _bgImagePath = path; _bgColor = null; });
  }

  Future<void> _resetBackground() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('group_bg_color_${widget.groupId}');
    await prefs.remove('group_bg_image_${widget.groupId}');
    if (mounted) setState(() { _bgColor = null; _bgImagePath = null; });
  }

  void _showBackgroundPicker() {
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
              decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('Chat Background', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 10, runSpacing: 10,
                children: _bgColors.map((c) {
                  final selected = _bgColor?.toARGB32() == c.toARGB32() ||
                      (_bgColor == null && c.toARGB32() == _defaultBgColor.toARGB32());
                  return GestureDetector(
                    onTap: () { Navigator.pop(ctx); _saveBgColor(c); },
                    child: Container(
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                        color: c, shape: BoxShape.circle,
                        border: Border.all(
                          color: selected ? AppColors.primary : Colors.grey.shade300,
                          width: selected ? 3 : 1.5,
                        ),
                      ),
                      child: selected ? const Icon(Icons.check, size: 18, color: AppColors.primary) : null,
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
                  icon: const Icon(Icons.photo_library_rounded),
                  label: const Text('Gallery'),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    final file = await _imagePicker.pickImage(source: ImageSource.gallery);
                    if (file != null) _saveBgImage(file.path);
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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

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
    } catch (_) {
      if (mounted) setState(() => pending.status = _PendingStatus.failed);
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
    } catch (_) {
      if (mounted) setState(() => pending.status = _PendingStatus.failed);
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

  Future<void> _stopAndSendRecording() async {
    _recordingTimer?.cancel();
    await _recorder.stop();
    setState(() => _isRecording = false);
    if (_recordingPath == null || _group == null) return;
    final file = File(_recordingPath!);
    if (!file.existsSync()) return;
    final duration = _recordingSeconds;
    final reply = _replyingTo;
    _cancelReply();
    final pending = _PendingItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(), type: MessageType.voice);
    setState(() => _pending.add(pending));
    _scrollToBottom();
    try {
      final senderName = _nameCache[widget.currentUid] ?? widget.currentUid;
      await _service.sendVoiceMessage(
        groupId: widget.groupId,
        senderId: widget.currentUid,
        senderName: senderName,
        participants: _group!.participants,
        audioFile: file,
        durationSeconds: duration,
        replyToId: reply?.id,
        replyToText: reply?.text,
        replyToSenderId: reply?.senderId,
        replyToSenderName: reply?.senderName,
      );
    } catch (_) {
      if (mounted) setState(() => pending.status = _PendingStatus.failed);
      return;
    }
    if (mounted) setState(() => _pending.remove(pending));
  }

  Future<void> _cancelRecording() async {
    _recordingTimer?.cancel();
    await _recorder.stop();
    if (_recordingPath != null) {
      try { File(_recordingPath!).deleteSync(); } catch (_) {}
    }
    setState(() => _isRecording = false);
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

  // ── Attachment sheet ──────────────────────────────────────────────────────

  void _showAttachmentSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _AttachOption(icon: Icons.camera_alt_rounded, label: 'Camera',
                onTap: () => _pickImage(ImageSource.camera)),
            _AttachOption(icon: Icons.photo_library_rounded, label: 'Gallery',
                onTap: () => _pickImage(ImageSource.gallery)),
          ]),
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final group = _group;
    final groupName = group?.name ?? widget.initialName;
    final memberCount = group?.participants.length ?? 0;
    final isMuted = context.watch<AppProvider>().isGroupMuted(widget.groupId);

    if (group != null) {
      for (final uid in group.participants) {
        _nameCache.putIfAbsent(uid, () => uid);
      }
    }

    Widget body = Column(children: [
      // ── Messages ───────────────────────────────────────────────────────
      Expanded(
        child: StreamBuilder<List<MessageModel>>(
          stream: _messagesStream,
          builder: (ctx, snap) {
            final msgs = snap.data ?? [];
            if (_prevMsgCount != null && msgs.length > _prevMsgCount!) _scrollToBottom();
            _prevMsgCount = msgs.length;
            _service.markRead(widget.groupId, widget.currentUid);

            final allItems = [
              ...msgs.map((m) => _Item.msg(m)),
              ..._pending.map((p) => _Item.pending(p)),
            ];

            if (allItems.isEmpty) {
              return Center(
                child: Text('No messages yet\nSay hello!',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textSecondary.withValues(alpha: 0.6))),
              );
            }

            return ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: allItems.length,
              itemBuilder: (ctx, i) {
                final item = allItems[i];
                if (item.isPending) return _buildPendingBubble(item.pending!);

                final msg = item.msg!;
                final isMine = msg.senderId == widget.currentUid;

                Widget? divider;
                final prev = i > 0 ? allItems[i - 1].msg : null;
                if (prev == null || !_sameDay(prev.timestamp, msg.timestamp)) {
                  divider = _DateDivider(date: msg.timestamp);
                }

                return Column(children: [
                  if (divider != null) divider,
                  _SwipeToReply(
                    onReply: () => setState(() => _replyingTo = msg),
                    child: GestureDetector(
                      onLongPress: () { HapticFeedback.mediumImpact(); _onLongPress(msg); },
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
                        allMessages: msgs,
                        tickWidget: isMine ? _buildTick(msg) : null,
                      ),
                    ),
                  ),
                ]);
              },
            );
          },
        ),
      ),

      // ── Reply bar ────────────────────────────────────────────────────
      if (_replyingTo != null) _ReplyBar(msg: _replyingTo!, onCancel: _cancelReply),

      // ── Recording bar ────────────────────────────────────────────────
      if (_isRecording)
        _RecordingBar(
          seconds: _recordingSeconds,
          onCancel: _cancelRecording,
          onSend: _stopAndSendRecording,
        ),

      // ── Input bar ────────────────────────────────────────────────────
      if (!_isRecording)
        _InputBar(
          controller: _textCtrl,
          focusNode: _textFocus,
          onSend: _sendText,
          onAttach: _showAttachmentSheet,
          onMicDown: _startRecording,
          onMicUp: _stopAndSendRecording,
        ),
    ]);

    if (_bgImagePath != null) {
      body = Container(
        decoration: BoxDecoration(
          image: DecorationImage(image: FileImage(File(_bgImagePath!)), fit: BoxFit.cover),
        ),
        child: body,
      );
    }

    return Scaffold(
      backgroundColor: _bgColor ?? _defaultBgColor,
      appBar: AppBar(
        titleSpacing: 0,
        title: GestureDetector(
          onTap: group != null
              ? () => Navigator.push(context, MaterialPageRoute(
                    builder: (_) => GroupInfoScreen(group: group, currentUid: widget.currentUid)))
              : null,
          child: Row(children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: Colors.white.withValues(alpha: 0.3),
              backgroundImage: group?.iconUrl != null
                  ? CachedNetworkImageProvider(group!.iconUrl!) : null,
              child: group?.iconUrl == null
                  ? const Icon(Icons.group_rounded, color: Colors.white, size: 20) : null,
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
            : item.type == MessageType.image && item.localFile != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.file(item.localFile!, width: 180, height: 180, fit: BoxFit.cover),
                  )
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
      case MessageType.voice: return '🎤 Voice message';
      case MessageType.image: return '📷 Photo';
      default: return '';
    }
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

// ── Item wrapper ──────────────────────────────────────────────────────────────

class _Item {
  final MessageModel? msg;
  final _PendingItem? pending;
  bool get isPending => pending != null;
  const _Item.msg(this.msg) : pending = null;
  const _Item.pending(this.pending) : msg = null;
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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: (d) {
        if (d.delta.dx > 0) {
          setState(() {
            _offset = (_offset + d.delta.dx).clamp(0.0, _threshold + 12);
          });
          if (_offset >= _threshold && !_triggered) {
            _triggered = true;
            HapticFeedback.lightImpact();
          }
        }
      },
      onHorizontalDragEnd: (_) {
        if (_triggered) widget.onReply();
        _triggered = false;
        setState(() => _offset = 0);
      },
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

  Color _colorForName(String name) =>
      _senderColors[name.hashCode.abs() % _senderColors.length];

  @override
  Widget build(BuildContext context) {
    final bubbleColor = isMine ? AppColors.primary : Colors.white;
    final textColor = isMine ? Colors.white : AppColors.textPrimary;

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
                  decoration: BoxDecoration(
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
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
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
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (msg.isEdited)
              Text('edited  ', style: TextStyle(color: textColor.withValues(alpha: 0.55), fontSize: 10)),
            Text(_fmtTime(msg.timestamp),
                style: TextStyle(color: textColor.withValues(alpha: 0.55), fontSize: 10)),
            if (tickWidget != null) ...[const SizedBox(width: 3), tickWidget!],
          ]),
        ]);

      case MessageType.image:
        return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (msg.imageUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: msg.imageUrl!,
                width: 220, height: 220, fit: BoxFit.cover,
                placeholder: (_, __) => Container(
                    width: 220, height: 220, color: Colors.black12,
                    child: const Center(child: CircularProgressIndicator(strokeWidth: 2))),
              ),
            ),
          const SizedBox(height: 4),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(_fmtTime(msg.timestamp),
                style: TextStyle(color: textColor.withValues(alpha: 0.55), fontSize: 10)),
            if (tickWidget != null) ...[const SizedBox(width: 3), tickWidget!],
          ]),
        ]);

      case MessageType.voice:
        return VoiceMessagePlayer(
          messageId: msg.id,
          audioUrl: msg.audioUrl,
          totalSeconds: msg.audioDurationSeconds ?? 0,
          isMine: isMine,
          playingIdNotifier: playingIdNotifier,
          isPlayingNotifier: isPlayingNotifier,
          positionNotifier: positionNotifier,
          durationNotifier: durationNotifier,
          onToggle: onToggleVoice,
          onSeek: onSeekAudio,
        );

      default:
        return Text(msg.text ?? '', style: TextStyle(color: textColor, fontSize: 15));
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
            Text(msg.text ?? (msg.imageUrl != null ? '📷 Photo' : '🎤 Voice'),
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
  final VoidCallback onCancel;
  final VoidCallback onSend;
  const _RecordingBar({required this.seconds, required this.onCancel, required this.onSend});

  String get _time {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [
        const Icon(Icons.mic_rounded, color: Colors.red, size: 22),
        const SizedBox(width: 8),
        Text(_time, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: Colors.red)),
        const Spacer(),
        TextButton.icon(
          onPressed: onCancel,
          icon: const Icon(Icons.delete_outline_rounded, color: Colors.grey),
          label: const Text('Cancel', style: TextStyle(color: Colors.grey)),
        ),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          onPressed: onSend,
          icon: const Icon(Icons.send_rounded, size: 16),
          label: const Text('Send'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary, foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          ),
        ),
      ]),
    );
  }
}

// ── Input bar ─────────────────────────────────────────────────────────────────

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onMicDown;
  final VoidCallback onMicUp;

  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onAttach,
    required this.onMicDown,
    required this.onMicUp,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
      child: SafeArea(
        top: false,
        child: Row(children: [
          IconButton(
            icon: const Icon(Icons.attach_file_rounded, color: AppColors.primary),
            onPressed: onAttach,
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF0EDF8),
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                maxLines: 5, minLines: 1,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Message',
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  border: InputBorder.none,
                ),
                onSubmitted: (_) => onSend(),
              ),
            ),
          ),
          const SizedBox(width: 6),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (ctx, value, _) {
              final hasText = value.text.trim().isNotEmpty;
              return hasText
                  ? GestureDetector(
                      onTap: onSend,
                      child: Container(
                        width: 42, height: 42,
                        decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                        child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                      ),
                    )
                  : GestureDetector(
                      onLongPressStart: (_) => onMicDown(),
                      onLongPressEnd: (_) => onMicUp(),
                      child: Container(
                        width: 42, height: 42,
                        decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                        child: const Icon(Icons.mic_rounded, color: Colors.white, size: 20),
                      ),
                    );
            },
          ),
        ]),
      ),
    );
  }
}

// ── Attach option ─────────────────────────────────────────────────────────────

class _AttachOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _AttachOption({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 56, height: 56,
          decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12), shape: BoxShape.circle),
          child: Icon(icon, color: AppColors.primary, size: 28),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      ]),
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
