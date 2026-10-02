import 'media_cache.dart';
import 'saved_media_store.dart';
import 'system_services.dart';

enum SavedMediaKind { image, video, audio }

/// Saves received chat media to the device by **reusing the local cache**
/// (no re-download when the file is already cached) and records the saved
/// location so the UI can show a "downloaded" state.
class MediaSaveService {
  /// Saves [url]'s media to the public gallery/music folder, reusing the cached
  /// copy when available. Returns the saved destination string, or null on
  /// failure.
  static Future<String?> saveReusingCache({
    required String url,
    required String messageId,
    required SavedMediaKind kind,
    String? fileName,
  }) async {
    // Reuse the already-cached file; downloads once only if not cached yet.
    final file = await getCachedMediaFile(url);
    if (file == null) return null;

    final name = _fileName(fileName, url, kind);
    final uri = await SystemServices.saveMediaToStore(
      path: file.path,
      name: name,
      mime: _mimeFor(kind, name),
      kind: kind.name,
    );
    if (uri == null) return null;

    await SavedMediaStore.mark(messageId, uri);
    return uri;
  }

  static String _fileName(String? provided, String url, SavedMediaKind kind) {
    if (provided != null && provided.trim().isNotEmpty) {
      return _sanitize(provided);
    }
    // Derive an extension from the URL, else fall back per kind.
    final path = Uri.tryParse(url)?.path ?? '';
    final urlExt =
        path.contains('.') ? path.split('.').last.toLowerCase() : '';
    final ext = urlExt.isNotEmpty && urlExt.length <= 4
        ? urlExt
        : _defaultExt(kind);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final prefix = switch (kind) {
      SavedMediaKind.image => 'IMG',
      SavedMediaKind.video => 'VID',
      SavedMediaKind.audio => 'AUD',
    };
    return '${prefix}_$stamp.$ext';
  }

  static String _defaultExt(SavedMediaKind kind) => switch (kind) {
        SavedMediaKind.image => 'jpg',
        SavedMediaKind.video => 'mp4',
        SavedMediaKind.audio => 'mp3',
      };

  static String _sanitize(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? 'file' : cleaned;
  }

  static String _mimeFor(SavedMediaKind kind, String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    switch (kind) {
      case SavedMediaKind.image:
        if (ext == 'png') return 'image/png';
        if (ext == 'webp') return 'image/webp';
        if (ext == 'gif') return 'image/gif';
        return 'image/jpeg';
      case SavedMediaKind.video:
        if (ext == 'mov') return 'video/quicktime';
        if (ext == 'webm') return 'video/webm';
        if (ext == 'mkv') return 'video/x-matroska';
        return 'video/mp4';
      case SavedMediaKind.audio:
        switch (ext) {
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
}
