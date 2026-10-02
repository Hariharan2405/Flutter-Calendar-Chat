import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:uuid/uuid.dart';
import '../models/user_profile_model.dart';
import '../models/message_model.dart';
import '../utils/media_compressor.dart';
import '../utils/shared_stream.dart';
import 'video_thumbs.dart';

/// How long after a heartbeat a user still counts as online. Shared so the
/// presence dot and the stream's change-detection agree.
const Duration kOnlineWindow = Duration(seconds: 60);

class ChatService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final _uuid = const Uuid();

  // ── User Profiles ─────────────────────────────────────────────────────────

  Future<UserProfileModel?> getUserProfile(String uid) async {
    final doc = await _db.collection('user_profiles').doc(uid).get();
    if (!doc.exists) return null;
    return UserProfileModel.fromFirestore(doc);
  }

  /// Returns the existing profile if a doc with this name exists, otherwise null.
  Future<UserProfileModel?> findProfileByName(String name) async {
    final snap = await _db
        .collection('user_profiles')
        .where('name', isEqualTo: name)
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return null;
    return UserProfileModel.fromFirestore(snap.docs.first);
  }

  Future<void> saveUserProfile(String uid, String name, String password) async {
    final now = DateTime.now();
    final token = await FirebaseMessaging.instance.getToken();
    await _db.collection('user_profiles').doc(uid).set({
      'name': name,
      'password': password,
      'createdAt': Timestamp.fromDate(now),
      'lastSeen': Timestamp.fromDate(now),
      if (token != null) 'fcmToken': token,
    });
  }

  /// The FCM token, fetched once per process. `getToken()` is a platform-channel
  /// round trip that can hit the network, and this runs on a 30-second
  /// heartbeat — re-fetching a value that essentially never changes was pure
  /// overhead, so it is cached and only written when it actually differs.
  static String? _cachedToken;
  static String? _writtenToken;

  /// Refreshes lastSeen (and the FCM token, if it changed).
  Future<void> updateOnReturn(String uid) async {
    try {
      _cachedToken ??= await FirebaseMessaging.instance.getToken();
    } catch (_) {}
    final token = _cachedToken;
    final tokenChanged = token != null && token != _writtenToken;
    await _db.collection('user_profiles').doc(uid).update({
      'lastSeen': Timestamp.fromDate(DateTime.now()),
      if (tokenChanged) 'fcmToken': token,
    });
    if (tokenChanged) _writtenToken = token;
  }

  Future<void> setDescription(String uid, String description) async {
    await _db.collection('user_profiles').doc(uid).set(
      {'description': description},
      SetOptions(merge: true),
    );
  }

  Future<String> uploadProfilePhoto(String uid, File file) async {
    // Profile photos display small — compress hard (max 512px).
    final compressed =
        await MediaCompressor.compressImage(file, maxSide: 512, quality: 80);

    // A fresh object name per upload. Writing to a fixed 'photo.jpg' returned
    // the same download URL every time, so every cache in the app — and every
    // other user's device — kept serving the previous image and the new photo
    // appeared never to apply.
    final name = '${DateTime.now().millisecondsSinceEpoch}.jpg';
    final ref = _storage.ref('profile_photos/$uid/$name');
    await ref.putFile(compressed, SettableMetadata(contentType: 'image/jpeg'));
    final url = await ref.getDownloadURL();

    // Drop the previous photos so the new name doesn't just accumulate files.
    unawaited(_pruneOldProfilePhotos(uid, keep: name));
    return url;
  }

  Future<void> _pruneOldProfilePhotos(String uid, {required String keep}) async {
    try {
      final listing = await _storage.ref('profile_photos/$uid').listAll();
      await Future.wait(listing.items
          .where((item) => item.name != keep)
          .map((item) => item.delete().catchError((_) {})));
    } catch (_) {}
  }

  Future<void> updatePhotoUrl(String uid, String url) async {
    // set(merge) rather than update(): update() rejects if the field path is
    // absent on an older profile document.
    await _db
        .collection('user_profiles')
        .doc(uid)
        .set({'photoUrl': url}, SetOptions(merge: true));
  }

  // ── Profile list ──────────────────────────────────────────────────────────
  //
  // Every screen that lists people reads from one shared, deduped stream.
  //
  // Two things made this expensive. The stream was rebuilt on each call, and
  // the calls happen inside `build()`, so an unrelated rebuild recreated a
  // listener over the whole collection. And every client writes `lastSeen` on
  // a 30-second heartbeat, so with N people online the raw snapshot stream
  // fired ~N times per 30s and rebuilt the entire list each time — constant
  // work while the app sits idle.
  //
  // The dedupe below drops any emission that would not change what is on
  // screen: a heartbeat from someone already shown as online is ignored.

  static final SharedStream<List<UserProfileModel>> _profiles =
      SharedStream<List<UserProfileModel>>(_buildProfileSource);

  /// Re-checks presence independently of Firestore. Needed because a user
  /// going offline produces *no* snapshot — their heartbeat simply stops — so
  /// the online→offline flip has to be noticed locally.
  static const _presenceRecheck = Duration(seconds: 20);

  static Stream<List<UserProfileModel>> _buildProfileSource() {
    final out = StreamController<List<UserProfileModel>>();
    List<UserProfileModel>? latest;
    String? lastSignature;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? sub;
    Timer? ticker;

    // Everything the list actually renders. `lastSeen` enters only as the
    // online/offline bit, so heartbeats that don't flip it are invisible here.
    String signatureOf(List<UserProfileModel> users) {
      final now = DateTime.now();
      final b = StringBuffer();
      for (final u in users) {
        final online = now.difference(u.lastSeen) < kOnlineWindow;
        b
          ..write(u.uid)
          ..write('')
          ..write(u.name)
          ..write('')
          ..write(u.photoUrl ?? '')
          ..write('')
          ..write(u.description ?? '')
          ..write('')
          ..write(online ? '1' : '0')
          ..write('');
      }
      return b.toString();
    }

    void emitIfChanged() {
      final users = latest;
      if (users == null || out.isClosed) return;
      final sig = signatureOf(users);
      if (sig == lastSignature) return;
      lastSignature = sig;
      out.add(users);
    }

    out.onListen = () {
      sub = FirebaseFirestore.instance
          .collection('user_profiles')
          .orderBy('name')
          .snapshots()
          .listen((snap) {
        latest = snap.docs
            .where((d) => d.data()['name'] != null)
            .map(UserProfileModel.fromFirestore)
            .toList();
        emitIfChanged();
      }, onError: out.addError);
      ticker = Timer.periodic(_presenceRecheck, (_) => emitIfChanged());
    };
    out.onCancel = () async {
      ticker?.cancel();
      await sub?.cancel();
    };
    return out.stream;
  }

  /// Every profile with a name, including the current user.
  Stream<List<UserProfileModel>> getAllUsersStream() => _profiles.stream();

  /// Cached per uid so this is safe to call from `build()` — see [SharedStream].
  static final _profilesExcept =
      KeyedSharedStreams<String, List<UserProfileModel>>(
    (uid) => _profiles
        .stream()
        .map((users) => users.where((u) => u.uid != uid).toList()),
  );

  Stream<List<UserProfileModel>> getAllUsersExcept(String currentUid) =>
      _profilesExcept.stream(currentUid);

  // ── Chat Rooms ────────────────────────────────────────────────────────────

  static String chatId(String uid1, String uid2) {
    final sorted = [uid1, uid2]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }

  Future<void> ensureChatExists(String uid1, String uid2) async {
    final id = chatId(uid1, uid2);
    final doc = await _db.collection('chats').doc(id).get();
    if (!doc.exists) {
      await _db.collection('chats').doc(id).set({
        'participants': [uid1, uid2],
        'createdAt': Timestamp.fromDate(DateTime.now()),
        'lastMessage': '',
        'lastSenderId': '',
        'lastMessageTime': Timestamp.fromDate(DateTime.now()),
        'unread_$uid1': 0,
        'unread_$uid2': 0,
      });
    }
  }

  Stream<List<MessageModel>> messages(String uid1, String uid2) {
    final id = chatId(uid1, uid2);
    final cutoff = DateTime.now().subtract(const Duration(days: 2));
    return _db
        .collection('chats')
        .doc(id)
        .collection('messages')
        .where('timestamp', isGreaterThan: Timestamp.fromDate(cutoff))
        .orderBy('timestamp')
        .limitToLast(20)
        .snapshots()
        .map((snap) => snap.docs.map(MessageModel.fromFirestore).toList());
  }

  /// Fetches up to 20 messages older than [before], used for pagination.
  Future<List<MessageModel>> loadOlderMessages(
      String uid1, String uid2, DateTime before) async {
    final id = chatId(uid1, uid2);
    final cutoff = DateTime.now().subtract(const Duration(days: 2));
    final snap = await _db
        .collection('chats')
        .doc(id)
        .collection('messages')
        .where('timestamp', isGreaterThan: Timestamp.fromDate(cutoff))
        .where('timestamp', isLessThan: Timestamp.fromDate(before))
        .orderBy('timestamp')
        .limitToLast(20)
        .get();
    return snap.docs.map(MessageModel.fromFirestore).toList();
  }

  Stream<Map<String, dynamic>?> chatData(String uid1, String uid2) {
    final id = chatId(uid1, uid2);
    return _db
        .collection('chats')
        .doc(id)
        .snapshots()
        .map((doc) => doc.exists ? doc.data() : null);
  }

  /// All chats involving this user — used for notifications
  /// Cached per uid: this is called from `build()`, and returning a fresh
  /// stream each time made an unrelated rebuild resubscribe the query.
  static final _chatsFor = KeyedSharedStreams<String, QuerySnapshot>(
    (uid) => FirebaseFirestore.instance
        .collection('chats')
        .where('participants', arrayContains: uid)
        .snapshots(),
  );

  Stream<QuerySnapshot> allChatsFor(String uid) => _chatsFor.stream(uid);

  Future<void> resetUnread(String uid1, String uid2) async {
    final id = chatId(uid1, uid2);
    try {
      await _db.collection('chats').doc(id).update({'unread_$uid1': 0});
    } catch (_) {}
  }

  Future<void> markRead(String uid1, String uid2, String currentUid) {
    return _updateChatMeta(chatId(uid1, uid2), {
      'unread_$currentUid': 0,
      'lastReadAt_$currentUid': Timestamp.now(),
    });
  }

  Future<void> markDelivered(String chatDocId, String currentUid) {
    return _updateChatMeta(chatDocId, {
      'lastDeliveredAt_$currentUid': Timestamp.now(),
    });
  }

  Stream<UserProfileModel?> watchUserProfile(String uid) {
    return _db
        .collection('user_profiles')
        .doc(uid)
        .snapshots()
        .map((doc) => doc.exists ? UserProfileModel.fromFirestore(doc) : null);
  }

  Future<void> _updateChatMeta(
      String chatDocId, Map<String, dynamic> data) async {
    try {
      await _db.collection('chats').doc(chatDocId).update(data);
    } catch (_) {}
  }

  /// Writes a message and its parent chat's preview/unread counter as one
  /// atomic batch. Doing them separately meant either could land without the
  /// other — a message with a stale chat-list preview, or a bumped unread count
  /// for a message that never arrived.
  Future<void> _commitMessage({
    required String chatDocId,
    required MessageModel msg,
    required String receiverUid,
    required String preview,
  }) async {
    final batch = _db.batch();
    final chatRef = _db.collection('chats').doc(chatDocId);

    batch.set(chatRef.collection('messages').doc(msg.id), msg.toFirestore());
    batch.update(chatRef, {
      'lastMessage': preview,
      'lastSenderId': msg.senderId,
      'lastMessageTime': Timestamp.fromDate(msg.timestamp),
      'unread_$receiverUid': FieldValue.increment(1),
    });

    await batch.commit();
  }

  // ── Send Messages ─────────────────────────────────────────────────────────

  Future<void> sendTextMessage({
    required String senderUid,
    required String receiverUid,
    required String text,
    String? replyToId,
    String? replyToText,
    String? replyToImageUrl,
    String? replyToSenderId,
    String? replyToThumb,
  }) async {
    await ensureChatExists(senderUid, receiverUid);
    final id = chatId(senderUid, receiverUid);
    final msgId = _uuid.v4();
    final now = DateTime.now();

    final msg = MessageModel(
      id: msgId,
      senderId: senderUid,
      text: text,
      type: MessageType.text,
      timestamp: now,
      replyToId: replyToId,
      replyToText: replyToText,
      replyToImageUrl: replyToImageUrl,
      replyToSenderId: replyToSenderId,
      replyToThumb: replyToThumb,
    );

    await _commitMessage(
      chatDocId: id,
      msg: msg,
      receiverUid: receiverUid,
      preview: text,
    );
  }

  Future<void> sendImageMessage({
    required String senderUid,
    required String receiverUid,
    required File imageFile,
    String? text,
    String? replyToId,
    String? replyToText,
    String? replyToImageUrl,
    String? replyToSenderId,
  }) async {
    await ensureChatExists(senderUid, receiverUid);
    final id = chatId(senderUid, receiverUid);
    final msgId = _uuid.v4();
    final now = DateTime.now();

    final compressed = await MediaCompressor.compressImage(imageFile);
    final ref = _storage.ref('chat_images/$senderUid/$msgId.jpg');
    await ref.putFile(compressed, SettableMetadata(contentType: 'image/jpeg'));
    final imageUrl = await ref.getDownloadURL();

    final msg = MessageModel(
      id: msgId,
      senderId: senderUid,
      text: text,
      imageUrl: imageUrl,
      type: MessageType.image,
      timestamp: now,
      replyToId: replyToId,
      replyToText: replyToText,
      replyToImageUrl: replyToImageUrl,
      replyToSenderId: replyToSenderId,
    );

    await _commitMessage(
      chatDocId: id,
      msg: msg,
      receiverUid: receiverUid,
      preview: messagePreview(msg),
    );
  }

  Future<void> sendVideoMessage({
    required String senderUid,
    required String receiverUid,
    required File videoFile,
    String? text,
    String? replyToId,
    String? replyToText,
    String? replyToImageUrl,
    String? replyToSenderId,
  }) async {
    await ensureChatExists(senderUid, receiverUid);
    final id = chatId(senderUid, receiverUid);
    final msgId = _uuid.v4();
    final now = DateTime.now();

    final ext = videoFile.path.split('.').last.toLowerCase();
    final ref = _storage.ref('chat_videos/$senderUid/$msgId.$ext');
    // The still frame uploads alongside the video rather than after it, so it
    // adds almost nothing to the send time.
    final extras = await VideoThumbs.forUpload(videoFile);
    final uploads = await Future.wait<String?>([
      () async {
        await ref.putFile(
            videoFile, SettableMetadata(contentType: 'video/$ext'));
        return ref.getDownloadURL();
      }(),
      _uploadThumb(extras.thumb, 'chat_videos/$senderUid/${msgId}_thumb.jpg'),
    ]);
    final videoUrl = uploads[0]!;

    final msg = MessageModel(
      id: msgId,
      senderId: senderUid,
      text: text,
      videoUrl: videoUrl,
      videoThumbUrl: uploads[1],
      videoDurationMs: extras.durationMs,
      type: MessageType.video,
      timestamp: now,
      replyToId: replyToId,
      replyToText: replyToText,
      replyToImageUrl: replyToImageUrl,
      replyToSenderId: replyToSenderId,
    );

    await _commitMessage(
      chatDocId: id,
      msg: msg,
      receiverUid: receiverUid,
      preview: messagePreview(msg),
    );
  }

  Future<void> sendGifMessage({
    required String senderUid,
    required String receiverUid,
    required String gifUrl,
    String? replyToId,
    String? replyToText,
    String? replyToImageUrl,
    String? replyToSenderId,
  }) async {
    await ensureChatExists(senderUid, receiverUid);
    final id = chatId(senderUid, receiverUid);
    final msgId = _uuid.v4();
    final now = DateTime.now();

    final msg = MessageModel(
      id: msgId,
      senderId: senderUid,
      imageUrl: gifUrl,
      type: MessageType.gif,
      timestamp: now,
      replyToId: replyToId,
      replyToText: replyToText,
      replyToImageUrl: replyToImageUrl,
      replyToSenderId: replyToSenderId,
    );

    await _commitMessage(
      chatDocId: id,
      msg: msg,
      receiverUid: receiverUid,
      preview: messagePreview(msg),
    );
  }

  Future<void> sendStickerMessage({
    required String senderUid,
    required String receiverUid,
    required String sticker,
    String? replyToId,
    String? replyToText,
    String? replyToImageUrl,
    String? replyToSenderId,
  }) async {
    await ensureChatExists(senderUid, receiverUid);
    final id = chatId(senderUid, receiverUid);
    final msgId = _uuid.v4();
    final now = DateTime.now();

    final msg = MessageModel(
      id: msgId,
      senderId: senderUid,
      text: sticker,
      type: MessageType.sticker,
      timestamp: now,
      replyToId: replyToId,
      replyToText: replyToText,
      replyToImageUrl: replyToImageUrl,
      replyToSenderId: replyToSenderId,
    );

    await _commitMessage(
      chatDocId: id,
      msg: msg,
      receiverUid: receiverUid,
      preview: messagePreview(msg),
    );
  }

  Future<void> sendVoiceMessage({
    required String senderUid,
    required String receiverUid,
    required File audioFile,
    required int durationSeconds,
    String? replyToId,
    String? replyToText,
    String? replyToImageUrl,
    String? replyToSenderId,
  }) async {
    await ensureChatExists(senderUid, receiverUid);
    final id = chatId(senderUid, receiverUid);
    final msgId = _uuid.v4();
    final now = DateTime.now();

    final ref = _storage.ref('voice_messages/$senderUid/$msgId.aac');
    await ref.putFile(audioFile);
    final audioUrl = await ref.getDownloadURL();

    final msg = MessageModel(
      id: msgId,
      senderId: senderUid,
      audioUrl: audioUrl,
      audioDurationSeconds: durationSeconds,
      type: MessageType.voice,
      timestamp: now,
      replyToId: replyToId,
      replyToText: replyToText,
      replyToImageUrl: replyToImageUrl,
      replyToSenderId: replyToSenderId,
    );

    await _commitMessage(
      chatDocId: id,
      msg: msg,
      receiverUid: receiverUid,
      preview: messagePreview(msg),
    );
  }

  Future<void> sendAudioFileMessage({
    required String senderUid,
    required String receiverUid,
    required File audioFile,
    required String fileName,
    required int fileSizeBytes,
    required int durationSeconds,
    String? replyToId,
    String? replyToText,
    String? replyToImageUrl,
    String? replyToSenderId,
  }) async {
    await ensureChatExists(senderUid, receiverUid);
    final id = chatId(senderUid, receiverUid);
    final msgId = _uuid.v4();
    final now = DateTime.now();

    final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : 'mp3';
    final ref = _storage.ref('chat_audio/$senderUid/$msgId.$ext');
    await ref.putFile(audioFile, SettableMetadata(contentType: 'audio/$ext'));
    final audioUrl = await ref.getDownloadURL();

    final msg = MessageModel(
      id: msgId,
      senderId: senderUid,
      audioUrl: audioUrl,
      audioDurationSeconds: durationSeconds,
      fileName: fileName,
      fileSizeBytes: fileSizeBytes,
      type: MessageType.audioFile,
      timestamp: now,
      replyToId: replyToId,
      replyToText: replyToText,
      replyToImageUrl: replyToImageUrl,
      replyToSenderId: replyToSenderId,
    );

    await _commitMessage(
      chatDocId: id,
      msg: msg,
      receiverUid: receiverUid,
      preview: messagePreview(msg),
    );
  }

  // ── Documents ─────────────────────────────────────────────────────────────

  Future<void> sendDocumentMessage({
    required String senderUid,
    required String receiverUid,
    required File file,
    required String fileName,
    required int fileSizeBytes,
    String? replyToId,
    String? replyToText,
    String? replyToImageUrl,
    String? replyToSenderId,
  }) async {
    await ensureChatExists(senderUid, receiverUid);
    final id = chatId(senderUid, receiverUid);
    final msgId = _uuid.v4();

    final ext =
        fileName.contains('.') ? fileName.split('.').last.toLowerCase() : 'bin';
    final ref = _storage.ref('chat_documents/$senderUid/$msgId.$ext');
    await ref.putFile(file, SettableMetadata(contentType: _mimeFor(ext)));
    final url = await ref.getDownloadURL();

    final msg = MessageModel(
      id: msgId,
      senderId: senderUid,
      documentUrl: url,
      fileName: fileName,
      fileSizeBytes: fileSizeBytes,
      type: MessageType.document,
      timestamp: DateTime.now(),
      replyToId: replyToId,
      replyToText: replyToText,
      replyToImageUrl: replyToImageUrl,
      replyToSenderId: replyToSenderId,
    );

    await _commitMessage(
      chatDocId: id,
      msg: msg,
      receiverUid: receiverUid,
      preview: messagePreview(msg),
    );
  }

  /// Best-effort content type so the browser/viewer opens the file rather than
  /// downloading it as an opaque blob.
  static String _mimeFor(String ext) {
    switch (ext) {
      case 'pdf':
        return 'application/pdf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'ppt':
        return 'application/vnd.ms-powerpoint';
      case 'pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      case 'txt':
        return 'text/plain';
      case 'csv':
        return 'text/csv';
      case 'zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }

  // ── Reactions ─────────────────────────────────────────────────────────────

  /// Toggles [emoji] for [uid]. Reacting with the same emoji again clears it;
  /// a different emoji replaces it, so each person holds at most one.
  Future<void> toggleReaction({
    required String uid1,
    required String uid2,
    required String messageId,
    required String reactorUid,
    required String emoji,
    required String? current,
  }) async {
    final ref = _db
        .collection('chats')
        .doc(chatId(uid1, uid2))
        .collection('messages')
        .doc(messageId);
    try {
      await ref.update({
        'reactions.$reactorUid':
            current == emoji ? FieldValue.delete() : emoji,
      });
    } catch (_) {}
  }

  // ── Typing indicator ──────────────────────────────────────────────────────

  /// Stamps the typing time on the chat document. The reader treats a stamp
  /// older than a few seconds as stale, so no explicit "stopped" write is
  /// needed if the app dies mid-compose.
  Future<void> setTyping(String uid1, String uid2, String selfUid,
      {required bool typing}) async {
    await _updateChatMeta(chatId(uid1, uid2), {
      'typing_$selfUid': typing ? Timestamp.now() : null,
    });
  }

  // ── Pinned message ────────────────────────────────────────────────────────

  /// Pins a message by copying its preview onto the chat document. The copy
  /// matters: messages are removed after two days by the Firestore TTL policy,
  /// and a pin that pointed at a deleted document would silently blank out.
  Future<void> pinMessage({
    required String uid1,
    required String uid2,
    required MessageModel msg,
    required String pinnedBy,
  }) async {
    await _updateChatMeta(chatId(uid1, uid2), {
      'pinnedMessageId': msg.id,
      'pinnedText': messagePreview(msg),
      'pinnedSenderId': msg.senderId,
      'pinnedBy': pinnedBy,
      'pinnedAt': Timestamp.now(),
    });
  }

  Future<void> unpinMessage(String uid1, String uid2) async {
    await _updateChatMeta(chatId(uid1, uid2), {
      'pinnedMessageId': FieldValue.delete(),
      'pinnedText': FieldValue.delete(),
      'pinnedSenderId': FieldValue.delete(),
      'pinnedBy': FieldValue.delete(),
      'pinnedAt': FieldValue.delete(),
    });
  }

  // ── Forwarding ────────────────────────────────────────────────────────────

  /// Re-sends an existing message into another 1:1 chat. Media is referenced by
  /// its existing Storage URL rather than re-uploaded, so forwarding is a
  /// single small write regardless of attachment size.
  Future<void> forwardMessage({
    required MessageModel source,
    required String senderUid,
    required String receiverUid,
  }) async {
    await ensureChatExists(senderUid, receiverUid);
    final id = chatId(senderUid, receiverUid);
    final msgId = _uuid.v4();

    final msg = MessageModel(
      id: msgId,
      senderId: senderUid,
      text: source.text,
      audioUrl: source.audioUrl,
      audioDurationSeconds: source.audioDurationSeconds,
      fileName: source.fileName,
      fileSizeBytes: source.fileSizeBytes,
      documentUrl: source.documentUrl,
      imageUrl: source.imageUrl,
      videoUrl: source.videoUrl,
      videoThumbUrl: source.videoThumbUrl,
      videoDurationMs: source.videoDurationMs,
      type: source.type,
      timestamp: DateTime.now(),
      isForwarded: true,
    );

    await _commitMessage(
      chatDocId: id,
      msg: msg,
      receiverUid: receiverUid,
      preview: messagePreview(msg),
    );
  }

  // ── Starred messages ──────────────────────────────────────────────────────
  //
  // Starred copies live under the user's own private document tree rather than
  // as a flag on the message. Chat messages are deleted after two days by the
  // Firestore TTL policy, so a flag would take the starred message with it —
  // the whole point of starring is that it outlives the conversation.

  CollectionReference<Map<String, dynamic>> _starredCol(String uid) =>
      _db.collection('users').doc(uid).collection('starred_messages');

  Future<void> starMessage({
    required String uid,
    required MessageModel msg,
    required String chatLabel,
  }) async {
    await _starredCol(uid).doc(msg.id).set({
      'senderId': msg.senderId,
      'senderName': msg.senderName,
      'preview': messagePreview(msg),
      'text': msg.text,
      'imageUrl': msg.imageUrl,
      'videoUrl': msg.videoUrl,
      'documentUrl': msg.documentUrl,
      'fileName': msg.fileName,
      'type': msg.type.name,
      'chatLabel': chatLabel,
      'originalTimestamp': Timestamp.fromDate(msg.timestamp),
      'starredAt': Timestamp.now(),
    });
  }

  Future<void> unstarMessage(String uid, String messageId) async {
    try {
      await _starredCol(uid).doc(messageId).delete();
    } catch (_) {}
  }

  Stream<Set<String>> starredIds(String uid) => _starredCol(uid)
      .snapshots()
      .map((s) => s.docs.map((d) => d.id).toSet());

  Stream<List<Map<String, dynamic>>> starredMessages(String uid) =>
      _starredCol(uid)
          .orderBy('starredAt', descending: true)
          .snapshots()
          .map((s) => s.docs.map((d) => {'id': d.id, ...d.data()}).toList());

  // ── Search ────────────────────────────────────────────────────────────────

  /// Text search within one conversation. Firestore has no substring operator,
  /// so this pulls the chat's messages (at most two days' worth — older ones no
  /// longer exist) and filters in memory.
  Future<List<MessageModel>> searchMessages({
    required String uid1,
    required String uid2,
    required String query,
  }) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    final snap = await _db
        .collection('chats')
        .doc(chatId(uid1, uid2))
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .get();
    return snap.docs
        .map(MessageModel.fromFirestore)
        .where((m) =>
            !m.isDeleted &&
            ((m.text?.toLowerCase().contains(q) ?? false) ||
                (m.fileName?.toLowerCase().contains(q) ?? false)))
        .toList();
  }

  // ── Edit / Delete ─────────────────────────────────────────────────────────

  Future<void> editMessage({
    required String uid1,
    required String uid2,
    required String messageId,
    required String newText,
  }) async {
    final id = chatId(uid1, uid2);
    await _db
        .collection('chats')
        .doc(id)
        .collection('messages')
        .doc(messageId)
        .update({'text': newText, 'isEdited': true});
  }

  /// Removes the message for everyone. The document is kept as a tombstone
  /// (`isDeleted`) so the other side sees "This message was deleted" rather
  /// than the message silently vanishing — but the text and media are stripped
  /// and the Storage objects removed, so nothing recoverable is left behind.
  /// Uploads a video's still frame. Returns null on any failure: the video
  /// still sends, it just shows the generated-on-device frame instead.
  Future<String?> _uploadThumb(File? thumb, String path) async {
    if (thumb == null) return null;
    try {
      final ref = _storage.ref(path);
      await ref.putFile(thumb, SettableMetadata(contentType: 'image/jpeg'));
      return await ref.getDownloadURL();
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteMessage({
    required String uid1,
    required String uid2,
    required String messageId,
    String? audioUrl,
    String? imageUrl,
    String? videoUrl,
    String? videoThumbUrl,
    String? documentUrl,
  }) async {
    final id = chatId(uid1, uid2);
    await _db
        .collection('chats')
        .doc(id)
        .collection('messages')
        .doc(messageId)
        .update({
      'isDeleted': true,
      'text': FieldValue.delete(),
      'audioUrl': FieldValue.delete(),
      'imageUrl': FieldValue.delete(),
      'videoUrl': FieldValue.delete(),
      'videoThumbUrl': FieldValue.delete(),
      'documentUrl': FieldValue.delete(),
      'reactions': FieldValue.delete(),
    });
    // Delete associated media from Storage so it isn't orphaned. The document
    // survives as a tombstone, so the onDocumentDeleted trigger won't fire and
    // this client-side cleanup is what actually reclaims the bytes.
    for (final url in [
      audioUrl,
      imageUrl,
      videoUrl,
      videoThumbUrl,
      documentUrl
    ]) {
      if (url != null && url.isNotEmpty) {
        try { await _storage.refFromURL(url).delete(); } catch (_) {}
      }
    }
    // Keep the chat-list preview in sync: recompute from the latest remaining
    // message (or clear if none) so a deleted last message no longer shows.
    await _refreshLastMessage(id);
  }

  /// Hides the message for [uid] only. The document is untouched for everyone
  /// else; the reader filters on `deletedFor`.
  ///
  /// Deliberately does not touch the chat's last-message preview: that field is
  /// shared by both participants, so rewriting it here would change what the
  /// other person sees because of a choice only this user made.
  Future<void> deleteMessageForMe({
    required String uid1,
    required String uid2,
    required String messageId,
    required String uid,
  }) async {
    try {
      await _db
          .collection('chats')
          .doc(chatId(uid1, uid2))
          .collection('messages')
          .doc(messageId)
          .update({
        'deletedFor': FieldValue.arrayUnion([uid]),
      });
    } catch (_) {}
  }

  /// Recomputes a chat's lastMessage/lastSenderId/lastMessageTime from the most
  /// recent remaining message. Clears them when no messages are left.
  Future<void> _refreshLastMessage(String chatDocId) async {
    try {
      final snap = await _db
          .collection('chats')
          .doc(chatDocId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(1)
          .get();
      if (snap.docs.isEmpty) {
        await _updateChatMeta(chatDocId, {
          'lastMessage': '',
          'lastSenderId': '',
        });
        return;
      }
      final last = MessageModel.fromFirestore(snap.docs.first);
      await _updateChatMeta(chatDocId, {
        'lastMessage': messagePreview(last),
        'lastSenderId': last.senderId,
        'lastMessageTime': Timestamp.fromDate(last.timestamp),
      });
    } catch (_) {}
  }

  /// The short chat-list preview string for a message, matching what each
  /// send method writes to `lastMessage`.
  static String messagePreview(MessageModel m) {
    if (m.isDeleted) return '🚫 This message was deleted';
    switch (m.type) {
      case MessageType.document:
        return '📄 ${m.fileName ?? 'Document'}';
      case MessageType.voice:
        return '🎤 Voice message';
      case MessageType.audioFile:
        return '🎵 Audio';
      case MessageType.image:
        return (m.text != null && m.text!.isNotEmpty) ? '📷 ${m.text}' : '📷 Image';
      case MessageType.video:
        return (m.text != null && m.text!.isNotEmpty) ? '🎥 ${m.text}' : '🎥 Video';
      case MessageType.gif:
        return '🎞️ GIF';
      case MessageType.sticker:
        return m.text ?? '😊 Sticker';
      case MessageType.text:
        return m.text ?? '';
    }
  }
}
