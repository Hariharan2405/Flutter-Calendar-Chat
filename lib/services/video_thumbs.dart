import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_compress/video_compress.dart';

import 'media_cache.dart';

/// Still frames for videos, and tiny previews for replies.
///
/// Videos used to render as a black box with a play icon until opened,
/// because nothing but the video itself was ever stored. New videos upload a
/// still frame alongside; older ones get one made on the phone from the copy
/// already in the media cache.
class VideoThumbs {
  VideoThumbs._();

  /// A still frame and the duration of a local [video], for uploading with it.
  /// Either may be null if the platform can't read the file; sending still
  /// works without them.
  static Future<({File? thumb, int? durationMs})> forUpload(File video) async {
    File? thumb;
    int? durationMs;
    await _serial(() async {
      try {
        final raw = await VideoCompress.getFileThumbnail(video.path,
            quality: 80, position: -1);
        // A bubble is ~260 logical px wide; 640 is sharp on dense screens.
        final small = await FlutterImageCompress.compressAndGetFile(
          raw.path,
          '${raw.path}_640.jpg',
          minWidth: 640,
          minHeight: 640,
          quality: 72,
        );
        thumb = small != null ? File(small.path) : raw;
      } catch (_) {}
      try {
        final info = await VideoCompress.getMediaInfo(video.path);
        durationMs = info.duration?.round();
      } catch (_) {}
    });
    return (thumb: thumb, durationMs: durationMs);
  }

  // ── Frames for videos that were sent without one ──────────────────────────

  static final Map<String, Uint8List?> _memory = {};
  static final Map<String, Future<Uint8List?>> _inFlight = {};
  static const int _memoryLimit = 60;

  /// A still frame for the video at [videoUrl], made from the cached copy.
  /// Cached in memory and on disk, so each video is only decoded once.
  static Future<Uint8List?> localFrame(String videoUrl) {
    if (_memory.containsKey(videoUrl)) return Future.value(_memory[videoUrl]);
    return _inFlight[videoUrl] ??= _makeLocalFrame(videoUrl)
        .whenComplete(() => _inFlight.remove(videoUrl));
  }

  /// The frame if it has already been made, without starting any work.
  static Uint8List? peekLocalFrame(String videoUrl) => _memory[videoUrl];

  static Future<Uint8List?> _makeLocalFrame(String url) async {
    try {
      return await _makeLocalFrameUnsafe(url);
    } catch (_) {
      // An unreadable video just keeps the placeholder backdrop.
      return null;
    }
  }

  static Future<Uint8List?> _makeLocalFrameUnsafe(String url) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/video_frames');
    final file = File('${dir.path}/${sha1.convert(utf8.encode(url))}.jpg');
    Uint8List? bytes;
    if (await file.exists()) {
      bytes = await file.readAsBytes();
    } else {
      final video = await getCachedMediaFile(url);
      if (video == null) return null;
      bytes = await _serial(() => VideoCompress.getByteThumbnail(video.path,
          quality: 70, position: -1));
      if (bytes == null || bytes.isEmpty) return null;
      await dir.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
    }
    if (_memory.length >= _memoryLimit) _memory.remove(_memory.keys.first);
    _memory[url] = bytes;
    return bytes;
  }

  // ── Tiny inline previews for replies ──────────────────────────────────────

  /// A ~120 px JPEG of an image or video, base64-encoded for storing inside
  /// the reply message itself. Null if the media can't be read.
  static Future<String?> tinyPreview({
    required String url,
    required bool isVideo,
  }) async {
    try {
      Uint8List? source;
      if (isVideo) {
        source = await localFrame(url);
      } else {
        final file = await getCachedMediaFile(url);
        if (file != null) source = await file.readAsBytes();
      }
      if (source == null) return null;
      final small = await FlutterImageCompress.compressWithList(
        source,
        minWidth: 120,
        minHeight: 120,
        quality: 55,
      );
      return base64Encode(small);
    } catch (_) {
      return null;
    }
  }

  // ── Serialising the video plugin ──────────────────────────────────────────

  static Future<void> _chain = Future.value();

  /// video_compress keeps one native session; overlapping calls (several
  /// bubbles decoding at once while scrolling) can fail or return the wrong
  /// frame, so they run one at a time.
  static Future<T> _serial<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _chain = _chain.then((_) async {
      try {
        completer.complete(await task());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }
}
