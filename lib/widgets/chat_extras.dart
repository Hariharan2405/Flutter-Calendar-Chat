import 'package:flutter/material.dart';

import '../constants/app_theme.dart';

/// The six emoji offered on the quick-react row. Kept short deliberately —
/// a long row turns a one-tap gesture into a decision.
const kQuickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// Horizontal emoji row shown above the long-press menu. Highlights the one the
/// current user already picked so tapping it again reads as "remove".
class ReactionPickerRow extends StatelessWidget {
  final String? current;
  final ValueChanged<String> onPick;

  const ReactionPickerRow({super.key, required this.current, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: kQuickReactions.map((e) {
          final selected = current == e;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: GestureDetector(
              onTap: () => onPick(e),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.primary.withValues(alpha: 0.15)
                      : Colors.transparent,
                  shape: BoxShape.circle,
                  border: selected
                      ? Border.all(color: AppColors.primary, width: 1.5)
                      : null,
                ),
                child: Text(e, style: const TextStyle(fontSize: 24)),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// The reaction summary that sits under a bubble: one chip per distinct emoji
/// with a count, so three thumbs-ups read as "👍 3" rather than three icons.
class ReactionChips extends StatelessWidget {
  final Map<String, String> reactions;
  final VoidCallback? onTap;

  const ReactionChips({super.key, required this.reactions, this.onTap});

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();

    final counts = <String, int>{};
    for (final emoji in reactions.values) {
      counts[emoji] = (counts[emoji] ?? 0) + 1;
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(top: 2),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.divider),
          boxShadow: const [
            BoxShadow(color: AppColors.cardShadow, blurRadius: 3, offset: Offset(0, 1)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: counts.entries.map((e) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Text(
                e.value > 1 ? '${e.key} ${e.value}' : e.key,
                style: const TextStyle(fontSize: 12),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

/// Banner pinned under the app bar showing the currently pinned message.
class PinnedBanner extends StatelessWidget {
  final String text;
  final VoidCallback onTapJump;
  final VoidCallback onUnpin;

  const PinnedBanner({
    super.key,
    required this.text,
    required this.onTapJump,
    required this.onUnpin,
  });

  @override
  Widget build(BuildContext context) {
    // A floating card under the header rather than a flat strip.
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
      child: Material(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(16),
        elevation: 0,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTapJump,
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x142A1170),
                    blurRadius: 12,
                    offset: Offset(0, 4)),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.push_pin_rounded,
                      size: 16, color: AppColors.primary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Pinned message',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary,
                          letterSpacing: .3,
                        ),
                      ),
                      Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13, color: AppColors.textPrimary),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  color: AppColors.textSecondary,
                  tooltip: 'Unpin',
                  onPressed: onUnpin,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Typing" shown as an incoming bubble with three bouncing dots, plus a
/// short label (the name, in group chats). Rendered only while the stamp is
/// fresh; the caller owns that decision via [TypingState.isActive].
class TypingIndicator extends StatefulWidget {
  final String label;

  const TypingIndicator({super.key, required this.label});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
                bottomRight: Radius.circular(20),
                bottomLeft: Radius.circular(6),
              ),
              boxShadow: [
                BoxShadow(
                    color: Color(0x142A1170),
                    blurRadius: 10,
                    offset: Offset(0, 3)),
              ],
            ),
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 3; i++) ...[
                    if (i > 0) const SizedBox(width: 5),
                    _dot(i),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Each dot rises in turn, a third of a cycle after the one before.
  Widget _dot(int i) {
    final phase = (_ctrl.value - i / 3) % 1.0;
    final lift = phase < 0.5 ? (phase < 0.25 ? phase : 0.5 - phase) * 4 : 0.0;
    return Transform.translate(
      offset: Offset(0, -4 * lift),
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.35 + 0.5 * lift),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// Reads a `typing_<uid>` timestamp and decides whether it still counts.
///
/// There is no "stopped typing" write to rely on — if the app is killed
/// mid-compose the last stamp just stays there — so freshness is what makes the
/// indicator honest.
class TypingState {
  static const _staleAfter = Duration(seconds: 6);

  static bool isActive(dynamic timestamp) {
    if (timestamp == null) return false;
    try {
      final dt = timestamp.toDate() as DateTime;
      return DateTime.now().difference(dt) < _staleAfter;
    } catch (_) {
      return false;
    }
  }
}

/// A document attachment bubble — icon, file name, size, and a tap target.
class DocumentBubble extends StatelessWidget {
  final String fileName;
  final int? sizeBytes;
  final bool isMe;
  final VoidCallback onOpen;

  const DocumentBubble({
    super.key,
    required this.fileName,
    required this.sizeBytes,
    required this.isMe,
    required this.onOpen,
  });

  static IconData iconFor(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    switch (ext) {
      case 'pdf':
        return Icons.picture_as_pdf_rounded;
      case 'doc':
      case 'docx':
        return Icons.description_rounded;
      case 'xls':
      case 'xlsx':
      case 'csv':
        return Icons.table_chart_rounded;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow_rounded;
      case 'zip':
      case 'rar':
        return Icons.folder_zip_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  static String formatSize(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final fg = isMe ? Colors.white : AppColors.textPrimary;
    final subFg = isMe ? Colors.white70 : AppColors.textSecondary;

    return GestureDetector(
      onTap: onOpen,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: (isMe ? Colors.white : AppColors.primary)
                  .withValues(alpha: isMe ? 0.22 : 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(iconFor(fileName),
                size: 21, color: isMe ? Colors.white : AppColors.primary),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  fileName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: fg),
                ),
                if (formatSize(sizeBytes).isNotEmpty)
                  Text(formatSize(sizeBytes),
                      style: TextStyle(fontSize: 11, color: subFg)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small "Forwarded" label placed above a forwarded bubble's content.
class ForwardedLabel extends StatelessWidget {
  final bool isMe;
  const ForwardedLabel({super.key, required this.isMe});

  @override
  Widget build(BuildContext context) {
    final color = isMe ? Colors.white70 : AppColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.shortcut_rounded, size: 12, color: color),
          const SizedBox(width: 4),
          Text('Forwarded',
              style: TextStyle(
                  fontSize: 11, fontStyle: FontStyle.italic, color: color)),
        ],
      ),
    );
  }
}

/// The tombstone shown in place of a message deleted for everyone.
class DeletedBubble extends StatelessWidget {
  final bool isMe;
  const DeletedBubble({super.key, required this.isMe});

  @override
  Widget build(BuildContext context) {
    final color = isMe ? Colors.white70 : AppColors.textSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.block_rounded, size: 14, color: color),
        const SizedBox(width: 6),
        Text(
          'This message was deleted',
          style: TextStyle(
              fontSize: 13, fontStyle: FontStyle.italic, color: color),
        ),
      ],
    );
  }
}

/// Asks which flavour of delete the user meant. "For everyone" is only offered
/// on your own messages — you can always remove someone else's copy from your
/// own view, never from theirs.
enum DeleteChoice { forMe, forEveryone }

Future<DeleteChoice?> showDeleteChoice(BuildContext context,
    {required bool canDeleteForEveryone}) {
  return showModalBottomSheet<DeleteChoice>(
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
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Delete message?',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.visibility_off_rounded,
                color: AppColors.textSecondary),
            title: const Text('Delete for me'),
            subtitle: const Text('Removed from your device only',
                style: TextStyle(fontSize: 12)),
            onTap: () => Navigator.pop(ctx, DeleteChoice.forMe),
          ),
          if (canDeleteForEveryone)
            ListTile(
              leading: const Icon(Icons.delete_forever_rounded,
                  color: AppColors.holiday),
              title: const Text('Delete for everyone',
                  style: TextStyle(color: AppColors.holiday)),
              subtitle: const Text('Replaced with "This message was deleted"',
                  style: TextStyle(fontSize: 12)),
              onTap: () => Navigator.pop(ctx, DeleteChoice.forEveryone),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
