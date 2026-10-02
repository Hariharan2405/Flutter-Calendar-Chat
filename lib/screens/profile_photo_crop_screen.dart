import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../constants/app_theme.dart';

/// Full-screen circular photo crop editor.
///
/// The whole photo is visible from the start: it is fitted inside the crop
/// square, letterboxed if it isn't square, and the user zooms in only if they
/// want to. Previously the image was drawn with `BoxFit.cover` and the zoom
/// floor was 1.0, so a non-square photo arrived already cropped to a square
/// and there was no way to zoom out far enough to see the rest of it — you
/// could only reposition within a crop you never chose.
///
/// The result is rendered on a canvas using exactly the transform shown on
/// screen, rather than screen-grabbing a `RepaintBoundary`. That makes the
/// output independent of screen size and device pixel ratio, and avoids
/// encoding a multi-megabyte PNG scaled to the device's density.
///
/// Returns the cropped [File], or null if the user cancels.
class ProfilePhotoCropScreen extends StatefulWidget {
  final File imageFile;
  const ProfilePhotoCropScreen({super.key, required this.imageFile});

  static Future<File?> push(BuildContext context, File file) =>
      Navigator.push<File?>(
        context,
        MaterialPageRoute(
          builder: (_) => ProfilePhotoCropScreen(imageFile: file),
        ),
      );

  @override
  State<ProfilePhotoCropScreen> createState() => _ProfilePhotoCropScreenState();
}

class _ProfilePhotoCropScreenState extends State<ProfilePhotoCropScreen> {
  /// Side length of the saved image. The upload step compresses to 512px, so
  /// rendering much beyond that only costs encode time and memory.
  static const int _outputSize = 768;

  /// Letterbox fill, shown behind the photo and baked into the result so the
  /// saved avatar has no transparent corners. Matches the on-screen preview.
  static const Color _fill = Color(0xFF101014);

  ui.Image? _image;
  String? _loadError;

  double _scale = 1.0;
  Offset _offset = Offset.zero;
  double _startScale = 1.0;

  bool _saving = false;
  double _cropSize = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.imageFile.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _image = frame.image);
    } catch (_) {
      if (mounted) {
        setState(() => _loadError = "That image couldn't be opened.");
      }
    }
  }

  // ── Geometry ───────────────────────────────────────────────────────────────

  CropGeometry get _geometry => CropGeometry(
        cropSize: _cropSize,
        imageWidth: _image!.width.toDouble(),
        imageHeight: _image!.height.toDouble(),
      );

  void _onScaleStart(ScaleStartDetails d) => _startScale = _scale;

  void _onScaleUpdate(ScaleUpdateDetails d) {
    setState(() {
      _scale = (_startScale * d.scale).clamp(CropGeometry.minZoom, CropGeometry.maxZoom);
      _offset = _geometry.clampOffset(_offset + d.focalPointDelta, _scale);
    });
  }

  // ── Save ───────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (_saving || _image == null) return;
    setState(() => _saving = true);
    try {
      final file = await _render();
      if (!mounted) return;
      Navigator.pop(context, file);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't prepare the photo")),
      );
    }
  }

  Future<File> _render() async {
    final img = _image!;
    final ratio = _outputSize / _cropSize;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final out = _outputSize.toDouble();

    canvas.drawRect(
      Rect.fromLTWH(0, 0, out, out),
      Paint()..color = _fill,
    );
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      _geometry.destRect(scale: _scale, offset: _offset, canvasSize: out, ratio: ratio),
      Paint()..filterQuality = FilterQuality.high,
    );

    final picture = recorder.endRecording();
    final rendered = await picture.toImage(_outputSize, _outputSize);
    picture.dispose();
    try {
      final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('encode failed');
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/profile_crop_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(data.buffer.asUint8List());
      return file;
    } finally {
      rendered.dispose();
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    _cropSize = screenWidth * 0.88;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context, null),
        ),
        title: const Text(
          'Position Photo',
          style: TextStyle(
              color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2.5),
              ),
            )
          else
            TextButton(
              onPressed: _image == null ? null : _save,
              child: Text(
                'Done',
                style: TextStyle(
                    color: _image == null ? Colors.white38 : Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700),
              ),
            ),
        ],
      ),
      body: _loadError != null
          ? Center(
              child: Text(_loadError!,
                  style: const TextStyle(color: Colors.white70)),
            )
          : Column(
              children: [
                const Spacer(),
                Center(
                  child: SizedBox(
                    width: _cropSize,
                    height: _cropSize,
                    child: _image == null
                        ? const Center(
                            child: CircularProgressIndicator(
                                color: Colors.white54, strokeWidth: 2))
                        : GestureDetector(
                            onScaleStart: _onScaleStart,
                            onScaleUpdate: _onScaleUpdate,
                            child: CustomPaint(
                              size: Size(_cropSize, _cropSize),
                              painter: _CropPainter(
                                image: _image!,
                                dest: _geometry.destRect(
                                    scale: _scale,
                                    offset: _offset,
                                    canvasSize: _cropSize,
                                    ratio: 1.0),
                                fill: _fill,
                              ),
                              foregroundPainter: const _CircleOverlayPainter(),
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 28),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.pinch_rounded, color: Colors.white38, size: 18),
                    SizedBox(width: 6),
                    Text('Pinch to zoom',
                        style: TextStyle(color: Colors.white54, fontSize: 13)),
                    SizedBox(width: 20),
                    Icon(Icons.open_with_rounded,
                        color: Colors.white38, size: 18),
                    SizedBox(width: 6),
                    Text('Drag to reposition',
                        style: TextStyle(color: Colors.white54, fontSize: 13)),
                  ],
                ),
                const Spacer(),
              ],
            ),
    );
  }
}

