import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../models/message_model.dart';
import '../services/chat_service.dart';
import '../utils/responsive.dart';
import '../widgets/chat_ui.dart';
import '../widgets/media_viewers.dart';

/// Read-only transcript of a conversation between two users, styled like a
/// normal chat. No composer: it only displays.
///
/// uid1's messages sit on the left in white bubbles, uid2's on the right in
/// the violet gradient, so the two sides read apart at a glance.
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
  final ScrollController _scrollController = ScrollController();
  late final Stream<List<MessageModel>> _messagesStream;
  String? _playingMessageId;

  @override
  void initState() {
    super.initState();
    // Create the stream once — recreating it on every build makes StreamBuilder
    // resubscribe, which resets the ListView and jumps the scroll position.
    _messagesStream = ChatService().messages(widget.uid1, widget.uid2);
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingMessageId = null);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _togglePlay(MessageModel msg) async {
    final url = msg.audioUrl;
    if (url == null) return;
    if (_playingMessageId == msg.id) {
      await _player.stop();
      if (mounted) setState(() => _playingMessageId = null);
    } else {
      setState(() => _playingMessageId = msg.id);
      await _player.play(UrlSource(url));
    }
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool _sameRun(MessageModel? other, MessageModel msg) {
    if (other == null) return false;
    if (other.senderId != msg.senderId) return false;
    if (!_sameDay(other.timestamp, msg.timestamp)) return false;
    return other.timestamp.difference(msg.timestamp).inMinutes.abs() < 3;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        titleSpacing: 0,
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: const ChatHeaderBackground(),
        title: Row(
          children: [
            HeaderAvatar(
                photoUrl: widget.photo1, name: widget.name1, radius: 15),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Icon(Icons.swap_horiz_rounded,
                  color: Colors.white70, size: 18),
            ),
            HeaderAvatar(
                photoUrl: widget.photo2, name: widget.name2, radius: 15),
            const SizedBox(width: 11),
            Flexible(
              child: Text(
                '${widget.name1} & ${widget.name2}',
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: _ReadOnlyBadge(),
          ),
        ],
      ),
      body: ChatCanvas(
        child: StreamBuilder<List<MessageModel>>(
          stream: _messagesStream,
          builder: (ctx, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final messages = snap.data ?? [];
            if (messages.isEmpty) {
              return const Center(
                child: Text('No messages yet',
                    style: TextStyle(color: ChatStyle.mist)),
              );
            }
            return ContentWidth(
              maxWidth: 900,
              child: ListView.builder(
                controller: _scrollController,
                reverse: true,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
                itemCount: messages.length,
                itemBuilder: (ctx, i) {
                  // reverse: index 0 = newest (bottom), higher index = older.
                  final msg = messages[messages.length - 1 - i];
                  final older = i < messages.length - 1
                      ? messages[messages.length - 2 - i]
                      : null;
                  final newer = i > 0 ? messages[messages.length - i] : null;
                  final showDate =
                      older == null || !_sameDay(older.timestamp, msg.timestamp);
                  // First of a run shows the sender name and the avatar.
                  final showName = !_sameRun(older, msg) || showDate;
                  final tail = !_sameRun(newer, msg);
                  final tight = !showName;

                  // Date pill is second in the Column so it sits above the
                  // bubble in a reversed list.
                  return Column(
                    children: [
                      _ReadOnlyBubble(
                        msg: msg,
                        isLeft: msg.senderId == widget.uid1,
                        senderName: msg.senderId == widget.uid1
                            ? widget.name1
                            : widget.name2,
                        photoUrl: msg.senderId == widget.uid1
                            ? widget.photo1
                            : widget.photo2,
                        showName: showName,
                        tail: tail,
                        tight: tight,
                        isPlaying: _playingMessageId == msg.id,
                        onTogglePlay: () => _togglePlay(msg),
                      ),
                      if (showDate) DatePill(date: msg.timestamp),
                    ],
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ReadOnlyBadge extends StatelessWidget {
  const _ReadOnlyBadge();

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_rounded, size: 12, color: Colors.white70),
            SizedBox(width: 4),
            Text('Read only',
                style: TextStyle(fontSize: 11, color: Colors.white70)),
          ]),
        ),
      );
}

// ── Bubble ─────────────────────────────────────────────────────────────────────

class _ReadOnlyBubble extends StatelessWidget {
  final MessageModel msg;

  /// uid1 is drawn on the left (white); uid2 on the right (gradient).
  final bool isLeft;
  final String senderName;
  final String? photoUrl;
  final bool showName;
  final bool tail;
  final bool tight;
  final bool isPlaying;
  final VoidCallback onTogglePlay;

  const _ReadOnlyBubble({
    required this.msg,
    required this.isLeft,
    required this.senderName,
    required this.photoUrl,
    required this.showName,
    required this.tail,
    required this.tight,
    required this.isPlaying,
    required this.onTogglePlay,
  });

  /// Gradient (and so white content) for the right-hand speaker.
  bool get _onDark => !isLeft;

  @override
  Widget build(BuildContext context) {
    final align = isLeft ? Alignment.centerLeft : Alignment.centerRight;

    if (msg.isDeleted) {
      return _frame(context, align,
          const _Tombstone(), const EdgeInsets.fromLTRB(14, 10, 14, 10));
    }

    // 1–3 emoji on their own: big, no bubble.
    final jumbo = msg.type == MessageType.text && msg.replyToText == null
        ? jumboEmojiCount(msg.text ?? '')
        : 0;
    if (jumbo > 0) {
      return Align(
        alignment: align,
        child: Padding(
          padding: EdgeInsets.only(
            top: tight ? 2 : 7,
            left: isLeft ? 4 : 52,
            right: isLeft ? 52 : 4,
          ),
          child: Column(
            crossAxisAlignment:
                isLeft ? CrossAxisAlignment.start : CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showName) _name(),
              Text(msg.text!.trim(),
                  style:
                      TextStyle(fontSize: jumboEmojiSize(jumbo), height: 1.15)),
              _timePill(),
            ],
          ),
        ),
      );
    }

    final isMedia =
        msg.type == MessageType.image || msg.type == MessageType.gif;
    final isVideo = msg.type == MessageType.video;

    final Widget content = isMedia
        ? _photo(context)
        : isVideo
            ? _video(context)
            : _textVoice(context);

    return _frame(
      context,
      align,
      content,
      isMedia || isVideo ? const EdgeInsets.all(4) : EdgeInsets.zero,
    );
  }

  Widget _frame(BuildContext context, Alignment align, Widget content,
      EdgeInsets padding) {
    return Align(
      alignment: align,
      child: Padding(
        padding: EdgeInsets.only(
          top: tight ? 2 : 7,
          left: isLeft ? 0 : 52,
          right: isLeft ? 52 : 0,
        ),
        child: Column(
          crossAxisAlignment:
              isLeft ? CrossAxisAlignment.start : CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showName) _name(),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: context.bubbleMaxWidth),
              child: BubbleFrame(
                isMe: _onDark,
                tail: tail,
                padding: padding,
                child: content,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _name() => Padding(
        padding: EdgeInsets.only(bottom: 3, left: isLeft ? 4 : 0, right: isLeft ? 0 : 4),
        child: Text(
          senderName,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: isLeft ? ChatStyle.violet : ChatStyle.orchid,
          ),
        ),
      );

  Widget _timePill() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(10),
        ),
        child: BubbleMeta(time: msg.timestamp, isMe: false),
      );

  Widget _meta() => BubbleMeta(
        time: msg.timestamp,
        isMe: _onDark,
        edited: msg.isEdited,
      );

  // ── Content kinds ──────────────────────────────────────────────────────────

  Widget _textVoice(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 9, 12, 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (msg.replyToText != null) ...[
            ReplyQuote(
              label: '↩',
              text: msg.replyToText!,
              isMe: _onDark,
              imageUrl: msg.replyToImageUrl,
              thumbBase64: msg.replyToThumb,
              isVideo: ReplyQuote.looksLikeVideo(msg.replyToText!),
            ),
            const SizedBox(height: 7),
          ],
          if (msg.type == MessageType.voice ||
              msg.type == MessageType.audioFile)
            _audioRow()
          else if (msg.type == MessageType.document)
            _documentRow()
          else
            Align(
              alignment: Alignment.centerLeft,
              widthFactor: 1,
              child: Text(msg.text ?? '', style: ChatStyle.body(_onDark)),
            ),
          const SizedBox(height: 3),
          _meta(),
        ],
      ),
    );
  }

  Widget _photo(BuildContext context) {
    final url = msg.imageUrl;
    final hasCaption = msg.text != null && msg.text!.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (msg.replyToText != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 2, 2, 5),
            child: ReplyQuote(
              label: '↩',
              text: msg.replyToText!,
              isMe: _onDark,
              imageUrl: msg.replyToImageUrl,
              thumbBase64: msg.replyToThumb,
            ),
          ),
        Stack(children: [
          if (url != null)
            BubblePhoto(
              url: url,
              isMe: _onDark,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => FullScreenImageViewer(url: url)),
              ),
            ),
          if (!hasCaption)
            Positioned(
              right: 8,
              bottom: 8,
              child: BubbleMeta(time: msg.timestamp, isMe: _onDark, onMedia: true),
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
                  child: Text(msg.text!, style: ChatStyle.body(_onDark)),
                ),
                const SizedBox(height: 3),
                _meta(),
              ],
            ),
          ),
      ],
    );
  }

  Widget _video(BuildContext context) {
    final url = msg.videoUrl;
    final hasCaption = msg.text != null && msg.text!.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(children: [
          if (url != null)
            VideoPreview(
              videoUrl: url,
              thumbUrl: msg.videoThumbUrl,
              durationMs: msg.videoDurationMs,
              isMe: _onDark,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => FullScreenVideoViewer(url: url)),
              ),
            ),
          if (!hasCaption)
            Positioned(
              right: 8,
              bottom: 8,
              child: BubbleMeta(time: msg.timestamp, isMe: _onDark, onMedia: true),
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
                  child: Text(msg.text!, style: ChatStyle.body(_onDark)),
                ),
                const SizedBox(height: 3),
                _meta(),
              ],
            ),
          ),
      ],
    );
  }

  Widget _audioRow() {
    final color = _onDark ? Colors.white : ChatStyle.violet;
    final isFile = msg.type == MessageType.audioFile;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTogglePlay,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: _onDark ? 0.22 : 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: color,
              size: 22,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isFile)
              Text(
                msg.fileName ?? 'Audio',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ChatStyle.body(_onDark)
                    .copyWith(fontSize: 13, fontWeight: FontWeight.w600),
              )
            else
              Row(
                children: List.generate(
                  18,
                  (i) => Container(
                    width: 3,
                    height: (5 + (i % 4) * 4).toDouble(),
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: isPlaying ? 1 : 0.45),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 3),
            Text(
              _fmtDur(msg.audioDurationSeconds ?? 0),
              style: ChatStyle.meta(_onDark),
            ),
          ],
        ),
      ],
    );
  }

  Widget _documentRow() {
    final color = _onDark ? Colors.white : ChatStyle.violet;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.insert_drive_file_rounded, color: color, size: 30),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            msg.fileName ?? 'Document',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ChatStyle.body(_onDark).copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  String _fmtDur(int s) =>
      '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

class _Tombstone extends StatelessWidget {
  const _Tombstone();

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.block_rounded, size: 15, color: ChatStyle.mist),
          SizedBox(width: 6),
          Text('This message was deleted',
              style: TextStyle(
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                  color: ChatStyle.mist)),
        ],
      );
}
