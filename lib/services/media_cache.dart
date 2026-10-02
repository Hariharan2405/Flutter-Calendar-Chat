import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Shared cache for chat/status media (images, video, audio, voice).
///
/// One instance is reused by every `CachedNetworkImage`, by the prefetcher, and
/// by media playback so a file downloaded once (on view or on prefetch) is
/// served locally afterwards. The stale period is 24h so a received file is
/// kept locally for a day for instant play/load, then cleaned up.
final CacheManager mediaCacheManager = CacheManager(
  Config(
    'chatMediaCache',
    stalePeriod: const Duration(hours: 24),
    maxNrOfCacheObjects: 500,
  ),
);

/// Returns the locally cached file for [url], downloading it once if it isn't
/// cached yet. Returns null on failure so callers can fall back to streaming.
Future<File?> getCachedMediaFile(String? url) async {
  if (url == null || url.isEmpty) return null;
  try {
    return await mediaCacheManager.getSingleFile(url);
  } catch (_) {
    return null;
  }
}

/// Returns the cached file for [url] only if it is already present locally
/// (never triggers a download). Null when not cached.
Future<File?> peekCachedMediaFile(String? url) async {
  if (url == null || url.isEmpty) return null;
  try {
    final info = await mediaCacheManager.getFileFromCache(url);
    return info?.file;
  } catch (_) {
    return null;
  }
}

/// Removes the given media URLs from both the file cache and the in-memory image
/// cache. Call when a message/status is deleted so its local copy doesn't linger.
Future<void> evictMediaFromCache(Iterable<String?> urls) async {
  for (final url in urls) {
    if (url == null || url.isEmpty) continue;
    try {
      await mediaCacheManager.removeFile(url);
    } catch (_) {}
    try {
      await CachedNetworkImage.evictFromCache(url, cacheManager: mediaCacheManager);
    } catch (_) {}
  }
}
