import 'dart:io';

enum StatusUploadState { uploading, failed }

/// An in-flight status upload tracked by AppProvider so it can continue in the
/// background after the create screen is dismissed, and surface a
/// sending / failed-retry indicator on the status screen.
class PendingStatusUpload {
  final String id;
  final String uid;
  final File mediaFile;
  final String mediaType; // 'photo' | 'video'
  final String? caption;
  final String? musicUrl;
  final String? musicName;
  final String? musicArtist;
  final int? musicStartMs;
  final DateTime createdAt;
  StatusUploadState state;

  PendingStatusUpload({
    required this.id,
    required this.uid,
    required this.mediaFile,
    required this.mediaType,
    this.caption,
    this.musicUrl,
    this.musicName,
    this.musicArtist,
    this.musicStartMs,
    required this.createdAt,
    this.state = StatusUploadState.uploading,
  });

  bool get isVideo => mediaType == 'video';
}
