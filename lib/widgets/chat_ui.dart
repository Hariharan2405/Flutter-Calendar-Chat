import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/chat_prefs.dart';
import '../services/media_cache.dart';
import '../services/video_thumbs.dart';
import '../utils/image_sizing.dart';

/// Visual language shared by the chat list, the private chat and group chat,
/// so the three screens read as one product rather than three.
class ChatStyle {
  ChatStyle._();

  // ── Colour ────────────────────────────────────────────────────────────────

  static const Color violet = Color(0xFF6C3CF0);
  static const Color violetDeep = Color(0xFF4B23C4);
  static const Color orchid = Color(0xFF9B6BFF);
  static const Color ink = Color(0xFF16132B);
  static const Color mist = Color(0xFF8B87A6);
  static const Color online = Color(0xFF22C55E);

  /// Headers: deep violet into orchid. Horizontal, so an app bar and a band
  /// placed under it share identical colours and join without a seam.
  static const LinearGradient header = LinearGradient(
    colors: [violetDeep, violet, orchid],
    stops: [0.0, 0.55, 1.0],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  /// Ring around an unviewed status — warm, so it reads on the violet header
  /// as well as on white.
  static const LinearGradient storyRing = LinearGradient(
    colors: [Color(0xFFFFC857), Color(0xFFFF6B6B), Color(0xFFD946EF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Your own messages.
  static const LinearGradient outgoing = LinearGradient(
    colors: [Color(0xFF8257FF), Color(0xFF5B30DC)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Default conversation backdrop when no wallpaper is chosen.
  static const LinearGradient canvas = LinearGradient(
    colors: [Color(0xFFEEE9FF), Color(0xFFF7F5FF), Color(0xFFFDFCFF)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static const List<BoxShadow> bubbleShadow = [
    BoxShadow(color: Color(0x142A1170), blurRadius: 10, offset: Offset(0, 3)),
  ];

  static const List<BoxShadow> floatingShadow = [
    BoxShadow(color: Color(0x1F2A1170), blurRadius: 24, offset: Offset(0, 8)),
  ];

  // ── Shape ─────────────────────────────────────────────────────────────────

  static const double radius = 20;
  static const double tail = 6;

  /// Bubble corners. Only the last bubble of a run gets the pointed "tail"
  /// corner, the way messages group in a real conversation.
  static BorderRadius bubbleRadius({required bool isMe, bool tail = true}) {
    const r = Radius.circular(radius);
    const t = Radius.circular(ChatStyle.tail);
    return BorderRadius.only(
      topLeft: r,
      topRight: r,
      bottomLeft: isMe || !tail ? r : t,
      bottomRight: !isMe || !tail ? r : t,
    );
  }

  // ── Text ──────────────────────────────────────────────────────────────────

  static TextStyle body(bool isMe) => TextStyle(
        color: isMe ? Colors.white : ink,
        fontSize: 15 * ChatPrefs.instance.textScale,
        height: 1.38,
        letterSpacing: 0.05,
      );

  static TextStyle meta(bool isMe) => TextStyle(
        fontSize: 10.5,
        color: isMe ? Colors.white.withValues(alpha: 0.72) : mist,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  static String time(DateTime t) => DateFormat('h:mm a').format(t);
}

/// The gradient behind an [AppBar]: set as `flexibleSpace`.
///
/// AppBar gives its flexible space loose constraints, and a childless
/// DecoratedBox sizes to the smallest it may — zero — which left the header
/// white with the white title and icons invisible on it. SizedBox.expand
/// makes it fill the bar.
class ChatHeaderBackground extends StatelessWidget {
  const ChatHeaderBackground({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.expand(
        child: DecoratedBox(
          decoration: BoxDecoration(gradient: ChatStyle.header),
        ),
      );
}

/// A message bubble: gradient for your own messages, white for others'.
class BubbleFrame extends StatelessWidget {
  final bool isMe;
  final bool tail;
  final Widget child;

  /// For media, the inset between the bubble edge and the photo.
  final EdgeInsets padding;

  /// A solid fill in place of the defaults — group chat gives some members
  /// a fixed colour of their own.
  final Color? color;

  const BubbleFrame({
    super.key,
    required this.isMe,
    required this.child,
    this.tail = true,
    this.padding = EdgeInsets.zero,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final radius = ChatStyle.bubbleRadius(isMe: isMe, tail: tail);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: color == null && isMe ? ChatStyle.outgoing : null,
        color: color ?? (isMe ? null : Colors.white),
        borderRadius: radius,
        boxShadow: ChatStyle.bubbleShadow,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// The time and delivery ticks that sit at the bottom-right of a bubble.
class BubbleMeta extends StatelessWidget {
  final DateTime time;
  final bool isMe;
  final bool edited;
  final Widget? ticks;
  final List<Widget> leading;

  /// For a time drawn over a photo, where bubble colours don't apply.
  final bool onMedia;

  const BubbleMeta({
    super.key,
    required this.time,
    required this.isMe,
    this.edited = false,
    this.ticks,
    this.leading = const [],
    this.onMedia = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = onMedia
        ? const TextStyle(
            fontSize: 10.5,
            color: Colors.white,
            fontWeight: FontWeight.w500,
          )
        : ChatStyle.meta(isMe);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ...leading,
        if (edited)
          Text('edited  ',
              style: style.copyWith(fontStyle: FontStyle.italic)),
        Text(ChatStyle.time(time), style: style),
        if (ticks != null) ...[const SizedBox(width: 3), ticks!],
      ],
    );
    if (!onMedia) return row;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(10),
      ),
      child: row,
    );
  }
}

/// A photo inside a bubble, with rounded inner corners.
class BubblePhoto extends StatelessWidget {
  final String url;
  final bool isMe;
  final VoidCallback? onTap;
  final double radius;

  const BubblePhoto({
    super.key,
    required this.url,
    required this.isMe,
    this.onTap,
    this.radius = ChatStyle.radius - 4,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 120, maxHeight: 340),
          child: CachedNetworkImage(
            imageUrl: url,
            cacheManager: mediaCacheManager,
            memCacheWidth: kBubbleImageDecodeWidth,
            width: double.infinity,
            fit: BoxFit.cover,
            fadeInDuration: const Duration(milliseconds: 180),
            placeholder: (_, __) => _MediaPlaceholder(isMe: isMe),
            errorWidget: (_, __, ___) => _MediaPlaceholder(
              isMe: isMe,
              icon: Icons.broken_image_outlined,
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaPlaceholder extends StatelessWidget {
  final bool isMe;
  final IconData? icon;
  const _MediaPlaceholder({required this.isMe, this.icon});

  @override
  Widget build(BuildContext context) => Container(
        height: 200,
        color: isMe
            ? Colors.white.withValues(alpha: 0.14)
            : const Color(0xFFF1EEFB),
        alignment: Alignment.center,
        child: icon != null
            ? Icon(icon, color: ChatStyle.mist)
            : SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: isMe ? Colors.white70 : ChatStyle.violet,
                ),
              ),
      );
}

/// A video preview: a real frame of the video, a play button and its length.
///
/// Uses the still uploaded with the video when there is one. Videos sent
/// before stills existed get a frame made on the phone from the cached copy,
/// so nothing shows as a plain black box any more.
class VideoPreview extends StatelessWidget {
  final String videoUrl;
  final String? thumbUrl;
  final int? durationMs;
  final bool isMe;
  final VoidCallback? onTap;
  final double radius;
  final double height;

  const VideoPreview({
    super.key,
    required this.videoUrl,
    required this.isMe,
    this.thumbUrl,
    this.durationMs,
    this.onTap,
    this.radius = ChatStyle.radius - 4,
    this.height = 210,
  });

  @override
  Widget build(BuildContext context) {
    final Widget frame = thumbUrl != null
        ? CachedNetworkImage(
            imageUrl: thumbUrl!,
            cacheManager: mediaCacheManager,
            memCacheWidth: kBubbleImageDecodeWidth,
            fit: BoxFit.cover,
            fadeInDuration: const Duration(milliseconds: 180),
            placeholder: (_, __) => const _VideoBackdrop(),
            errorWidget: (_, __, ___) => _LocalFrame(videoUrl: videoUrl),
          )
        : _LocalFrame(videoUrl: videoUrl);

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              frame,
              // Lifts the play button and chips off busy frames.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0x00000000), Color(0x66000000)],
                    begin: Alignment.center,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),
              Center(
                child: Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.42),
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.85), width: 2),
                  ),
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 36),
                ),
              ),
              Positioned(
                left: 10,
                bottom: 8,
                child: Row(
                  children: [
                    const Icon(Icons.videocam_rounded,
                        color: Colors.white, size: 15),
                    if (durationMs != null) ...[
                      const SizedBox(width: 4),
                      Text(
                        formatDuration(durationMs!),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String formatDuration(int ms) {
    final total = (ms / 1000).round();
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

class _VideoBackdrop extends StatelessWidget {
  const _VideoBackdrop();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF2B2440), Color(0xFF15121F)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
      );
}

/// A frame made on the phone, for a video that was sent without one.
class _LocalFrame extends StatefulWidget {
  final String videoUrl;
  const _LocalFrame({required this.videoUrl});

  @override
  State<_LocalFrame> createState() => _LocalFrameState();
}

class _LocalFrameState extends State<_LocalFrame> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = VideoThumbs.peekLocalFrame(widget.videoUrl);
    if (_bytes == null) {
      VideoThumbs.localFrame(widget.videoUrl).then((b) {
        if (mounted && b != null) setState(() => _bytes = b);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return const _VideoBackdrop();
    return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
  }
}

/// The quoted message shown above a reply, with a thumbnail when the quoted
/// message was a photo, video or status.
class ReplyQuote extends StatelessWidget {
  final String label;
  final String text;
  final bool isMe;
  final String? imageUrl;

  /// Inline base64 preview — used for statuses, whose media is deleted after
  /// 24 hours, and for videos without an uploaded still.
  final String? thumbBase64;
  final bool isVideo;
  final VoidCallback? onTap;

  const ReplyQuote({
    super.key,
    required this.label,
    required this.text,
    required this.isMe,
    this.imageUrl,
    this.thumbBase64,
    this.isVideo = false,
    this.onTap,
  });

  /// Guesses whether a quoted message was a video from its preview text.
  static bool looksLikeVideo(String text) =>
      text.startsWith('🎬') || text.startsWith('🎥') || text.startsWith('📹');

  @override
  Widget build(BuildContext context) {
    final accent = isMe ? Colors.white : ChatStyle.violet;
    Widget? thumb;
    final bytes = _decode(thumbBase64);
    if (bytes != null) {
      thumb = Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
    } else if (imageUrl != null) {
      thumb = CachedNetworkImage(
        imageUrl: imageUrl!,
        cacheManager: mediaCacheManager,
        memCacheWidth: 132,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => const SizedBox.shrink(),
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: isMe
              ? Colors.white.withValues(alpha: 0.16)
              : const Color(0xFFF2EEFF),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 3.5, color: accent.withValues(alpha: 0.9)),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(9, 6, 10, 7),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: accent,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.3,
                          color: isMe
                              ? Colors.white.withValues(alpha: 0.82)
                              : ChatStyle.mist,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (thumb != null)
                SizedBox(
                  width: 48,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      thumb,
                      if (isVideo)
                        const Center(
                          child: Icon(Icons.play_circle_fill_rounded,
                              color: Colors.white, size: 20),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static final Map<String, Uint8List> _decoded = {};

  static Uint8List? _decode(String? b64) {
    if (b64 == null || b64.isEmpty) return null;
    final hit = _decoded[b64];
    if (hit != null) return hit;
    try {
      final bytes = base64Decode(b64);
      if (_decoded.length > 80) _decoded.remove(_decoded.keys.first);
      return _decoded[b64] = bytes;
    } catch (_) {
      return null;
    }
  }
}

/// The "Today" / "Yesterday" / date marker between days.
class DatePill extends StatelessWidget {
  final DateTime date;
  const DatePill({super.key, required this.date});

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final label = _sameDay(date, now)
        ? 'Today'
        : _sameDay(date, now.subtract(const Duration(days: 1)))
            ? 'Yesterday'
            : now.difference(date).inDays < 7
                ? DateFormat('EEEE').format(date)
                : DateFormat('d MMM yyyy').format(date);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(20),
            boxShadow: ChatStyle.bubbleShadow,
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: ChatStyle.mist,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ),
    );
  }
}

/// Round gradient button for send / record.
class GradientCircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final Color? color;

  const GradientCircleButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 50,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: color == null ? ChatStyle.outgoing : null,
          color: color,
          boxShadow: const [
            BoxShadow(
                color: Color(0x405B30DC), blurRadius: 14, offset: Offset(0, 5)),
          ],
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          transitionBuilder: (child, anim) =>
              ScaleTransition(scale: anim, child: child),
          child: Icon(icon, key: ValueKey(icon), color: Colors.white, size: 24),
        ),
      ),
    );
  }
}

/// The floating rounded field the composer sits in.
BoxDecoration composerDecoration() => BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(28),
      boxShadow: ChatStyle.floatingShadow,
    );

/// A circular avatar with an optional online dot, used in chat headers.
class HeaderAvatar extends StatelessWidget {
  final String? photoUrl;
  final String name;
  final bool online;
  final double radius;

  const HeaderAvatar({
    super.key,
    required this.photoUrl,
    required this.name,
    this.online = false,
    this.radius = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.55), width: 1.5),
          ),
          child: CircleAvatar(
            radius: radius,
            backgroundColor: Colors.white.withValues(alpha: 0.22),
            backgroundImage: photoUrl != null
                ? avatarImage(photoUrl!, radius: radius)
                : null,
            child: photoUrl == null
                ? Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: radius * 0.85,
                    ),
                  )
                : null,
          ),
        ),
        if (online)
          Positioned(
            right: 1,
            bottom: 1,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: ChatStyle.online,
                shape: BoxShape.circle,
                border: Border.all(color: ChatStyle.violet, width: 2),
              ),
            ),
          ),
      ],
    );
  }
}

