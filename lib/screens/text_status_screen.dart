import 'package:flutter/material.dart';

import '../services/status_service.dart';
import '../utils/snack_util.dart';

/// Compose a text-only status: type on a coloured card, tap the palette to
/// cycle backgrounds, post.
///
/// Unlike photo and video statuses this uploads nothing to Storage — it writes
/// a single document — so posting is instant and there is no media to clean up
/// when it expires.
class TextStatusScreen extends StatefulWidget {
  final String uid;

  const TextStatusScreen({super.key, required this.uid});

  @override
  State<TextStatusScreen> createState() => _TextStatusScreenState();
}

class _TextStatusScreenState extends State<TextStatusScreen> {
  final _ctrl = TextEditingController();
  final _service = StatusService();
  int _colorIndex = 0;
  bool _posting = false;

  /// Deep, saturated grounds — white text has to stay legible on every one, so
  /// nothing pale belongs here.
  static const _backgrounds = <Color>[
    Color(0xFF5C35D1),
    Color(0xFF00897B),
    Color(0xFFC62828),
    Color(0xFF1565C0),
    Color(0xFFEF6C00),
    Color(0xFF37474F),
    Color(0xFF6A1B9A),
    Color(0xFF2E7D32),
  ];

  Color get _bg => _backgrounds[_colorIndex];

  /// Long text needs to shrink to stay on one screen; short text should feel
  /// like a statement.
  double get _fontSize {
    final len = _ctrl.text.characters.length;
    if (len <= 30) return 34;
    if (len <= 80) return 27;
    if (len <= 160) return 22;
    return 18;
  }

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _post() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _posting) return;
    setState(() => _posting = true);
    try {
      await _service.uploadTextStatus(
        uid: widget.uid,
        text: text,
        // ignore: deprecated_member_use
        backgroundColor: _bg.value,
      );
      if (mounted) {
        Navigator.pop(context);
        context.showSuccess('Status posted');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _posting = false);
        context.showError('Could not post status');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPost = _ctrl.text.trim().isNotEmpty && !_posting;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.palette_rounded, color: Colors.white),
            tooltip: 'Change background',
            onPressed: () => setState(
                () => _colorIndex = (_colorIndex + 1) % _backgrounds.length),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: TextField(
                    controller: _ctrl,
                    autofocus: true,
                    maxLines: null,
                    maxLength: 400,
                    textAlign: TextAlign.center,
                    cursorColor: Colors.white,
                    textCapitalization: TextCapitalization.sentences,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: _fontSize,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      counterText: '',
                      hintText: 'Type a status',
                      hintStyle: TextStyle(
                        color: Colors.white54,
                        fontSize: 26,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_ctrl.text.characters.length}/400',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                  FloatingActionButton(
                    backgroundColor: Colors.white,
                    foregroundColor: _bg,
                    onPressed: canPost ? _post : null,
                    child: _posting
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
