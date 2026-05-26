import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path_provider/path_provider.dart';

// ── Drawing data ──────────────────────────────────────────────────────────────

class _Stroke {
  final List<Offset> points;
  final Color color;
  final double width;
  _Stroke({required this.points, required this.color, required this.width});
}

class _DrawingPainter extends CustomPainter {
  final List<_Stroke> strokes;
  final _Stroke? current;
  _DrawingPainter(this.strokes, this.current);

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in [...strokes, if (current != null) current!]) {
      if (stroke.points.isEmpty) continue;
      final paint = Paint()
        ..color = stroke.color
        ..strokeWidth = stroke.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path()..moveTo(stroke.points[0].dx, stroke.points[0].dy);
      for (var i = 1; i < stroke.points.length; i++) {
        path.lineTo(stroke.points[i].dx, stroke.points[i].dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_DrawingPainter old) => true;
}

// ── Screen ────────────────────────────────────────────────────────────────────

class ImageEditScreen extends StatefulWidget {
  final File imageFile;
  const ImageEditScreen({super.key, required this.imageFile});

  @override
  State<ImageEditScreen> createState() => _ImageEditScreenState();
}

class _ImageEditScreenState extends State<ImageEditScreen> {
  late File _imageFile;
  final List<_Stroke> _strokes = [];
  _Stroke? _currentStroke;
  Color _penColor = Colors.red;
  double _penWidth = 4.0;
  bool _drawingMode = false;
  bool _isSending = false;
  final _repaintKey = GlobalKey();

  static const _colors = [
    Colors.red,
    Colors.orange,
    Colors.yellow,
    Colors.green,
    Colors.blue,
    Colors.purple,
    Colors.white,
    Colors.black,
  ];

  @override
  void initState() {
    super.initState();
    _imageFile = widget.imageFile;
  }

  Future<void> _cropImage() async {
    final cropped = await ImageCropper().cropImage(
      sourcePath: _imageFile.path,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop Image',
          toolbarColor: const Color(0xFF5C35D1),
          toolbarWidgetColor: Colors.white,
          activeControlsWidgetColor: const Color(0xFF5C35D1),
          initAspectRatio: CropAspectRatioPreset.original,
          lockAspectRatio: false,
        ),
        IOSUiSettings(title: 'Crop Image'),
      ],
    );
    if (cropped != null && mounted) {
      setState(() {
        _imageFile = File(cropped.path);
        _strokes.clear();
        _drawingMode = false;
      });
    }
  }

  Future<File> _captureWithDrawings() async {
    final boundary =
        _repaintKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = byteData!.buffer.asUint8List();
    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/edited_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<void> _send() async {
    if (_isSending) return;
    setState(() => _isSending = true);
    try {
      final File result =
          _strokes.isEmpty ? _imageFile : await _captureWithDrawings();
      if (mounted) Navigator.pop(context, result);
    } catch (_) {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Edit Image',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        actions: [
          IconButton(
            icon: Icon(
              _drawingMode ? Icons.draw_rounded : Icons.draw_outlined,
              color: _drawingMode ? Colors.yellowAccent : Colors.white,
            ),
            tooltip: 'Draw',
            onPressed: () => setState(() => _drawingMode = !_drawingMode),
          ),
          IconButton(
            icon: const Icon(Icons.crop_rounded, color: Colors.white),
            tooltip: 'Crop',
            onPressed: _cropImage,
          ),
          if (_strokes.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.undo_rounded, color: Colors.white),
              onPressed: () => setState(() => _strokes.removeLast()),
            ),
          _isSending
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        color: Color(0xFF5C35D1), strokeWidth: 2),
                  ),
                )
              : IconButton(
                  icon:
                      const Icon(Icons.send_rounded, color: Color(0xFF5C35D1)),
                  tooltip: 'Send',
                  onPressed: _send,
                ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: RepaintBoundary(
                key: _repaintKey,
                child: Stack(
                  fit: StackFit.passthrough,
                  children: [
                    Image.file(_imageFile,
                        fit: BoxFit.contain, gaplessPlayback: true),
                    if (_drawingMode || _strokes.isNotEmpty)
                      Positioned.fill(
                        child: GestureDetector(
                          onPanStart: _drawingMode
                              ? (d) => setState(() => _currentStroke = _Stroke(
                                    points: [d.localPosition],
                                    color: _penColor,
                                    width: _penWidth,
                                  ))
                              : null,
                          onPanUpdate: _drawingMode
                              ? (d) => setState(
                                  () => _currentStroke?.points.add(d.localPosition))
                              : null,
                          onPanEnd: _drawingMode
                              ? (_) => setState(() {
                                    if (_currentStroke != null) {
                                      _strokes.add(_currentStroke!);
                                      _currentStroke = null;
                                    }
                                  })
                              : null,
                          child: CustomPaint(
                            painter: _DrawingPainter(_strokes, _currentStroke),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (_drawingMode) _buildDrawingToolbar(),
        ],
      ),
    );
  }

  Widget _buildDrawingToolbar() {
    return Container(
      color: const Color(0xFF1A1A1A),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: _colors
                .map((c) => GestureDetector(
                      onTap: () => setState(() => _penColor = c),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        margin: const EdgeInsets.symmetric(horizontal: 5),
                        width: _penColor == c ? 32 : 26,
                        height: _penColor == c ? 32 : 26,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _penColor == c
                                ? Colors.white
                                : Colors.transparent,
                            width: 2.5,
                          ),
                        ),
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.circle, color: Colors.white54, size: 8),
              Expanded(
                child: Slider(
                  value: _penWidth,
                  min: 2,
                  max: 20,
                  activeColor: _penColor,
                  inactiveColor: Colors.white24,
                  onChanged: (v) => setState(() => _penWidth = v),
                ),
              ),
              const Icon(Icons.circle, color: Colors.white54, size: 20),
            ],
          ),
        ],
      ),
    );
  }
}
