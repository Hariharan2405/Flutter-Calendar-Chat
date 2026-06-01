import 'package:flutter/material.dart';
import '../constants/app_theme.dart';

/// Reusable voice-message bubble used by both ChatDetailScreen and GroupChatScreen.
///
/// All playback state lives in the parent screen (single AudioPlayer shared
/// across all bubbles). This widget just reads the notifiers and draws itself.
class VoiceMessagePlayer extends StatefulWidget {
  final String messageId;
  final String? audioUrl;
  final int totalSeconds;
  final bool isMine;

  // Shared playback state — owned by the parent screen
  final ValueNotifier<String?> playingIdNotifier;   // which msg is "active"
  final ValueNotifier<bool> isPlayingNotifier;       // actually playing vs paused
  final ValueNotifier<Duration> positionNotifier;
  final ValueNotifier<Duration?> durationNotifier;

  final VoidCallback onToggle;
  final void Function(Duration) onSeek;

  const VoiceMessagePlayer({
    super.key,
    required this.messageId,
    required this.audioUrl,
    required this.totalSeconds,
    required this.isMine,
    required this.playingIdNotifier,
    required this.isPlayingNotifier,
    required this.positionNotifier,
    required this.durationNotifier,
    required this.onToggle,
    required this.onSeek,
  });

  @override
  State<VoiceMessagePlayer> createState() => _VoiceMessagePlayerState();
}

class _VoiceMessagePlayerState extends State<VoiceMessagePlayer> {
  // Fixed waveform shape — gives every bubble a natural voice-audio look
  static const _barHeights = [
    8.0, 13.0, 20.0, 24.0, 16.0, 22.0, 10.0, 18.0, 26.0, 14.0,
    8.0,  22.0, 18.0, 26.0, 12.0, 20.0, 24.0, 10.0, 18.0, 22.0,
    14.0, 26.0, 16.0,  8.0, 20.0, 24.0, 18.0, 12.0,
  ];

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

  String _fmt(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

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
    final elapsed = position.inSeconds;

    final activeColor =
        widget.isMine ? Colors.white : AppColors.primary;
    final dimColor = widget.isMine
        ? Colors.white.withValues(alpha: 0.28)
        : AppColors.primary.withValues(alpha: 0.22);
    final timeColor = widget.isMine
        ? Colors.white.withValues(alpha: 0.72)
        : AppColors.textSecondary;
    final btnBg = widget.isMine
        ? Colors.white.withValues(alpha: 0.18)
        : AppColors.primary.withValues(alpha: 0.1);

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // ── Play / pause button ─────────────────────────────────────────────
        GestureDetector(
          onTap: widget.onToggle,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: isActive ? activeColor.withValues(alpha: 0.22) : btnBg,
              shape: BoxShape.circle,
              border: isActive
                  ? Border.all(color: activeColor.withValues(alpha: 0.4), width: 1.5)
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
        // ── Waveform + time ─────────────────────────────────────────────────
        SizedBox(
          width: 152,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Interactive waveform
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
                      height: 30,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: List.generate(_barHeights.length, (i) {
                          final barFraction = i / (_barHeights.length - 1);
                          final played = barFraction <= progress;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 80),
                            width: 3.5,
                            height: _barHeights[i],
                            decoration: BoxDecoration(
                              color: played ? activeColor : dimColor,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          );
                        }),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 4),
              // Elapsed  ·  Total
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _fmt(elapsed),
                    style: TextStyle(
                      fontSize: 10,
                      color: isActive ? activeColor.withValues(alpha: 0.9) : timeColor,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    _fmt(widget.totalSeconds),
                    style: TextStyle(
                      fontSize: 10,
                      color: timeColor,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
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
