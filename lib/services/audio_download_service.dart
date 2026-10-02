import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'system_services.dart';

/// Downloads chat audio files and saves them to the public Music folder.
class AudioDownloadService {
  /// Downloads [url] and saves it to the public Music/Calendar folder under
  /// [fileName]. Returns the saved destination string on success, or null.
  static Future<String?> downloadToMusic(String url, String fileName) async {
    try {
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode != 200) return null;

      // Stage the bytes in a temp file, then hand the path to the native side
      // which copies it into MediaStore (public Music folder).
      final tmpDir = await getTemporaryDirectory();
      final safeName = _sanitize(fileName);
      final tmp = File('${tmpDir.path}/dl_$safeName');
      await tmp.writeAsBytes(resp.bodyBytes);

      final saved = await SystemServices.saveAudioToMusic(
        path: tmp.path,
        name: safeName,
        mime: _mimeFor(safeName),
      );

      try {
        await tmp.delete();
      } catch (_) {}
      return saved;
    } catch (_) {
      return null;
    }
  }

  static String _sanitize(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? 'audio.mp3' : cleaned;
  }

  static String _mimeFor(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    switch (ext) {
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
      case 'mp4':
        return 'audio/mp4';
      case 'aac':
        return 'audio/aac';
      case 'wav':
        return 'audio/wav';
      case 'ogg':
      case 'oga':
        return 'audio/ogg';
      case 'opus':
        return 'audio/opus';
      case 'flac':
        return 'audio/flac';
      default:
        return 'audio/mpeg';
    }
  }
}