/// Pure layout maths for the crop editor, kept out of the widget so the
/// preview and the saved file provably use the same transform.
@visibleForTesting
class CropGeometry {
  /// Zoom 1.0 is "whole photo visible". There is deliberately no way to zoom
  /// out past it, and the previous code's floor of 1.0 meant something else
  /// entirely because it sat on top of a cover-fit.
  static const double minZoom = 1.0;
  static const double maxZoom = 8.0;

  final double cropSize;
  final double imageWidth;
  final double imageHeight;

  const CropGeometry({
    required this.cropSize,
    required this.imageWidth,
    required this.imageHeight,
  });

  /// Scale that fits the whole image inside the crop square (contain).
  double get fitScale {
    final sx = cropSize / imageWidth;
    final sy = cropSize / imageHeight;
    return sx < sy ? sx : sy;
  }

  /// On-screen size of the photo at the given zoom.
  Size displayedSize(double scale) {
    final s = fitScale * scale;
    return Size(imageWidth * s, imageHeight * s);
  }

  /// Panning is bounded by how far the photo overflows the crop square, so it
  /// can never be dragged out of view. An axis that does not overflow — the
  /// letterboxed one at zoom 1.0 — is pinned to centre.
  Offset clampOffset(Offset raw, double scale) {
    final shown = displayedSize(scale);
    final maxX = ((shown.width - cropSize) / 2).clamp(0.0, double.infinity);
    final maxY = ((shown.height - cropSize) / 2).clamp(0.0, double.infinity);
    return Offset(raw.dx.clamp(-maxX, maxX), raw.dy.clamp(-maxY, maxY));
  }

  /// Where the photo sits inside a square canvas of [canvasSize], where
  /// [ratio] is that canvas's size relative to the on-screen crop square.
  Rect destRect({
    required double scale,
    required Offset offset,
    required double canvasSize,
    required double ratio,
  }) {
    final shown = displayedSize(scale);
    return Rect.fromCenter(
      center: Offset(canvasSize / 2, canvasSize / 2) + (offset * ratio),
      width: shown.width * ratio,
      height: shown.height * ratio,
    );
  }
}

/// Draws the photo exactly as [_ProfilePhotoCropScreenState._render] will, so
/// the preview and the saved file cannot drift apart.
class _CropPainter extends CustomPainter {
  final ui.Image image;
  final Rect dest;
  final Color fill;

  const _CropPainter({
    required this.image,
    required this.dest,
    required this.fill,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = fill,
    );
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dest,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) =>
      old.image != image || old.dest != dest || old.fill != fill;
}

// ── Circle overlay painter ─────────────────────────────────────────────────────
//
// Dims everything outside the circle and draws a crisp white border so the
// user can see exactly which region will be used as their profile photo.

class _CircleOverlayPainter extends CustomPainter {
  const _CircleOverlayPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 1.5;

    final outerRect = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final circleHole = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
    final scrim = Path.combine(PathOperation.difference, outerRect, circleHole);
    canvas.drawPath(scrim, Paint()..color = const Color(0xCC000000));

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..isAntiAlias = true,
    );

    canvas.drawCircle(
      center,
      radius - 3,
      Paint()
        ..color = AppColors.primary.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
