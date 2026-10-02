import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Chat display preferences shared by both chat screens.
class ChatPrefs extends ChangeNotifier {
  ChatPrefs._();
  static final ChatPrefs instance = ChatPrefs._();

  static const _textScaleKey = 'chat_text_scale';
  static const _enterSendsKey = 'chat_enter_sends';

  /// Choices offered in Settings, as (label, multiplier).
  static const List<(String, double)> textSizes = [
    ('Small', 0.9),
    ('Default', 1.0),
    ('Large', 1.12),
    ('Extra large', 1.25),
  ];

  double _textScale = 1.0;
  bool _enterSends = false;

  /// Multiplier for message text.
  double get textScale => _textScale;

  /// Whether the keyboard's Enter key sends instead of starting a new line.
  bool get enterSends => _enterSends;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _textScale = prefs.getDouble(_textScaleKey) ?? 1.0;
      _enterSends = prefs.getBool(_enterSendsKey) ?? false;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setTextScale(double v) async {
    _textScale = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_textScaleKey, v);
  }

  Future<void> setEnterSends(bool v) async {
    _enterSends = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enterSendsKey, v);
  }
}
