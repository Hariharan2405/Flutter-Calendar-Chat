import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import '../services/chat_service.dart';
import '../models/user_profile_model.dart';
import '../models/message_model.dart';
import '../constants/app_theme.dart';
import '../widgets/voice_preview_sheet.dart';

// Tracks active chat for notification suppression
class ActiveChatTracker {
  static String? activeChatId;
}

class ChatDetailScreen extends StatefulWidget {
  final String currentUid;
  final UserProfileModel otherUser;

  const ChatDetailScreen({
    super.key,
    required this.currentUid,
    required this.otherUser,
  });

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  final ChatService _chatService = ChatService();
  final TextEditingController _textCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  bool _isRecording = false;
  bool _isSending = false;
  String? _playingMessageId;
  String? _recordingPath;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;

  // For drag-to-record gesture
  double _dragStartY = 0;
  bool _recordingStartedByDrag = false;

  @override
  void initState() {
    super.initState();
    ActiveChatTracker.activeChatId =
        ChatService.chatId(widget.currentUid, widget.otherUser.uid);
    _chatService.resetUnread(widget.currentUid, widget.otherUser.uid);
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingMessageId = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0EDF8),
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: Colors.white.withValues(alpha: 0.25),
              child: Text(
                widget.otherUser.name[0].toUpperCase(),
                style: const TextStyle(color: Colors.white,
                    fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.otherUser.name,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                Text(
                  'Last seen ${_formatLastSeen(widget.otherUser.lastSeen)}',
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ],
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(child: _buildMessageList()),
          if (_isRecording) _buildRecordingBar(),
          _buildInputBar(),
        ],
      ),
    );
  }

  // ── Message List ──────────────────────────────────────────────────────────

  Widget _buildMessageList() {
    return StreamBuilder<List<MessageModel>>(
      stream: _chatService.messages(widget.currentUid, widget.otherUser.uid),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final messages = snap.data ?? [];
        if (messages.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.chat_bubble_outline_rounded, size: 56,
                    color: AppColors.textSecondary.withValues(alpha: 0.3)),
                const SizedBox(height: 12),
                Text('Say hello to ${widget.otherUser.name}!',
                    style: TextStyle(color: AppColors.textSecondary
                        .withValues(alpha: 0.6), fontSize: 14)),
              ],
            ),
          );
        }

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollCtrl.hasClients) {
            _scrollCtrl.animateTo(
              _scrollCtrl.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });

        return ListView.builder(
          controller: _scrollCtrl,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          itemCount: messages.length,
          itemBuilder: (ctx, i) {
            final msg = messages[i];
            final isMe = msg.senderId == widget.currentUid;
            final showDate = i == 0 ||
                !_isSameDay(messages[i - 1].timestamp, msg.timestamp);
            return Column(
              children: [
                if (showDate) _buildDateDivider(msg.timestamp),
                _buildBubble(msg, isMe),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildDateDivider(DateTime dt) {
    final now = DateTime.now();
    final label = _isSameDay(dt, now)
        ? 'Today'
        : _isSameDay(dt, now.subtract(const Duration(days: 1)))
            ? 'Yesterday'
            : DateFormat('d MMM yyyy').format(dt);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          const Expanded(child: Divider(color: AppColors.divider)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(label,
                style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          ),
          const Expanded(child: Divider(color: AppColors.divider)),
        ],
      ),
    );
  }

  Widget _buildBubble(MessageModel msg, bool isMe) {
    return GestureDetector(
      onLongPress: () => _showMessageOptions(msg, isMe),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: EdgeInsets.only(
            top: 3, bottom: 3,
            left: isMe ? 60 : 0,
            right: isMe ? 0 : 60,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isMe ? AppColors.primary : Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(isMe ? 18 : 4),
              bottomRight: Radius.circular(isMe ? 4 : 18),
            ),
            boxShadow: [
              BoxShadow(color: AppColors.cardShadow, blurRadius: 4,
                  offset: const Offset(0, 2)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (msg.type == MessageType.text)
                Text(msg.text ?? '',
                    style: TextStyle(
                        color: isMe ? Colors.white : AppColors.textPrimary,
                        fontSize: 14))
              else
                _buildVoiceBubble(msg, isMe),
              const SizedBox(height: 3),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (msg.isEdited)
                    Text('edited  ',
                        style: TextStyle(fontSize: 9,
                            color: isMe ? Colors.white.withValues(alpha: 0.6)
                                : AppColors.textSecondary,
                            fontStyle: FontStyle.italic)),
                  Text(
                    DateFormat('HH:mm').format(msg.timestamp),
                    style: TextStyle(fontSize: 10,
                        color: isMe ? Colors.white.withValues(alpha: 0.7)
                            : AppColors.textSecondary),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceBubble(MessageModel msg, bool isMe) {
    final isPlaying = _playingMessageId == msg.id;
    final dur = msg.audioDurationSeconds ?? 0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => _togglePlay(msg),
          child: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: isMe ? Colors.white.withValues(alpha: 0.2)
                  : AppColors.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: isMe ? Colors.white : AppColors.primary, size: 20,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: List.generate(20, (i) => Container(
                width: 3,
                height: (4 + (i % 4) * 4).toDouble(),
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: isMe
                      ? Colors.white.withValues(alpha: isPlaying ? 1.0 : 0.55)
                      : AppColors.primary.withValues(alpha: isPlaying ? 1.0 : 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              )),
            ),
            const SizedBox(height: 2),
            Text(_fmt(dur),
                style: TextStyle(fontSize: 10,
                    color: isMe ? Colors.white.withValues(alpha: 0.8)
                        : AppColors.textSecondary)),
          ],
        ),
      ],
    );
  }

  // ── Recording Bar (shown while recording) ─────────────────────────────────

  Widget _buildRecordingBar() {
    return GestureDetector(
      onVerticalDragUpdate: (d) {
        if (d.delta.dy > 6) _stopForPreview(); // slide down to finish
      },
      child: Container(
        color: AppColors.holiday.withValues(alpha: 0.08),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 10, height: 10,
              decoration: const BoxDecoration(
                color: AppColors.holiday, shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Text('Recording  ${_fmt(_recordingSeconds)}',
                style: const TextStyle(color: AppColors.holiday,
                    fontWeight: FontWeight.w600, fontSize: 14)),
            const Spacer(),
            const Text('↓ Slide down to finish',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  // ── Input Bar ─────────────────────────────────────────────────────────────

  Widget _buildInputBar() {
    return Container(
      padding: EdgeInsets.only(
        left: 12, right: 12, top: 10,
        bottom: MediaQuery.of(context).padding.bottom + 10,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: AppColors.cardShadow, blurRadius: 8,
            offset: Offset(0, -2))],
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AppColors.divider),
              ),
              child: TextField(
                controller: _textCtrl,
                decoration: const InputDecoration(
                  hintText: 'Type a message...',
                  border: InputBorder.none,
                  hintStyle: TextStyle(color: AppColors.textSecondary),
                ),
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
              ),
            ),
          ),
          const SizedBox(width: 8),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _textCtrl,
            builder: (_, val, __) =>
                val.text.trim().isNotEmpty ? _sendBtn() : _micBtn(),
          ),
        ],
      ),
    );
  }

  Widget _sendBtn() => GestureDetector(
        onTap: _isSending ? null : _sendText,
        child: Container(
          width: 48, height: 48,
          decoration: const BoxDecoration(
              color: AppColors.primary, shape: BoxShape.circle),
          child: _isSending
              ? const Padding(padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.send_rounded, color: Colors.white, size: 22),
        ),
      );

  Widget _micBtn() {
    return GestureDetector(
      // Slide UP to start recording
      onVerticalDragStart: (d) {
        _dragStartY = d.globalPosition.dy;
        _recordingStartedByDrag = false;
      },
      onVerticalDragUpdate: (d) async {
        final dy = d.globalPosition.dy - _dragStartY;
        if (dy < -30 && !_isRecording && !_recordingStartedByDrag) {
          _recordingStartedByDrag = true;
          await _startRecording();
        }
      },
      // Tap to start/stop when not using drag
      onTap: _isRecording ? _stopForPreview : _startRecording,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: _isRecording ? 54 : 48,
        height: _isRecording ? 54 : 48,
        decoration: BoxDecoration(
          color: _isRecording ? AppColors.holiday : AppColors.accent,
          shape: BoxShape.circle,
          boxShadow: _isRecording
              ? [BoxShadow(color: AppColors.holiday.withValues(alpha: 0.4),
                  blurRadius: 12, spreadRadius: 4)]
              : [],
        ),
        child: Icon(
          _isRecording ? Icons.stop_rounded : Icons.mic_rounded,
          color: Colors.white, size: _isRecording ? 26 : 22,
        ),
      ),
    );
  }

  // ── Message Options (long press) ──────────────────────────────────────────

  void _showMessageOptions(MessageModel msg, bool isMe) {
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
              width: 40, height: 4, margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2)),
            ),
            if (isMe && msg.type == MessageType.text)
              ListTile(
                leading: const Icon(Icons.edit_rounded, color: AppColors.primary),
                title: const Text('Edit Message'),
                onTap: () { Navigator.pop(ctx); _editMessage(msg); },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: AppColors.holiday),
              title: const Text('Delete Message',
                  style: TextStyle(color: AppColors.holiday)),
              onTap: () { Navigator.pop(ctx); _deleteMessage(msg); },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _editMessage(MessageModel msg) {
    final ctrl = TextEditingController(text: msg.text);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Edit Message'),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Edit your message...'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newText = ctrl.text.trim();
              if (newText.isEmpty) return;
              await _chatService.editMessage(
                uid1: widget.currentUid,
                uid2: widget.otherUser.uid,
                messageId: msg.id,
                newText: newText,
              );
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _deleteMessage(MessageModel msg) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Delete Message'),
        content: const Text('This message will be permanently deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.holiday),
            onPressed: () async {
              await _chatService.deleteMessage(
                uid1: widget.currentUid,
                uid2: widget.otherUser.uid,
                messageId: msg.id,
              );
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _sendText() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    _textCtrl.clear();
    setState(() => _isSending = true);
    try {
      await _chatService.sendTextMessage(
        senderUid: widget.currentUid,
        receiverUid: widget.otherUser.uid,
        text: text,
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _startRecording() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission required')));
      }
      return;
    }
    final dir = await getTemporaryDirectory();
    _recordingPath =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.aac';
    _recordingSeconds = 0;
    await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000),
        path: _recordingPath!);
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recordingSeconds++);
    });
    if (mounted) setState(() => _isRecording = true);
  }

  Future<void> _stopForPreview() async {
    if (!_isRecording) return;
    _recordingTimer?.cancel();
    final path = await _recorder.stop();
    if (mounted) setState(() => _isRecording = false);

    if (path == null || _recordingSeconds < 1) return;

    final dur = _recordingSeconds;
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => VoicePreviewSheet(
        audioPath: path,
        durationSeconds: dur,
        onSend: () => _chatService.sendVoiceMessage(
          senderUid: widget.currentUid,
          receiverUid: widget.otherUser.uid,
          audioFile: File(path),
          durationSeconds: dur,
        ),
      ),
    );
  }

  Future<void> _togglePlay(MessageModel msg) async {
    if (_playingMessageId == msg.id) {
      await _player.stop();
      setState(() => _playingMessageId = null);
    } else {
      setState(() => _playingMessageId = msg.id);
      await _player.play(UrlSource(msg.audioUrl!));
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _formatLastSeen(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 2) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return DateFormat('d MMM').format(dt);
  }

  String _fmt(int s) =>
      '${(s ~/ 60).toString().padLeft(1, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  void dispose() {
    ActiveChatTracker.activeChatId = null;
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _recordingTimer?.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }
}