/// Text for the quoted-message label in a reply bubble.
String replyLabel({
  required String? replyToSenderId,
  required String currentUid,
  required String otherName,
  String? replyToSenderName,
}) {
  if (replyToSenderId == currentUid) return 'You';
  return replyToSenderName ?? otherName;
}

// ── Conversation backdrop ─────────────────────────────────────────────────────

/// The default conversation background: the soft gradient with a faint dot
/// texture, so a long chat doesn't sit on a flat wash of colour.
class ChatCanvas extends StatelessWidget {
  final Widget child;
  const ChatCanvas({super.key, required this.child});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(gradient: ChatStyle.canvas),
        child: CustomPaint(
          painter: const _DotTexturePainter(),
          child: child,
        ),
      );
}

class _DotTexturePainter extends CustomPainter {
  const _DotTexturePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0x0F6C3CF0);
    const step = 22.0;
    var row = 0;
    for (double y = 8; y < size.height; y += step, row++) {
      // Offset alternate rows for a woven look rather than a grid.
      final x0 = row.isEven ? 8.0 : 8.0 + step / 2;
      for (double x = x0; x < size.width; x += step) {
        canvas.drawCircle(Offset(x, y), 1.3, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ── Big emoji ─────────────────────────────────────────────────────────────────

bool _isEmojiRune(int r) =>
    (r >= 0x1F000 && r <= 0x1FAFF) || // pictographs, skin tones, flags
    (r >= 0x2600 && r <= 0x27BF) || // misc symbols, dingbats
    (r >= 0x2300 && r <= 0x23FF) || // ⌚ ⏰ …
    (r >= 0x2B00 && r <= 0x2BFF) || // ⭐ ⬆ …
    (r >= 0x2190 && r <= 0x21FF) || // arrows used as emoji
    (r >= 0xE0020 && r <= 0xE007F) || // flag tags
    r == 0x200D || // zero-width joiner
    r == 0xFE0F ||
    r == 0xFE0E ||
    r == 0x20E3 ||
    r == 0x00A9 ||
    r == 0x00AE ||
    r == 0x203C ||
    r == 0x2049 ||
    r == 0x2122 ||
    r == 0x2139 ||
    r == 0x3030 ||
    r == 0x303D ||
    r == 0x3297 ||
    r == 0x3299;

/// How many emoji [text] is made of, if it is nothing but 1–3 emoji (spaces
/// allowed); otherwise 0. Such messages are shown large, without a bubble.
int jumboEmojiCount(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return 0;
  for (final r in trimmed.runes) {
    if (r == 0x20 || r == 0x0A) continue;
    if (!_isEmojiRune(r)) return 0;
  }
  final count = trimmed.characters.where((c) => c.trim().isNotEmpty).length;
  return count >= 1 && count <= 3 ? count : 0;
}

/// Font size for a big-emoji message of [count] emoji.
double jumboEmojiSize(int count) => switch (count) {
      1 => 52,
      2 => 42,
      _ => 34,
    };

// ── Jump to newest ────────────────────────────────────────────────────────────

/// Floating button that scrolls to the newest message, with an unread count.
class JumpToBottomButton extends StatelessWidget {
  final int unseen;
  final VoidCallback onTap;
  const JumpToBottomButton(
      {super.key, required this.unseen, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: ChatStyle.floatingShadow,
            ),
            child: const Icon(Icons.keyboard_double_arrow_down_rounded,
                color: ChatStyle.violet, size: 24),
          ),
        ),
        if (unseen > 0)
          Positioned(
            top: -6,
            right: -4,
            child: Container(
              constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
              padding: const EdgeInsets.symmetric(horizontal: 5),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: ChatStyle.outgoing,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: Text(
                unseen > 99 ? '99+' : '$unseen',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800),
              ),
            ),
          ),
      ],
    );
  }
}
