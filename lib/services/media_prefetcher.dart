import 'media_cache.dart';

/// Background-downloads media into [mediaCacheManager] so that opening a chat or
/// a status shows instantly instead of waiting on a network fetch.
///
/// Fire-and-forget: callers don't await. Each URL is fetched at most once per
/// session (tracked in [_inFlight] / [_done]) and all errors are swallowed.
class MediaPrefetcher {
  static final Set<String> _inFlight = {};
  static final Set<String> _done = {};

  /// Downloads each non-empty URL into the shared cache if not already cached.
  static void prefetch(Iterable<String?> urls) {
    for (final url in urls) {
      if (url == null || url.isEmpty) continue;
      if (_inFlight.contains(url) || _done.contains(url)) continue;
      _inFlight.add(url);
      mediaCacheManager.getSingleFile(url).then((_) {
        _done.add(url);
      }).catchError((_) {
        // Leave out of _done so a later attempt can retry.
      }).whenComplete(() => _inFlight.remove(url));
    }
  }
}
