import 'package:cloud_firestore/cloud_firestore.dart';

class StatusModel {
  final String id;
  final String uid;
  final String type; // 'photo' | 'video' | 'text'
  /// Empty for a text status — there is nothing in Storage to point at.
  final String mediaUrl;
  /// Text statuses only: the typed body and the ARGB background it sits on.
  final String? textBody;
  final int? backgroundColor;
  final String? musicUrl;
  final String? musicName;
  final String? musicArtist;
  final int? musicStartMs; // ms into track where playback begins
  final String? caption;
  final DateTime createdAt;
  final DateTime expiresAt;
  final Map<String, DateTime> viewers; // viewerUid → viewedAt

  const StatusModel({
    required this.id,
    required this.uid,
    required this.type,
    required this.mediaUrl,
    this.textBody,
    this.backgroundColor,
    this.musicUrl,
    this.musicName,
    this.musicArtist,
    this.musicStartMs,
    this.caption,
    required this.createdAt,
    required this.expiresAt,
    required this.viewers,
  });

  bool get isVideo => type == 'video';
  bool get isText => type == 'text';
  bool get hasMusic => musicUrl != null;
  bool hasViewedBy(String viewerUid) => viewers.containsKey(viewerUid);
  int get viewCount => viewers.length;

  factory StatusModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final rawViewers = (data['viewers'] as Map<String, dynamic>?) ?? {};
    final viewers = rawViewers.map(
      (k, v) => MapEntry(k, (v as Timestamp).toDate()),
    );
    return StatusModel(
      id: doc.id,
      uid: data['uid'] as String,
      type: (data['type'] as String?) ?? 'photo',
      // Text statuses have no Storage object, so this can legitimately be absent.
      mediaUrl: (data['mediaUrl'] as String?) ?? '',
      textBody: data['textBody'] as String?,
      backgroundColor: data['backgroundColor'] as int?,
      musicUrl: data['musicUrl'] as String?,
      musicName: data['musicName'] as String?,
      musicArtist: data['musicArtist'] as String?,
      musicStartMs: data['musicStartMs'] as int?,
      caption: data['caption'] as String?,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      expiresAt: (data['expiresAt'] as Timestamp).toDate(),
      viewers: viewers,
    );
  }
}

class UserStatuses {
  final String uid;
  final String name;
  final String? photoUrl;
  final List<StatusModel> statuses; // chronological order

  const UserStatuses({
    required this.uid,
    required this.name,
    this.photoUrl,
    required this.statuses,
  });

  bool allViewedBy(String viewerUid) =>
      statuses.every((s) => s.hasViewedBy(viewerUid));
  DateTime get latestAt => statuses.last.createdAt;
}
