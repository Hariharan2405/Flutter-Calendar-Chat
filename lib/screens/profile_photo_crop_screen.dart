import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import '../constants/app_theme.dart';

/// Full-screen circular photo crop editor.
///
/// Shows the photo with a circle overlay. The user pinches to zoom and drags
/// to reposition so that the desired content is inside the circle.
/// Tapping "Done" captures the square behind the circle at 3× pixel density
/// and returns it as a [File]. Returns null if the user cancels.
///
/// Usage:
///   final File? cropped = await ProfilePhotoCropScreen.push(context, pickedFile);
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

class _ProfilePhotoCropScreenState extends State<ProfilePhotoCropScreen>
    with SingleTickerProviderStateMixin {
  double _scale = 1.0;
  Offset _offset = Offset.zero;

  // Stored at gesture start so delta can be applied cleanly each frame
  double _startScale = 1.0;

  bool _saving = false;
  final GlobalKey _repaintKey = GlobalKey();

  // Computed in build() and used in gesture handlers
  double _cropSize = 0;

  // ── Gesture handlers ───────────────────────────────────────────────────────

  void _onScaleStart(ScaleStartDetails d) {
    _startScale = _scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    setState(() {
      // Scale around the crop-area centre
      _scale = (_startScale * d.scale).clamp(1.0, 8.0);
      // Accumulate pan delta every frame, then clamp so image always covers
      // the full crop square (guarantees no empty region in the circle)
      _offset = _clampOffset(_offset + d.focalPointDelta);
    });
  }

  /// Maximum offset allowed in each direction so the image never exposes a
  /// gap inside the crop circle.
  Offset _clampOffset(Offset raw) {
    final maxOffset = _cropSize * (_scale - 1) / 2;
    return Offset(
      raw.dx.clamp(-maxOffset, maxOffset),
      raw.dy.clamp(-maxOffset, maxOffset),
    );
  }

  // ── Capture & return ───────────────────────────────────────────────────────

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final boundary = _repaintKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData!.buffer.asUint8List();
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/profile_crop_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes);
      if (mounted) Navigator.pop(context, file);
    } catch (_) {
      if (mounted) setState(() => _saving = false);
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
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        actions: [
          _saving
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2.5),
                  ),
                )
              : TextButton(
                  onPressed: _save,
                  child: const Text(
                    'Done',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700),
                  ),
                ),
        ],
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),

          // ── Crop area ────────────────────────────────────────────────────
          Center(
            child: SizedBox(
              width: _cropSize,
              height: _cropSize,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Image with gestures — only this is captured
                  RepaintBoundary(
                    key: _repaintKey,
                    child: ClipRect(
                      child: SizedBox(
                        width: _cropSize,
                        height: _cropSize,
                        child: GestureDetector(
                          onScaleStart: _onScaleStart,
                          onScaleUpdate: _onScaleUpdate,
                          child: Transform.translate(
                            offset: _offset,
                            child: Transform.scale(
                              scale: _scale,
                              child: Image.file(
                                widget.imageFile,
                                width: _cropSize,
                                height: _cropSize,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Dim overlay + circle border — NOT captured, pointer ignored
                  IgnorePointer(
                    child: CustomPaint(
                      size: Size(_cropSize, _cropSize),
                      painter: _CircleOverlayPainter(),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Hint ─────────────────────────────────────────────────────────
          const SizedBox(height: 28),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.pinch_rounded, color: Colors.white38, size: 18),
              SizedBox(width: 6),
              Text('Pinch to zoom',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
              SizedBox(width: 20),
              Icon(Icons.open_with_rounded, color: Colors.white38, size: 18),
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

    // Dark scrim outside the circle
    final outerRect = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final circleHole = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
    final scrim = Path.combine(PathOperation.difference, outerRect, circleHole);
    canvas.drawPath(
      scrim,
      Paint()..color = const Color(0xCC000000), // 80 % black
    );

    // Crisp white border
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..isAntiAlias = true,
    );

    // Subtle inner glow so the border stands out on light photos too
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
