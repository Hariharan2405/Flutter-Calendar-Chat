import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:video_compress/video_compress.dart';
import '../models/status_model.dart';
import '../models/user_profile_model.dart';
import '../utils/media_compressor.dart';
import '../utils/shared_stream.dart';

class MusicTrack {
  final String name;
  final String artist;
  final String previewUrl;
  final String artworkUrl;

  const MusicTrack({
    required this.name,
    required this.artist,
    required this.previewUrl,
    required this.artworkUrl,
  });
}

class StatusService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final _uuid = const Uuid();

  // ── Queries ──────────────────────────────────────────────────────────────────

  // One shared listener for every screen that shows statuses. The chat list
  // and the status screen are both mounted at once when you push from one to
  // the other, so a per-screen `.snapshots()` meant two listeners over the
  // same query — and, because these are called from `build()`, a fresh
  // listener on every rebuild.
  static final SharedStream<List<StatusModel>> _shared =
      SharedStream<List<StatusModel>>(_rawActiveStatuses);

  Stream<List<StatusModel>> allActiveStatuses() => _shared.stream();

  static Stream<List<StatusModel>> _rawActiveStatuses() {
    return FirebaseFirestore.instance
        .collection('statuses')
        // Bounds what we read. Note this timestamp is fixed when the query is
        // built, so it is a floor, not a live filter — hence the second check
        // below, which re-evaluates on every emission.
        .where('expiresAt', isGreaterThan: Timestamp.now())
        .orderBy('expiresAt')
        .snapshots()
        .map((snap) {
          final now = DateTime.now();
          final items = snap.docs
              .map(StatusModel.fromFirestore)
              // Without this, a status that expires while the app is open
              // stays on screen until the stream is rebuilt, because the
              // query's cutoff was frozen at subscription time.
              .where((s) => s.expiresAt.isAfter(now))
              .toList();
          items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          return items;
        });
  }

  /// Groups a flat list of statuses + user profiles into per-user groups,
  /// sorted: unviewed first (most recent), then viewed (most recent).
  static List<UserStatuses> groupByUser({
    required List<StatusModel> statuses,
    required List<UserProfileModel> users,
    required String currentUid,
  }) {
    final map = <String, List<StatusModel>>{};
    for (final s in statuses) {
      map.putIfAbsent(s.uid, () => []).add(s);
    }
    // Sort each user's statuses chronologically
    for (final list in map.values) {
      list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }

    final profileMap = {for (final u in users) u.uid: u};
    final groups = map.entries
        .map((e) {
          final profile = profileMap[e.key];
          return UserStatuses(
            uid: e.key,
            name: profile?.name ?? e.key,
            photoUrl: profile?.photoUrl,
            statuses: e.value,
          );
        })
        .toList();

    // Sort: unviewed first (by latest status time desc), then viewed
    groups.sort((a, b) {
      final aViewed = a.allViewedBy(currentUid);
      final bViewed = b.allViewedBy(currentUid);
      if (aViewed != bViewed) return aViewed ? 1 : -1;
      return b.latestAt.compareTo(a.latestAt);
    });
    return groups;
  }

  // ── Upload ────────────────────────────────────────────────────────────────────

  Future<void> uploadPhotoStatus({
    required String uid,
    required File imageFile,
    String? caption,
    String? musicUrl,
    String? musicName,
    String? musicArtist,
    int? musicStartMs,
  }) async {
    final id = _uuid.v4();
    final compressed = await MediaCompressor.compressImage(imageFile);
    final ref = _storage.ref('statuses/$uid/$id.jpg');
    await ref.putFile(compressed, SettableMetadata(contentType: 'image/jpeg'));
    final mediaUrl = await ref.getDownloadURL();
    final now = DateTime.now();
    await _db.collection('statuses').doc(id).set({
      'uid': uid,
      'type': 'photo',
      'mediaUrl': mediaUrl,
      if (caption?.isNotEmpty == true) 'caption': caption,
      if (musicUrl != null) 'musicUrl': musicUrl,
      if (musicName != null) 'musicName': musicName,
      if (musicArtist != null) 'musicArtist': musicArtist,
      if (musicStartMs != null && musicStartMs > 0) 'musicStartMs': musicStartMs,
      'createdAt': Timestamp.fromDate(now),
      'expiresAt': Timestamp.fromDate(now.add(const Duration(hours: 24))),
      'viewers': {},
    });
  }

  /// A text status uploads nothing — no compression, no Storage object, no
  /// cleanup later. It is a single small document.
  Future<void> uploadTextStatus({
    required String uid,
    required String text,
    required int backgroundColor,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now();
    await _db.collection('statuses').doc(id).set({
      'uid': uid,
      'type': 'text',
      'mediaUrl': '',
      'textBody': text,
      'backgroundColor': backgroundColor,
      'createdAt': Timestamp.fromDate(now),
      'expiresAt': Timestamp.fromDate(now.add(const Duration(hours: 24))),
      'viewers': {},
    });
  }

  Future<void> uploadVideoStatus({
    required String uid,
    required File videoFile,
    String? caption,
  }) async {
    final id = _uuid.v4();
    // Compress to cut upload time and Firebase data (mirrors chat video sends).
    File toUpload = videoFile;
    try {
      final info = await VideoCompress.compressVideo(
        videoFile.path,
        quality: VideoQuality.MediumQuality,
        deleteOrigin: false,
        includeAudio: true,
      );
      if (info?.path != null) toUpload = File(info!.path!);
    } catch (_) {}
    final ext = toUpload.path.split('.').last.toLowerCase();
    final ref = _storage.ref('statuses/$uid/$id.$ext');
    await ref.putFile(toUpload);
    final mediaUrl = await ref.getDownloadURL();
    final now = DateTime.now();
    await _db.collection('statuses').doc(id).set({
      'uid': uid,
      'type': 'video',
      'mediaUrl': mediaUrl,
      if (caption?.isNotEmpty == true) 'caption': caption,
      'createdAt': Timestamp.fromDate(now),
      'expiresAt': Timestamp.fromDate(now.add(const Duration(hours: 24))),
      'viewers': {},
    });
  }

  // Upload a local audio file and return the download URL
  Future<String> uploadLocalMusic(String uid, File audioFile) async {
    final id = _uuid.v4();
    final ext = audioFile.path.split('.').last.toLowerCase();
    final ref = _storage.ref('status_music/$uid/$id.$ext');
    await ref.putFile(audioFile);
    return await ref.getDownloadURL();
  }

  // ── Viewer tracking ───────────────────────────────────────────────────────────

  Future<void> markViewed(String statusId, String viewerUid) async {
    try {
      await _db.collection('statuses').doc(statusId).update({
        'viewers.$viewerUid': Timestamp.now(),
      });
    } catch (_) {}
  }

  // ── Delete ────────────────────────────────────────────────────────────────────

  Future<void> deleteStatus(String statusId, {String? mediaUrl}) async {
    try {
      await _db.collection('statuses').doc(statusId).delete();
    } catch (_) {}
    // Remove the backing media from Storage so it isn't orphaned.
    if (mediaUrl != null && mediaUrl.isNotEmpty) {
      try {
        await _storage.refFromURL(mediaUrl).delete();
      } catch (_) {}
    }
  }

  // ── iTunes music search (free 30-second previews) ─────────────────────────────

  Future<List<MusicTrack>> searchMusic(String query) async {
    try {
      final uri = Uri.parse(
          'https://itunes.apple.com/search?term=${Uri.encodeComponent(query)}'
          '&media=music&entity=song&limit=20');
      final resp = await http.get(uri).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return (data['results'] as List)
          .where((r) => r['previewUrl'] != null)
          .map((r) => MusicTrack(
                name: r['trackName'] as String? ?? 'Unknown',
                artist: r['artistName'] as String? ?? '',
                previewUrl: r['previewUrl'] as String,
                artworkUrl: (r['artworkUrl100'] as String? ?? '')
                    .replaceAll('100x100', '60x60'),
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
