import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'system_services.dart';

/// Remembers which chat media messages have been saved to the device, and where
/// (the MediaStore content URI). Used to show a "downloaded" indicator instead
/// of the download button — and to bring the button back if the user later
/// deletes the saved file from the device.
class SavedMediaStore {
  static const _key = 'saved_media_uris';

  // In-memory mirror so lookups during build are synchronous after first load.
  static Map<String, String>? _cache;

  static Future<Map<String, String>> _load() async {
    if (_cache != null) return _cache!;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) {
      return _cache = {};
    }
    try {
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      return _cache = map.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return _cache = {};
    }
  }

  static Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(_cache ?? {}));
  }

  /// Records that [messageId]'s media was saved at [uri].
  static Future<void> mark(String messageId, String uri) async {
    final map = await _load();
    map[messageId] = uri;
    await _persist();
  }

  /// The saved URI for [messageId], or null if never saved.
  static Future<String?> uriFor(String messageId) async {
    final map = await _load();
    return map[messageId];
  }

  /// True if [messageId]'s media was saved AND still exists on the device.
  /// If the record exists but the file is gone, the record is cleared so the
  /// download option reappears.
  static Future<bool> existsFor(String messageId) async {
    final map = await _load();
    final uri = map[messageId];
    if (uri == null) return false;
    final exists = await SystemServices.mediaUriExists(uri);
    if (!exists) {
      map.remove(messageId);
      await _persist();
    }
    return exists;
  }
}
