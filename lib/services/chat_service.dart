import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:uuid/uuid.dart';
import '../models/user_profile_model.dart';
import '../models/message_model.dart';

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

  /// Called when an existing user enters the chat screen — refreshes lastSeen and FCM token.
  Future<void> updateOnReturn(String uid) async {
    final token = await FirebaseMessaging.instance.getToken();
    await _db.collection('user_profiles').doc(uid).update({
      'lastSeen': Timestamp.fromDate(DateTime.now()),
      if (token != null) 'fcmToken': token,
    });
  }

  Future<void> setDescription(String uid, String description) async {
    await _db.collection('user_profiles').doc(uid).set(
      {'description': description},
      SetOptions(merge: true),
    );
  }

  Future<String> uploadProfilePhoto(String uid, File file) async {
    final ref = _storage.ref('profile_photos/$uid/photo.jpg');
    await ref.putFile(file, SettableMetadata(contentType: 'image/jpeg'));
    return await ref.getDownloadURL();
  }

  Future<void> updatePhotoUrl(String uid, String url) async {
    await _db.collection('user_profiles').doc(uid).update({'photoUrl': url});
  }

  Stream<List<UserProfileModel>> getAllUsersExcept(String currentUid) {
    return _db
        .collection('user_profiles')
        .orderBy('name')
        .snapshots()
        .map((snap) => snap.docs
            .where((d) => d.id != currentUid && d.data()['name'] != null)
            .map(UserProfileModel.fromFirestore)
            .toList());
  }

  Stream<List<UserProfileModel>> getAllUsersStream() {
    return _db
        .collection('user_profiles')
        .orderBy('name')
        .snapshots()
        .map((snap) => snap.docs
            .where((d) => d.data()['name'] != null)
            .map(UserProfileModel.fromFirestore)
            .toList());
  }

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
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    return _db
        .collection('chats')
        .doc(id)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .snapshots()
        .map((snap) => snap.docs
            .map(MessageModel.fromFirestore)
            .where((m) => m.timestamp.isAfter(cutoff))
            .toList());
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
  Stream<QuerySnapshot> allChatsFor(String uid) {
    return _db
        .collection('chats')
        .where('participants', arrayContains: uid)
        .snapshots();
  }

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

  // ── Send Messages ─────────────────────────────────────────────────────────

  Future<void> sendTextMessage({
    required String senderUid,
    required String receiverUid,
    required String text,
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
      text: text,
      type: MessageType.text,
      timestamp: now,
      replyToId: replyToId,
      replyToText: replyToText,
      replyToImageUrl: replyToImageUrl,
      replyToSenderId: replyToSenderId,
    );

    await _db
        .collection('chats')
        .doc(id)
        .collection('messages')
        .doc(msgId)
        .set(msg.toFirestore());

    _updateChatMeta(id, {
      'lastMessage': text,
      'lastSenderId': senderUid,
      'lastMessageTime': Timestamp.fromDate(now),
      'unread_$receiverUid': FieldValue.increment(1),
    });
  }

  Future<void> sendImageMessage({
    required String senderUid,
    required String receiverUid,
    required File imageFile,
    String? replyToId,
    String? replyToText,
    String? replyToImageUrl,
    String? replyToSenderId,
  }) async {
    await ensureChatExists(senderUid, receiverUid);
    final id = chatId(senderUid, receiverUid);
    final msgId = _uuid.v4();
    final now = DateTime.now();

    final ext = imageFile.path.split('.').last.toLowerCase();
    final ref = _storage.ref('chat_images/$senderUid/$msgId.$ext');
    await ref.putFile(imageFile);
    final imageUrl = await ref.getDownloadURL();

    final msg = MessageModel(
      id: msgId,
      senderId: senderUid,
      imageUrl: imageUrl,
      type: MessageType.image,
      timestamp: now,
      replyToId: replyToId,
      replyToText: replyToText,
      replyToImageUrl: replyToImageUrl,
      replyToSenderId: replyToSenderId,
    );

    await _db
        .collection('chats')
        .doc(id)
        .collection('messages')
        .doc(msgId)
        .set(msg.toFirestore());

    _updateChatMeta(id, {
      'lastMessage': '📷 Image',
      'lastSenderId': senderUid,
      'lastMessageTime': Timestamp.fromDate(now),
      'unread_$receiverUid': FieldValue.increment(1),
    });
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

    await _db
        .collection('chats')
        .doc(id)
        .collection('messages')
        .doc(msgId)
        .set(msg.toFirestore());

    _updateChatMeta(id, {
      'lastMessage': '🎞️ GIF',
      'lastSenderId': senderUid,
      'lastMessageTime': Timestamp.fromDate(now),
      'unread_$receiverUid': FieldValue.increment(1),
    });
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

    await _db
        .collection('chats')
        .doc(id)
        .collection('messages')
        .doc(msgId)
        .set(msg.toFirestore());

    _updateChatMeta(id, {
      'lastMessage': sticker,
      'lastSenderId': senderUid,
      'lastMessageTime': Timestamp.fromDate(now),
      'unread_$receiverUid': FieldValue.increment(1),
    });
  }

  Future<void> sendVoiceMessage({
    required String senderUid,
    required String receiverUid,
    required File audioFile,
    required int durationSeconds,
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
    );

    await _db
        .collection('chats')
        .doc(id)
        .collection('messages')
        .doc(msgId)
        .set(msg.toFirestore());

    _updateChatMeta(id, {
      'lastMessage': '🎤 Voice message',
      'lastSenderId': senderUid,
      'lastMessageTime': Timestamp.fromDate(now),
      'unread_$receiverUid': FieldValue.increment(1),
    });
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

  Future<void> deleteMessage({
    required String uid1,
    required String uid2,
    required String messageId,
  }) async {
    final id = chatId(uid1, uid2);
    await _db
        .collection('chats')
        .doc(id)
        .collection('messages')
        .doc(messageId)
        .delete();
  }
}
