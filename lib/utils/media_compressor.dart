import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';

/// Compresses images before upload so chat/group/status/profile media is a few
/// hundred KB instead of multiple MB. This cuts upload time (send lag), Firebase
/// data usage, and download/load time.
class MediaCompressor {
  /// Resizes [src] so its longest side is at most [maxSide] and re-encodes it as
  /// JPEG at [quality]. Returns a new temp file, or the original file if
  /// compression fails or doesn't help (so callers can always upload something).
  static Future<File> compressImage(
    File src, {
    int maxSide = 1600,
    int quality = 75,
  }) async {
    try {
      final dir = await getTemporaryDirectory();
      final target =
          '${dir.path}/cmp_${DateTime.now().microsecondsSinceEpoch}.jpg';
      final result = await FlutterImageCompress.compressAndGetFile(
        src.absolute.path,
        target,
        quality: quality,
        minWidth: maxSide,
        minHeight: maxSide,
        keepExif: false,
      );
      if (result == null) return src;
      final out = File(result.path);
      // If compression somehow produced a bigger file, keep the original.
      if (await out.length() >= await src.length()) return src;
      return out;
    } catch (e) {
      debugPrint('Image compression failed, uploading original: $e');
      return src;
    }
  }
}
