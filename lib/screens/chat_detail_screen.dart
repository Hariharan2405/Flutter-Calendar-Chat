import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/chat_service.dart';
import '../services/call_service.dart';
import '../models/user_profile_model.dart';
import '../models/message_model.dart';
import '../models/call_model.dart';
import '../constants/app_theme.dart';
import '../widgets/voice_preview_sheet.dart';
import '../widgets/image_preview_sheet.dart';
import '../widgets/gif_picker_sheet.dart';
import '../widgets/sticker_picker_sheet.dart';
import 'call_screen.dart';

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
  final FocusNode _textFocus = FocusNode();
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  final ImagePicker _imagePicker = ImagePicker();

  bool _isRecording = false;
  bool _isSending = false;
  bool _showEmojiPicker = false;
  String? _playingMessageId;
  String? _recordingPath;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;
  MessageModel? _replyingTo;

  double _dragStartY = 0;
  bool _recordingStartedByDrag = false;

  // Chat background — null = default color
  Color? _bgColor;
  String? _bgImagePath;
  static const _defaultBgColor = Color(0xFFF0EDF8);

  String get _chatId =>
      ChatService.chatId(widget.currentUid, widget.otherUser.uid);

  @override
  void initState() {
    super.initState();
    ActiveChatTracker.activeChatId = _chatId;
    _chatService.resetUnread(widget.currentUid, widget.otherUser.uid);
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingMessageId = null);
    });
    _textFocus.addListener(() {
      if (_textFocus.hasFocus && _showEmojiPicker) {
        setState(() => _showEmojiPicker = false);
      }
    });
    _loadBackground();
  }

  Future<void> _loadBackground() async {
    final prefs = await SharedPreferences.getInstance();
    final colorVal = prefs.getInt('chat_bg_color_$_chatId');
    final imagePath = prefs.getString('chat_bg_image_$_chatId');
    if (mounted) {
      setState(() {
        _bgColor = colorVal != null ? Color(colorVal) : null;
        _bgImagePath = imagePath;
      });
    }
  }

  Future<void> _saveBgColor(Color color) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('chat_bg_color_$_chatId', color.toARGB32());
    await prefs.remove('chat_bg_image_$_chatId');
    if (mounted) setState(() { _bgColor = color; _bgImagePath = null; });
  }

  Future<void> _saveBgImage(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('chat_bg_image_$_chatId', path);
    await prefs.remove('chat_bg_color_$_chatId');
    if (mounted) setState(() { _bgImagePath = path; _bgColor = null; });
  }

  Future<void> _resetBackground() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('chat_bg_color_$_chatId');
    await prefs.remove('chat_bg_image_$_chatId');
    if (mounted) setState(() { _bgColor = null; _bgImagePath = null; });
  }

  // ── Emoji toggle ───────────────────────────────────────────────────────────

  void _toggleEmoji() {
    if (_showEmojiPicker) {
      setState(() => _showEmojiPicker = false);
      _textFocus.requestFocus();
    } else {
      _textFocus.unfocus();
      setState(() => _showEmojiPicker = true);
    }
  }

  // ── Background picker ─────────────────────────────────────────────────────

  static const _bgColors = [
    Color(0xFFF0EDF8), // default purple-tint
    Colors.white,
    Color(0xFFE8F5E9), // green
    Color(0xFFE3F2FD), // blue
    Color(0xFFFFF8E1), // yellow
    Color(0xFFFCE4EC), // pink
    Color(0xFFEDE7F6), // deep purple
    Color(0xFFE0F7FA), // cyan
    Color(0xFF1A1A2E), // dark
    Color(0xFF2D2D44), // dark purple
  ];

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
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('Chat Background',
                  style:
                      TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _bgColors.map((c) {
                  final selected =
                      _bgColor?.toARGB32() == c.toARGB32() ||
                      (_bgColor == null &&
                          c.toARGB32() == _defaultBgColor.toARGB32());
                  return GestureDetector(
                    onTap: () {
                      Navigator.pop(ctx);
                      _saveBgColor(c);
                    },
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected
                              ? AppColors.primary
                              : AppColors.divider,
                          width: selected ? 3 : 1.5,
                        ),
                      ),
                      child: selected
                          ? const Icon(Icons.check,
                              size: 18, color: AppColors.primary)
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
                  icon: const Icon(Icons.photo_library_rounded),
                  label: const Text('Gallery'),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    final file = await _imagePicker.pickImage(
                        source: ImageSource.gallery);
                    if (file != null) _saveBgImage(file.path);
                  },
                ),
                TextButton.icon(
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Reset'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _resetBackground();
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    Widget body = Column(
      children: [
        Expanded(child: _buildMessageList()),
        if (_isRecording) _buildRecordingBar(),
        if (_replyingTo != null) _buildReplyBar(),
        _buildInputBar(),
        if (_showEmojiPicker) _buildEmojiPicker(),
      ],
    );

    // Wrap with background image if set
    if (_bgImagePath != null) {
      body = Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: FileImage(File(_bgImagePath!)),
            fit: BoxFit.cover,
          ),
        ),
        child: body,
      );
    }

    return Scaffold(
      backgroundColor: _bgColor ?? _defaultBgColor,
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            GestureDetector(
              onTap: widget.otherUser.photoUrl != null
                  ? () => _viewFullImage(widget.otherUser.photoUrl!)
                  : null,
              child: CircleAvatar(
                radius: 18,
                backgroundColor: Colors.white.withValues(alpha: 0.25),
                backgroundImage: widget.otherUser.photoUrl != null
                    ? CachedNetworkImageProvider(widget.otherUser.photoUrl!)
                    : null,
                child: widget.otherUser.photoUrl == null
                    ? Text(
                        widget.otherUser.name[0].toUpperCase(),
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16),
                      )
                    : null,
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.otherUser.name,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                Text(
                  'Last seen ${_formatLastSeen(widget.otherUser.lastSeen)}',
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.call_rounded, color: Colors.white),
            onPressed: () => _startCall(isVideo: false),
            tooltip: 'Voice call',
          ),
          IconButton(
            icon: const Icon(Icons.videocam_rounded, color: Colors.white),
            onPressed: () => _startCall(isVideo: true),
            tooltip: 'Video call',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (v) {
              if (v == 'bg') _showBackgroundPicker();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'bg',
                child: Row(
                  children: [
                    Icon(Icons.wallpaper_rounded, size: 20),
                    SizedBox(width: 10),
                    Text('Change Background'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: body,
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
                Icon(Icons.chat_bubble_outline_rounded,
                    size: 56,
                    color: AppColors.textSecondary.withValues(alpha: 0.3)),
                const SizedBox(height: 12),
                Text('Say hello to ${widget.otherUser.name}!',
                    style: TextStyle(
                        color: AppColors.textSecondary.withValues(alpha: 0.6),
                        fontSize: 14)),
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
            final showDate =
                i == 0 || !_isSameDay(messages[i - 1].timestamp, msg.timestamp);
            return Column(
              children: [
                if (showDate) _buildDateDivider(msg.timestamp),
                _SwipeToReply(
                  onReply: () => setState(() => _replyingTo = msg),
                  child: _buildBubble(msg, isMe),
                ),
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
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textSecondary)),
          ),
          const Expanded(child: Divider(color: AppColors.divider)),
        ],
      ),
    );
  }

  Widget _buildBubble(MessageModel msg, bool isMe) {
    if (msg.type == MessageType.sticker) {
      return _buildStickerBubble(msg, isMe);
    }
    final isMedia = msg.type == MessageType.image || msg.type == MessageType.gif;

    return GestureDetector(
      onLongPress: () => _showMessageOptions(msg, isMe),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: EdgeInsets.only(
            top: 3,
            bottom: 3,
            left: isMe ? 60 : 0,
            right: isMe ? 0 : 60,
          ),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.72,
          ),
          decoration: BoxDecoration(
            color: isMe ? AppColors.primary : Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(isMe ? 18 : 4),
              bottomRight: Radius.circular(isMe ? 4 : 18),
            ),
            boxShadow: [
              BoxShadow(
                  color: AppColors.cardShadow,
                  blurRadius: 4,
                  offset: const Offset(0, 2)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(isMe ? 18 : 4),
              bottomRight: Radius.circular(isMe ? 4 : 18),
            ),
            child: isMedia
                ? _buildMediaBubble(msg, isMe)
                : _buildTextVoiceBubble(msg, isMe),
          ),
        ),
      ),
    );
  }

  Widget _buildStickerBubble(MessageModel msg, bool isMe) {
    return GestureDetector(
      onLongPress: () => _showMessageOptions(msg, isMe),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.only(
            top: 3,
            bottom: 3,
            left: isMe ? 60 : 0,
            right: isMe ? 0 : 60,
          ),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(msg.text ?? '', style: const TextStyle(fontSize: 56)),
              Text(
                DateFormat('HH:mm').format(msg.timestamp),
                style: const TextStyle(
                    fontSize: 10, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextVoiceBubble(MessageModel msg, bool isMe) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (msg.replyToText != null) ...[
            _buildReplySnippet(msg.replyToText!, isMe),
            const SizedBox(height: 6),
          ],
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
                    style: TextStyle(
                        fontSize: 9,
                        color: isMe
                            ? Colors.white.withValues(alpha: 0.6)
                            : AppColors.textSecondary,
                        fontStyle: FontStyle.italic)),
              Text(
                DateFormat('HH:mm').format(msg.timestamp),
                style: TextStyle(
                    fontSize: 10,
                    color: isMe
                        ? Colors.white.withValues(alpha: 0.7)
                        : AppColors.textSecondary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMediaBubble(MessageModel msg, bool isMe) {
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (msg.replyToText != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                child: _buildReplySnippet(msg.replyToText!, isMe),
              ),
            GestureDetector(
              onTap: () => _viewFullImage(msg.imageUrl!),
              child: CachedNetworkImage(
                imageUrl: msg.imageUrl!,
                width: double.infinity,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(
                  height: 160,
                  color: isMe
                      ? Colors.white.withValues(alpha: 0.15)
                      : AppColors.background,
                  child: const Center(
                      child: CircularProgressIndicator(strokeWidth: 2)),
                ),
                errorWidget: (_, __, ___) => Container(
                  height: 160,
                  color: AppColors.background,
                  child: const Icon(Icons.broken_image_outlined,
                      color: AppColors.textSecondary),
                ),
              ),
            ),
            const SizedBox(height: 22),
          ],
        ),
        Positioned(
          bottom: 6,
          right: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black45,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              DateFormat('HH:mm').format(msg.timestamp),
              style:
                  const TextStyle(fontSize: 10, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReplySnippet(String text, bool isMe) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
      decoration: BoxDecoration(
        color: isMe
            ? Colors.white.withValues(alpha: 0.15)
            : AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(
            color: isMe ? Colors.white70 : AppColors.primary,
            width: 3,
          ),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: isMe ? Colors.white70 : AppColors.textSecondary,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
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
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: isMe
                  ? Colors.white.withValues(alpha: 0.2)
                  : AppColors.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: isMe ? Colors.white : AppColors.primary,
              size: 20,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: List.generate(
                  20,
                  (i) => Container(
                        width: 3,
                        height: (4 + (i % 4) * 4).toDouble(),
                        margin: const EdgeInsets.symmetric(horizontal: 1),
                        decoration: BoxDecoration(
                          color: isMe
                              ? Colors.white
                                  .withValues(alpha: isPlaying ? 1.0 : 0.55)
                              : AppColors.primary
                                  .withValues(alpha: isPlaying ? 1.0 : 0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      )),
            ),
            const SizedBox(height: 2),
            Text(_fmt(dur),
                style: TextStyle(
                    fontSize: 10,
                    color: isMe
                        ? Colors.white.withValues(alpha: 0.8)
                        : AppColors.textSecondary)),
          ],
        ),
      ],
    );
  }

  // ── Reply bar ─────────────────────────────────────────────────────────────

  Widget _buildReplyBar() {
    final msg = _replyingTo!;
    final isMyMsg = msg.senderId == widget.currentUid;
    final name = isMyMsg ? 'You' : widget.otherUser.name;
    final preview = msg.type == MessageType.text
        ? (msg.text ?? '')
        : msg.type == MessageType.voice
            ? '🎤 Voice message'
            : msg.type == MessageType.image
                ? '📷 Image'
                : msg.type == MessageType.sticker
                    ? (msg.text ?? '😊 Sticker')
                    : '🎞️ GIF';

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 6),
      color: AppColors.background,
      child: Row(
        children: [
          Container(
            width: 3,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name,
                    style: const TextStyle(
                        color: AppColors.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                Text(preview,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded,
                size: 18, color: AppColors.textSecondary),
            onPressed: () => setState(() => _replyingTo = null),
          ),
        ],
      ),
    );
  }

  // ── Recording Bar ─────────────────────────────────────────────────────────

  Widget _buildRecordingBar() {
    return GestureDetector(
      onVerticalDragUpdate: (d) {
        if (d.delta.dy > 6) _stopForPreview();
      },
      child: Container(
        color: AppColors.holiday.withValues(alpha: 0.08),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                  color: AppColors.holiday, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Text('Recording  ${_fmt(_recordingSeconds)}',
                style: const TextStyle(
                    color: AppColors.holiday,
                    fontWeight: FontWeight.w600,
                    fontSize: 14)),
            const Spacer(),
            const Text('↓ Slide down to finish',
                style:
                    TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  // ── Input Bar ─────────────────────────────────────────────────────────────

  Widget _buildInputBar() {
    return Container(
      padding: EdgeInsets.only(
        left: 6,
        right: 8,
        top: 6,
        bottom: MediaQuery.of(context).padding.bottom + 6,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, -2))
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Emoji toggle
          _inputIconBtn(
            icon: _showEmojiPicker
                ? Icons.keyboard_rounded
                : Icons.emoji_emotions_rounded,
            onTap: _toggleEmoji,
            color: _showEmojiPicker ? AppColors.primary : AppColors.textSecondary,
          ),
          // Text field
          Expanded(
            child: Container(
              padding: const EdgeInsets.only(left: 14, right: 4, top: 2, bottom: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFF3F0FA),
                borderRadius: BorderRadius.circular(26),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      focusNode: _textFocus,
                      decoration: const InputDecoration(
                        hintText: 'Message...',
                        border: InputBorder.none,
                        hintStyle: TextStyle(color: AppColors.textSecondary),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 9),
                      ),
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                    ),
                  ),
                  // Attach button
                  GestureDetector(
                    onTap: _showAttachmentOptions,
                    child: const Padding(
                      padding: EdgeInsets.only(bottom: 9, left: 4, right: 6),
                      child: Icon(Icons.attach_file_rounded,
                          color: AppColors.textSecondary, size: 20),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Send / Mic
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _textCtrl,
            builder: (_, val, __) =>
                val.text.trim().isNotEmpty ? _sendBtn() : _micBtn(),
          ),
        ],
      ),
    );
  }

  Widget _inputIconBtn({
    required IconData icon,
    required VoidCallback onTap,
    Color color = AppColors.textSecondary,
  }) =>
      GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 38,
          height: 42,
          child: Icon(icon, color: color, size: 24),
        ),
      );

  Widget _buildEmojiPicker() {
    return SizedBox(
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
            initCategory: Category.RECENT,
          ),
          bottomActionBarConfig: BottomActionBarConfig(
            backgroundColor: Colors.white,
            buttonColor: Colors.white,
            buttonIconColor: AppColors.primary,
          ),
        ),
      ),
    );
  }

  Widget _sendBtn() => GestureDetector(
        onTap: _isSending ? null : _sendText,
        child: Container(
          width: 48,
          height: 48,
          decoration: const BoxDecoration(
              color: AppColors.primary, shape: BoxShape.circle),
          child: _isSending
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.send_rounded, color: Colors.white, size: 22),
        ),
      );

  Widget _micBtn() {
    return GestureDetector(
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
      onTap: _isRecording ? _stopForPreview : _startRecording,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: _isRecording ? 54 : 48,
        height: _isRecording ? 54 : 48,
        decoration: BoxDecoration(
          color: _isRecording ? AppColors.holiday : AppColors.accent,
          shape: BoxShape.circle,
          boxShadow: _isRecording
              ? [
                  BoxShadow(
                      color: AppColors.holiday.withValues(alpha: 0.4),
                      blurRadius: 12,
                      spreadRadius: 4)
                ]
              : [],
        ),
        child: Icon(
          _isRecording ? Icons.stop_rounded : Icons.mic_rounded,
          color: Colors.white,
          size: _isRecording ? 26 : 22,
        ),
      ),
    );
  }

  // ── Attachment options ────────────────────────────────────────────────────

  void _showAttachmentOptions() {
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
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2)),
            ),
            ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle),
                child: const Icon(Icons.camera_alt_rounded,
                    color: AppColors.primary, size: 22),
              ),
              title: const Text('Camera'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle),
                child: const Icon(Icons.photo_library_rounded,
                    color: AppColors.primary, size: 22),
              ),
              title: const Text('Gallery'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle),
                child: const Icon(Icons.gif_rounded,
                    color: AppColors.primary, size: 26),
              ),
              title: const Text('GIF'),
              onTap: () {
                Navigator.pop(ctx);
                _showGifPicker();
              },
            ),
            ListTile(
              leading: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle),
                child: const Text('😊',
                    style: TextStyle(fontSize: 22), textAlign: TextAlign.center),
              ),
              title: const Text('Sticker'),
              onTap: () {
                Navigator.pop(ctx);
                _showStickerPicker();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    final XFile? file =
        await _imagePicker.pickImage(source: source, imageQuality: 85);
    if (file == null || !mounted) return;

    final imageFile = File(file.path);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ImagePreviewSheet(
        imageFile: imageFile,
        onSend: () => _chatService.sendImageMessage(
          senderUid: widget.currentUid,
          receiverUid: widget.otherUser.uid,
          imageFile: imageFile,
          replyToId: _replyingTo?.id,
          replyToText: _replyToPreviewText(),
          replyToSenderId: _replyingTo?.senderId,
        ),
      ),
    ).then((_) {
      if (_replyingTo != null) setState(() => _replyingTo = null);
    });
  }

  Future<void> _showGifPicker() async {
    final String? gifUrl = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const GifPickerSheet(),
    );
    if (gifUrl == null || !mounted) return;

    setState(() => _isSending = true);
    try {
      await _chatService.sendGifMessage(
        senderUid: widget.currentUid,
        receiverUid: widget.otherUser.uid,
        gifUrl: gifUrl,
        replyToId: _replyingTo?.id,
        replyToText: _replyToPreviewText(),
        replyToSenderId: _replyingTo?.senderId,
      );
      setState(() => _replyingTo = null);
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _showStickerPicker() async {
    final String? sticker = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const StickerPickerSheet(),
    );
    if (sticker == null || !mounted) return;

    setState(() => _isSending = true);
    try {
      await _chatService.sendStickerMessage(
        senderUid: widget.currentUid,
        receiverUid: widget.otherUser.uid,
        sticker: sticker,
        replyToId: _replyingTo?.id,
        replyToText: _replyToPreviewText(),
        replyToSenderId: _replyingTo?.senderId,
      );
      setState(() => _replyingTo = null);
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _viewFullImage(String url) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: Center(
            child: InteractiveViewer(
              child: CachedNetworkImage(
                imageUrl: url,
                placeholder: (_, __) =>
                    const Center(child: CircularProgressIndicator()),
              ),
            ),
          ),
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
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2)),
            ),
            ListTile(
              leading:
                  const Icon(Icons.reply_rounded, color: AppColors.primary),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => _replyingTo = msg);
              },
            ),
            if (isMe && msg.type == MessageType.text)
              ListTile(
                leading: const Icon(Icons.edit_rounded,
                    color: AppColors.primary),
                title: const Text('Edit Message'),
                onTap: () {
                  Navigator.pop(ctx);
                  _editMessage(msg);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded,
                  color: AppColors.holiday),
              title: const Text('Delete Message',
                  style: TextStyle(color: AppColors.holiday)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteMessage(msg);
              },
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
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Edit Message'),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          autofocus: true,
          decoration:
              const InputDecoration(hintText: 'Edit your message...'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
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
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Delete Message'),
        content:
            const Text('This message will be permanently deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.holiday),
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

  void _startCall({required bool isVideo}) {
    if (CallService().isInCall) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You are already in a call')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          callId: '',
          isOutgoing: true,
          callType: isVideo ? CallType.video : CallType.voice,
          otherUser: widget.otherUser,
          currentUid: widget.currentUid,
        ),
      ),
    );
  }

  Future<void> _sendText() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    _textCtrl.clear();
    final reply = _replyingTo;
    setState(() {
      _isSending = true;
      _replyingTo = null;
    });
    try {
      await _chatService.sendTextMessage(
        senderUid: widget.currentUid,
        receiverUid: widget.otherUser.uid,
        text: text,
        replyToId: reply?.id,
        replyToText: _replyToPreviewText(msg: reply),
        replyToSenderId: reply?.senderId,
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  String? _replyToPreviewText({MessageModel? msg}) {
    final m = msg ?? _replyingTo;
    if (m == null) return null;
    if (m.type == MessageType.text) return m.text;
    if (m.type == MessageType.voice) return '🎤 Voice message';
    if (m.type == MessageType.image) return '📷 Image';
    if (m.type == MessageType.gif) return '🎞️ GIF';
    if (m.type == MessageType.sticker) return m.text;
    return null;
  }

  Future<void> _startRecording() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Microphone permission required')));
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
    _recordingTimer =
        Timer.periodic(const Duration(seconds: 1), (_) {
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
    _textFocus.dispose();
    _recordingTimer?.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }
}

// ── Swipe-to-reply wrapper ────────────────────────────────────────────────────

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
          Transform.translate(
            offset: Offset(_offset, 0),
            child: widget.child,
          ),
          if (_offset > 6)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Center(
                child: Opacity(
                  opacity: (_offset / _threshold).clamp(0.0, 1.0),
                  child: const Icon(Icons.reply_rounded,
                      color: AppColors.primary, size: 22),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
