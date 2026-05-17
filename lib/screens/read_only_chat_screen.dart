import 'package:audioplayers/audioplayers.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../constants/app_theme.dart';
import '../models/message_model.dart';
import '../services/chat_service.dart';

class ReadOnlyChatScreen extends StatefulWidget {
  final String uid1;
  final String uid2;
  final String name1;
  final String name2;
  final String? photo1;
  final String? photo2;

  const ReadOnlyChatScreen({
    super.key,
    required this.uid1,
    required this.uid2,
    required this.name1,
    required this.name2,
    this.photo1,
    this.photo2,
  });

  @override
  State<ReadOnlyChatScreen> createState() => _ReadOnlyChatScreenState();
}

class _ReadOnlyChatScreenState extends State<ReadOnlyChatScreen> {
  final AudioPlayer _player = AudioPlayer();
  String? _playingMessageId;

  @override
  void initState() {
    super.initState();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingMessageId = null);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
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

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0EDF8),
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            _MiniAvatar(name: widget.name1, photo: widget.photo1, color: AppColors.primary),
            const SizedBox(width: 6),
            const Icon(Icons.swap_horiz_rounded, color: Colors.white70, size: 18),
            const SizedBox(width: 6),
            _MiniAvatar(name: widget.name2, photo: widget.photo2, color: AppColors.accent),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                '${widget.name1} & ${widget.name2}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(
              children: [
                Icon(Icons.lock_rounded, size: 12, color: Colors.white70),
                SizedBox(width: 4),
                Text('Read only',
                    style: TextStyle(fontSize: 11, color: Colors.white70)),
              ],
            ),
          ),
        ],
      ),
      body: StreamBuilder<List<MessageModel>>(
        stream: ChatService().messages(widget.uid1, widget.uid2),
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final messages = snap.data ?? [];
          if (messages.isEmpty) {
            return const Center(
              child: Text('No messages yet',
                  style: TextStyle(color: AppColors.textSecondary)),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
            itemCount: messages.length,
            itemBuilder: (ctx, i) {
              final msg = messages[i];
              final isUid1 = msg.senderId == widget.uid1;
              final senderName = isUid1 ? widget.name1 : widget.name2;
              final showDate = i == 0 ||
                  !_sameDay(messages[i - 1].timestamp, msg.timestamp);
              final showName =
                  i == 0 || messages[i - 1].senderId != msg.senderId;
              return Column(
                children: [
                  if (showDate) _DateDivider(dt: msg.timestamp),
                  _ReadOnlyBubble(
                    msg: msg,
                    isLeft: isUid1,
                    senderName: senderName,
                    showName: showName,
                    isPlaying: _playingMessageId == msg.id,
                    onTogglePlay: () => _togglePlay(msg),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

// ── Mini avatar for AppBar ────────────────────────────────────────────────────

class _MiniAvatar extends StatelessWidget {
  final String name;
  final String? photo;
  final Color color;

  const _MiniAvatar({required this.name, this.photo, required this.color});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 15,
      backgroundColor: Colors.white.withValues(alpha: 0.25),
      backgroundImage:
          photo != null ? CachedNetworkImageProvider(photo!) : null,
      child: photo == null
          ? Text(name[0].toUpperCase(),
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12))
          : null,
    );
  }
}

// ── Date divider ─────────────────────────────────────────────────────────────

class _DateDivider extends StatelessWidget {
  final DateTime dt;
  const _DateDivider({required this.dt});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final day = DateTime(dt.year, dt.month, dt.day);
    final label = day == today
        ? 'Today'
        : day == yesterday
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
}

// ── Read-only bubble ──────────────────────────────────────────────────────────

class _ReadOnlyBubble extends StatelessWidget {
  final MessageModel msg;
  final bool isLeft;
  final String senderName;
  final bool showName;
  final bool isPlaying;
  final VoidCallback onTogglePlay;

  const _ReadOnlyBubble({
    required this.msg,
    required this.isLeft,
    required this.senderName,
    required this.showName,
    required this.isPlaying,
    required this.onTogglePlay,
  });

  @override
  Widget build(BuildContext context) {
    if (msg.type == MessageType.sticker) {
      return Align(
        alignment: isLeft ? Alignment.centerLeft : Alignment.centerRight,
        child: Padding(
          padding: EdgeInsets.only(
              top: 3, bottom: 3, left: isLeft ? 0 : 60, right: isLeft ? 60 : 0),
          child: Column(
            crossAxisAlignment:
                isLeft ? CrossAxisAlignment.start : CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showName)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(senderName,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: isLeft ? AppColors.primary : AppColors.accent)),
                ),
              Text(msg.text ?? '', style: const TextStyle(fontSize: 48)),
              Text(DateFormat('HH:mm').format(msg.timestamp),
                  style: const TextStyle(
                      fontSize: 10, color: AppColors.textSecondary)),
            ],
          ),
        ),
      );
    }

    final isMedia =
        msg.type == MessageType.image || msg.type == MessageType.gif;
    final bubbleColor = isLeft ? Colors.white : const Color(0xFFE8E0F5);

    return Align(
      alignment: isLeft ? Alignment.centerLeft : Alignment.centerRight,
      child: Column(
        crossAxisAlignment:
            isLeft ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showName)
            Padding(
              padding: EdgeInsets.only(
                  top: 6,
                  bottom: 2,
                  left: isLeft ? 2 : 0,
                  right: isLeft ? 0 : 2),
              child: Text(senderName,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isLeft ? AppColors.primary : AppColors.accent)),
            ),
          Container(
            margin: EdgeInsets.only(
                top: 2,
                bottom: 2,
                left: isLeft ? 0 : 60,
                right: isLeft ? 60 : 0),
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.72),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(isLeft ? 4 : 18),
                bottomRight: Radius.circular(isLeft ? 18 : 4),
              ),
              boxShadow: [
                BoxShadow(
                    color: AppColors.cardShadow,
                    blurRadius: 4,
                    offset: const Offset(0, 2))
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(isLeft ? 4 : 18),
                bottomRight: Radius.circular(isLeft ? 18 : 4),
              ),
              child: isMedia ? _mediaBubble(context) : _textVoiceBubble(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _textVoiceBubble() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (msg.replyToText != null) ...[
            Container(
              padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(8),
                border: const Border(
                    left: BorderSide(color: AppColors.primary, width: 3)),
              ),
              child: Text(msg.replyToText!,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
          ],
          if (msg.type == MessageType.voice)
            GestureDetector(
              onTap: onTogglePlay,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: AppColors.primary,
                      size: 20,
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
                                    color: AppColors.primary.withValues(
                                        alpha: isPlaying ? 1.0 : 0.4),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                )),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _fmtDur(msg.audioDurationSeconds ?? 0),
                        style: const TextStyle(
                            fontSize: 10, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ],
              ),
            )
          else
            Text(msg.text ?? '',
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 14)),
          const SizedBox(height: 3),
          Text(DateFormat('HH:mm').format(msg.timestamp),
              style: const TextStyle(
                  fontSize: 10, color: AppColors.textSecondary)),
        ],
      ),
    );
  }

  Widget _mediaBubble(BuildContext context) {
    final url = msg.imageUrl;
    if (url == null) return const SizedBox.shrink();
    return Stack(
      children: [
        CachedNetworkImage(
          imageUrl: url,
          width: double.infinity,
          fit: BoxFit.cover,
          placeholder: (_, __) => Container(
            height: 160,
            color: AppColors.background,
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
        const SizedBox(height: 22),
        Positioned(
          bottom: 6,
          right: 8,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(10)),
            child: Text(DateFormat('HH:mm').format(msg.timestamp),
                style:
                    const TextStyle(fontSize: 10, color: Colors.white)),
          ),
        ),
      ],
    );
  }

  String _fmtDur(int s) =>
      '${(s ~/ 60).toString().padLeft(1, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}
