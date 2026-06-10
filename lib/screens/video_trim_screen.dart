import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';
import '../constants/app_theme.dart';
import 'dart:io';

/// Full-screen video trimmer.
/// Navigates back with the trimmed [File], or null if cancelled.
class VideoTrimScreen extends StatefulWidget {
  final File videoFile;
  const VideoTrimScreen({super.key, required this.videoFile});

  @override
  State<VideoTrimScreen> createState() => _VideoTrimScreenState();
}

class _VideoTrimScreenState extends State<VideoTrimScreen> {
  // ── Player ────────────────────────────────────────────────────────────────
  late VideoPlayerController _ctrl;
  Duration _totalDuration = Duration.zero;

  // ── Trim state (0.0–1.0 fractions of total duration) ─────────────────────
  double _startFrac = 0.0;
  double _endFrac   = 1.0;

  // ── Thumbnail strip ───────────────────────────────────────────────────────
  static const int    _thumbCount  = 10;
  static const double _stripHeight = 64.0;
  final List<Uint8List?> _thumbs = [];

  // ── UI state ──────────────────────────────────────────────────────────────
  bool _loading  = true;
  bool _playing  = false;
  bool _trimming = false;

  Timer? _playbackTimer;

  // ── Derived helpers ───────────────────────────────────────────────────────
  int get _startMs =>
      (_startFrac * _totalDuration.inMilliseconds).round();
  int get _endMs =>
      (_endFrac * _totalDuration.inMilliseconds).round();
  int get _clipMs => _endMs - _startMs;

  String _fmtMs(int ms) {
    final d = Duration(milliseconds: ms);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _playbackTimer?.cancel();
    _ctrl.removeListener(_onPlayerTick);
    _ctrl.dispose();
    VideoCompress.cancelCompression();
    super.dispose();
  }

  Future<void> _init() async {
    _ctrl = VideoPlayerController.file(widget.videoFile);
    await _ctrl.initialize();
    _totalDuration = _ctrl.value.duration;
    _ctrl.addListener(_onPlayerTick);
    if (mounted) setState(() => _loading = false);
    _buildThumbnails();
  }

  // Stop playback when we reach the end marker.
  void _onPlayerTick() {
    if (!_playing) return;
    if (_ctrl.value.position.inMilliseconds >= _endMs) {
      _ctrl.pause();
      _ctrl.seekTo(Duration(milliseconds: _startMs));
      if (mounted) setState(() => _playing = false);
    }
  }

  // ── Thumbnail generation ──────────────────────────────────────────────────

  Future<void> _buildThumbnails() async {
    final totalMs = _totalDuration.inMilliseconds;
    for (int i = 0; i < _thumbCount; i++) {
      final posMs = (totalMs * i / _thumbCount).round();
      try {
        final bytes = await VideoCompress.getByteThumbnail(
          widget.videoFile.path,
          quality: 40,
          position: posMs,
        );
        if (mounted) setState(() {
          if (_thumbs.length <= i) _thumbs.add(bytes);
          else _thumbs[i] = bytes;
        });
      } catch (_) {
        if (mounted) setState(() {
          if (_thumbs.length <= i) _thumbs.add(null);
        });
      }
    }
  }

  // ── Playback ──────────────────────────────────────────────────────────────

  Future<void> _togglePlay() async {
    if (_playing) {
      await _ctrl.pause();
      if (mounted) setState(() => _playing = false);
    } else {
      await _ctrl.seekTo(Duration(milliseconds: _startMs));
      await _ctrl.play();
      if (mounted) setState(() => _playing = true);
    }
  }

  // ── Trim & export ─────────────────────────────────────────────────────────

  Future<void> _send() async {
    if (_trimming) return;
    await _ctrl.pause();
    setState(() { _playing = false; _trimming = true; });

    try {
      // If the user selected the full video (no meaningful trim), skip re-encoding.
      final fullMs = _totalDuration.inMilliseconds;
      final isFullVideo = _startMs <= 50 && (_endMs >= fullMs - 50);

      if (isFullVideo) {
        if (mounted) Navigator.pop(context, widget.videoFile);
        return;
      }

      final info = await VideoCompress.compressVideo(
        widget.videoFile.path,
        quality: VideoQuality.DefaultQuality,
        deleteOrigin: false,
        startTime: _startMs,
        duration: _clipMs,
      );

      if (!mounted) return;
      if (info?.file != null) {
        Navigator.pop(context, info!.file);
      } else {
        _showError('Trim failed — please try again.');
        setState(() => _trimming = false);
      }
    } catch (e) {
      if (mounted) {
        _showError('Error: $e');
        setState(() => _trimming = false);
      }
    }
  }

