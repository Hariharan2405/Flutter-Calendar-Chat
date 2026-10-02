import 'package:flutter/material.dart';
import '../constants/app_theme.dart';

/// WhatsApp-style audio-file bubble used by both ChatDetailScreen and
/// GroupChatScreen. Shows the file name, a play/pause button, a thin seek bar
/// with elapsed/total time, the file size, and a download button.
///
/// Playback state is owned by the parent screen (single shared AudioPlayer),
/// exactly like [VoiceMessagePlayer]. This widget only reads the notifiers and
/// reports taps back through callbacks. Download progress is local state.
class AudioFileMessage extends StatefulWidget {
  final String messageId;
  final String? audioUrl;
  final String fileName;
  final int? fileSizeBytes;
  final int totalSeconds;
  final bool isMine;

  /// True when this file has already been saved to the device (and still
  /// exists) — the download button is replaced by a "downloaded" indicator.
  final bool isSaved;

  // Shared playback state — owned by the parent screen
  final ValueNotifier<String?> playingIdNotifier;
  final ValueNotifier<bool> isPlayingNotifier;
  final ValueNotifier<Duration> positionNotifier;
  final ValueNotifier<Duration?> durationNotifier;

  final VoidCallback onToggle;
  final void Function(Duration) onSeek;

  /// Downloads the file to the device. Returns true on success. The widget
  /// shows a spinner while the future is in flight.
  final Future<bool> Function() onDownload;

  const AudioFileMessage({
    super.key,
    required this.messageId,
    required this.audioUrl,
    required this.fileName,
    required this.fileSizeBytes,
    required this.totalSeconds,
    required this.isMine,
    this.isSaved = false,
    required this.playingIdNotifier,
    required this.isPlayingNotifier,
    required this.positionNotifier,
    required this.durationNotifier,
    required this.onToggle,
    required this.onSeek,
    required this.onDownload,
  });

  @override
  State<AudioFileMessage> createState() => _AudioFileMessageState();
}

class _AudioFileMessageState extends State<AudioFileMessage> {
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    widget.playingIdNotifier.addListener(_onNotify);
    widget.isPlayingNotifier.addListener(_onNotify);
    widget.positionNotifier.addListener(_onNotify);
    widget.durationNotifier.addListener(_onNotify);
  }

  void _onNotify() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.playingIdNotifier.removeListener(_onNotify);
    widget.isPlayingNotifier.removeListener(_onNotify);
    widget.positionNotifier.removeListener(_onNotify);
    widget.durationNotifier.removeListener(_onNotify);
    super.dispose();
  }

  String _fmtTime(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  String _fmtSize(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _download() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      await widget.onDownload();
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isActive = widget.playingIdNotifier.value == widget.messageId;
    final isPlaying = isActive && widget.isPlayingNotifier.value;
    final position = isActive ? widget.positionNotifier.value : Duration.zero;
    final realDur = isActive ? widget.durationNotifier.value : null;
    final totalDur = realDur ??
        Duration(seconds: widget.totalSeconds > 0 ? widget.totalSeconds : 1);
    final progress =
        (position.inMilliseconds / totalDur.inMilliseconds).clamp(0.0, 1.0);

    final activeColor = widget.isMine ? Colors.white : AppColors.primary;
    final dimColor = widget.isMine
        ? Colors.white.withValues(alpha: 0.28)
        : AppColors.primary.withValues(alpha: 0.20);
    final subColor = widget.isMine
        ? Colors.white.withValues(alpha: 0.72)
        : AppColors.textSecondary;
    final btnBg = widget.isMine
        ? Colors.white.withValues(alpha: 0.18)
        : AppColors.primary.withValues(alpha: 0.1);

    // Show the real total once known (after first play); otherwise the stored one.
    final shownTotal = isActive && realDur != null
        ? realDur.inSeconds
        : widget.totalSeconds;
    final elapsed = isActive ? position.inSeconds : 0;
    final sizeStr = _fmtSize(widget.fileSizeBytes);
    final meta = [
      if (shownTotal > 0) '${_fmtTime(elapsed)} / ${_fmtTime(shownTotal)}',
      if (sizeStr.isNotEmpty) sizeStr,
    ].join('  ·  ');

    return SizedBox(
      width: 214,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Play / pause ────────────────────────────────────────────────
          GestureDetector(
            onTap: widget.audioUrl == null ? null : widget.onToggle,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: isActive ? activeColor.withValues(alpha: 0.22) : btnBg,
                shape: BoxShape.circle,
                border: isActive
                    ? Border.all(
                        color: activeColor.withValues(alpha: 0.4), width: 1.5)
                    : null,
              ),
              child: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: activeColor,
                size: 24,
              ),
            ),
          ),
          const SizedBox(width: 10),
          // ── Name + seek bar + meta ──────────────────────────────────────
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.audiotrack_rounded, size: 14, color: activeColor),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        widget.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: widget.isMine
                              ? Colors.white
                              : AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // Thin seek bar
                LayoutBuilder(
                  builder: (ctx, constraints) {
                    final w = constraints.maxWidth;
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: isActive
                          ? (d) => _handleSeek(d.localPosition.dx, w)
                          : null,
                      onHorizontalDragUpdate: isActive
                          ? (d) => _handleSeek(d.localPosition.dx, w)
                          : null,
                      child: SizedBox(
                        height: 14,
                        child: Stack(
                          alignment: Alignment.centerLeft,
                          children: [
                            Container(
                              height: 3,
                              decoration: BoxDecoration(
                                color: dimColor,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            FractionallySizedBox(
                              widthFactor: progress,
                              child: Container(
                                height: 3,
                                decoration: BoxDecoration(
                                  color: activeColor,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 4),
                if (meta.isNotEmpty)
                  Text(
                    meta,
                    style: TextStyle(
                      fontSize: 10,
                      color: subColor,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          // ── Download / saved indicator ──────────────────────────────────
          widget.isSaved
              ? SizedBox(
                  width: 34,
                  height: 34,
                  child: Icon(Icons.download_done_rounded,
                      color: activeColor, size: 22),
                )
              : GestureDetector(
                  onTap: _download,
                  child: SizedBox(
                    width: 34,
                    height: 34,
                    child: _downloading
                        ? Padding(
                            padding: const EdgeInsets.all(7),
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: activeColor),
                          )
                        : Icon(Icons.download_rounded,
                            color: activeColor, size: 22),
                  ),
                ),
        ],
      ),
    );
  }

  void _handleSeek(double localX, double totalWidth) {
    final ratio = (localX / totalWidth).clamp(0.0, 1.0);
    final totalDur = widget.durationNotifier.value ??
        Duration(seconds: widget.totalSeconds > 0 ? widget.totalSeconds : 1);
    widget.onSeek(
      Duration(milliseconds: (totalDur.inMilliseconds * ratio).round()),
    );
  }
}