  void _showError(String msg) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Trim Video',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        actions: [
          if (!_loading)
            _trimming
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2)),
                  )
                : TextButton.icon(
                    onPressed: _send,
                    icon: const Icon(Icons.send_rounded,
                        color: AppColors.primary, size: 18),
                    label: const Text('Send',
                        style: TextStyle(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w700)),
                  ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary))
          : Column(children: [
              // ── Video preview ──────────────────────────────────────────────
              Expanded(
                child: GestureDetector(
                  onTap: _togglePlay,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Center(
                        child: AspectRatio(
                          aspectRatio: _ctrl.value.aspectRatio,
                          child: VideoPlayer(_ctrl),
                        ),
                      ),
                      if (!_playing)
                        Container(
                          width: 62, height: 62,
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                            border:
                                Border.all(color: Colors.white38, width: 1.5),
                          ),
                          child: const Icon(Icons.play_arrow_rounded,
                              color: Colors.white, size: 36),
                        ),
                    ],
                  ),
                ),
              ),

              // ── Trim controls ──────────────────────────────────────────────
              Container(
                color: const Color(0xFF111111),
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Duration info row
                    Row(children: [
                      _chip(Icons.play_circle_outline_rounded,
                          _fmtMs(_startMs)),
                      const SizedBox(width: 6),
                      const Icon(Icons.arrow_forward_rounded,
                          color: Colors.white38, size: 14),
                      const SizedBox(width: 6),
                      _chip(Icons.stop_circle_outlined, _fmtMs(_endMs)),
                      const Spacer(),
                      _chip(Icons.timer_outlined, _fmtMs(_clipMs)),
                    ]),
                    const SizedBox(height: 14),

                    // Thumbnail strip with drag handles
                    LayoutBuilder(
                      builder: (_, constraints) =>
                          _TrimStrip(
                            width:       constraints.maxWidth,
                            height:      _stripHeight,
                            thumbCount:  _thumbCount,
                            thumbs:      _thumbs,
                            startFrac:   _startFrac,
                            endFrac:     _endFrac,
                            onStartChanged: (v) {
                              setState(() => _startFrac = v);
                              _ctrl.seekTo(
                                  Duration(milliseconds: _startMs));
                            },
                            onEndChanged: (v) =>
                                setState(() => _endFrac = v),
                          ),
                    ),

                    const SizedBox(height: 14),

                    // Play button + hint
                    Row(children: [
                      GestureDetector(
                        onTap: _togglePlay,
                        child: Container(
                          width: 40, height: 40,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: AppColors.primary.withValues(alpha: 0.5)),
                          ),
                          child: Icon(
                            _playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: AppColors.primary,
                            size: 22,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Drag the yellow handles to trim. '
                          'Tap play to preview the selected clip.',
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.4),
                              fontSize: 11),
                        ),
                      ),
                    ]),
                  ],
                ),
              ),
            ]),
    );
  }

  Widget _chip(IconData icon, String label) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: Colors.white54, size: 12),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ]),
      );
}

// ── Trim strip widget ─────────────────────────────────────────────────────────

class _TrimStrip extends StatelessWidget {
  final double width;
  final double height;
  final int thumbCount;
  final List<Uint8List?> thumbs;
  final double startFrac;
  final double endFrac;
  final ValueChanged<double> onStartChanged;
  final ValueChanged<double> onEndChanged;

  static const double _handleW = 22.0;
  static const double _minGap  = 0.05; // minimum 5 % clip

  const _TrimStrip({
    required this.width,
    required this.height,
    required this.thumbCount,
    required this.thumbs,
    required this.startFrac,
    required this.endFrac,
    required this.onStartChanged,
    required this.onEndChanged,
  });

  @override
  Widget build(BuildContext context) {
    final selLeft  = startFrac * width;
    final selRight = endFrac   * width;

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(children: [
          // ── Thumbnail frames ───────────────────────────────────────────────
          Row(
            children: List.generate(thumbCount, (i) {
              final bytes = i < thumbs.length ? thumbs[i] : null;
              return Expanded(
                child: SizedBox(
                  height: height,
                  child: bytes != null
                      ? Image.memory(bytes,
                            fit: BoxFit.cover, gaplessPlayback: true)
                      : Container(color: const Color(0xFF333333)),
                ),
              );
            }),
          ),

          // ── Dim outside selection ──────────────────────────────────────────
          Positioned(
              left: 0, top: 0,
              width: selLeft.clamp(0.0, width), height: height,
              child: Container(color: Colors.black.withValues(alpha: 0.6))),
          Positioned(
              left: selRight.clamp(0.0, width), top: 0,
              width: (width - selRight).clamp(0.0, width), height: height,
              child: Container(color: Colors.black.withValues(alpha: 0.6))),

          // ── Selection border ───────────────────────────────────────────────
          Positioned(
            left: selLeft, top: 0,
            width: (selRight - selLeft).clamp(0.0, width), height: height,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.primary, width: 2.5),
              ),
            ),
          ),

          // ── Left drag handle ───────────────────────────────────────────────
          Positioned(
            left: (selLeft - _handleW / 2).clamp(0.0, width - _handleW),
            top: 0, height: height, width: _handleW,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (d) {
                final newFrac =
                    (startFrac + d.delta.dx / width)
                        .clamp(0.0, endFrac - _minGap);
                onStartChanged(newFrac);
              },
              child: _Handle(isLeft: true, height: height),
            ),
          ),

          // ── Right drag handle ──────────────────────────────────────────────
          Positioned(
            left: (selRight - _handleW / 2).clamp(0.0, width - _handleW),
            top: 0, height: height, width: _handleW,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (d) {
                final newFrac =
                    (endFrac + d.delta.dx / width)
                        .clamp(startFrac + _minGap, 1.0);
                onEndChanged(newFrac);
              },
              child: _Handle(isLeft: false, height: height),
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Handle pill ───────────────────────────────────────────────────────────────

class _Handle extends StatelessWidget {
  final bool isLeft;
  final double height;
  const _Handle({required this.isLeft, required this.height});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 14, height: height,
        decoration: BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(3, (_) => Container(
              width: 2, height: 10,
              margin: const EdgeInsets.symmetric(vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white70,
                borderRadius: BorderRadius.circular(1),
              ),
            )),
          ),
        ),
      ),
    );
  }
}
