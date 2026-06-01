import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:uuid/uuid.dart';
import '../models/group_model.dart';
import '../models/message_model.dart';

class GroupChatService {
  static final GroupChatService _instance = GroupChatService._();
  factory GroupChatService() => _instance;
  GroupChatService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final _uuid = const Uuid();

  static const _col = 'group_chats';

  // ── Group CRUD ─────────────────────────────────────────────────────────────

  Future<String> createGroup({
    required String name,
    required String creatorUid,
    required String creatorName,
    required List<String> participantUids,
  }) async {
    final groupId = _uuid.v4();
    final all = [...participantUids, creatorUid].toSet().toList();
    final initial = <String, dynamic>{};
    for (final uid in all) {
      initial['unread_$uid'] = 0;
    }
    await _db.collection(_col).doc(groupId).set({
      'name': name,
      'iconUrl': null,
      'createdBy': creatorUid,
      'participants': all,
      'admins': [creatorUid],
      'lastMessage': '',
      'lastSenderId': '',
      'lastSenderName': '',
      'lastMessageTime': null,
      'createdAt': Timestamp.now(),
      ...initial,
    });
    return groupId;
  }

  Future<void> updateGroupName(String groupId, String name) async {
    await _db.collection(_col).doc(groupId).update({'name': name});
  }

  Future<String> uploadGroupIcon(String groupId, File file) async {
    final ref = _storage.ref('group_icons/$groupId/icon.jpg');
    await ref.putFile(file);
    final url = await ref.getDownloadURL();
    await _db.collection(_col).doc(groupId).update({'iconUrl': url});
    return url;
  }

  Future<void> addMember(String groupId, String uid) async {
    await _db.collection(_col).doc(groupId).update({
      'participants': FieldValue.arrayUnion([uid]),
      'unread_$uid': 0,
    });
  }

  Future<void> removeMember(String groupId, String uid) async {
    await _db.collection(_col).doc(groupId).update({
      'participants': FieldValue.arrayRemove([uid]),
      'admins': FieldValue.arrayRemove([uid]),
    });
  }

  Future<void> leaveGroup(String groupId, String uid) async {
    await removeMember(groupId, uid);
  }

  Future<void> makeAdmin(String groupId, String uid) async {
    await _db.collection(_col).doc(groupId).update({
      'admins': FieldValue.arrayUnion([uid]),
    });
  }

  Future<void> removeAdmin(String groupId, String uid) async {
    await _db.collection(_col).doc(groupId).update({
      'admins': FieldValue.arrayRemove([uid]),
    });
  }

  // ── Streams ────────────────────────────────────────────────────────────────

  Stream<GroupModel?> watchGroup(String groupId) {
    return _db.collection(_col).doc(groupId).snapshots().map(
          (doc) => doc.exists ? GroupModel.fromFirestore(doc) : null,
        );
  }

  Stream<List<GroupModel>> getAllGroupsFor(String uid) {
    return _db
        .collection(_col)
        .where('participants', arrayContains: uid)
        .orderBy('lastMessageTime', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map(GroupModel.fromFirestore).toList());
  }

  Stream<List<MessageModel>> messages(String groupId) {
    final since = DateTime.now().subtract(const Duration(days: 3));
    return _db
        .collection(_col)
        .doc(groupId)
        .collection('messages')
        .where('timestamp', isGreaterThan: Timestamp.fromDate(since))
        .orderBy('timestamp')
        .snapshots()
        .map((snap) => snap.docs.map(MessageModel.fromFirestore).toList());
  }

  // ── Read tracking ──────────────────────────────────────────────────────────

  Future<void> markRead(String groupId, String uid) async {
    try {
      await _db.collection(_col).doc(groupId).update({
        'unread_$uid': 0,
        'lastReadAt_$uid': Timestamp.now(),
      });
    } catch (_) {}
  }

  Future<void> markDelivered(String groupId, String uid) async {
    try {
      await _db.collection(_col).doc(groupId).update({
        'lastDeliveredAt_$uid': Timestamp.now(),
      });
    } catch (_) {}
  }

  // ── Sending messages ───────────────────────────────────────────────────────

  Future<void> _updateGroupMeta(
    String groupId,
    String lastMessage,
    String senderId,
    String senderName,
    List<String> participants,
  ) async {
    final updates = <String, dynamic>{
      'lastMessage': lastMessage,
      'lastSenderId': senderId,
      'lastSenderName': senderName,
      'lastMessageTime': Timestamp.now(),
    };
    for (final uid in participants) {
      if (uid != senderId) {
        updates['unread_$uid'] = FieldValue.increment(1);
      }
    }
    await _db.collection(_col).doc(groupId).update(updates);
  }

  Future<String> sendTextMessage({
    required String groupId,
    required String senderId,
    required String senderName,
    required List<String> participants,
    required String text,
    String? replyToId,
    String? replyToText,
    String? replyToImageUrl,
    String? replyToSenderId,
    String? replyToSenderName,
  }) async {
    final msgId = _uuid.v4();
    final msg = MessageModel(
      id: msgId,
      senderId: senderId,
      senderName: senderName,
      type: MessageType.text,
      text: text,
      timestamp: DateTime.now(),
      replyToId: replyToId,
      replyToText: replyToText,
      replyToImageUrl: replyToImageUrl,
      replyToSenderId: replyToSenderId,
      replyToSenderName: replyToSenderName,
    );
    await _db
        .collection(_col)
        .doc(groupId)
        .collection('messages')
        .doc(msgId)
        .set(msg.toFirestore());
    await _updateGroupMeta(groupId, text, senderId, senderName, participants);
    return msgId;
  }

  Future<String> sendImageMessage({
    required String groupId,
    required String senderId,
    required String senderName,
    required List<String> participants,
    required File imageFile,
    String? replyToId,
    String? replyToText,
    String? replyToImageUrl,
    String? replyToSenderId,
    String? replyToSenderName,
  }) async {
    final msgId = _uuid.v4();
    final ref = _storage.ref('group_images/$groupId/$senderId/$msgId.jpg');
    await ref.putFile(imageFile);
    final url = await ref.getDownloadURL();
    final msg = MessageModel(
      id: msgId,
      senderId: senderId,
      senderName: senderName,
      type: MessageType.image,
      imageUrl: url,
      timestamp: DateTime.now(),
      replyToId: replyToId,
      replyToText: replyToText,
      replyToImageUrl: replyToImageUrl,
      replyToSenderId: replyToSenderId,
      replyToSenderName: replyToSenderName,
    );
    await _db
        .collection(_col)
        .doc(groupId)
        .collection('messages')
        .doc(msgId)
        .set(msg.toFirestore());
    await _updateGroupMeta(groupId, '📷 Photo', senderId, senderName, participants);
    return msgId;
  }

  Future<String> sendVoiceMessage({
    required String groupId,
    required String senderId,
    required String senderName,
    required List<String> participants,
    required File audioFile,
    required int durationSeconds,
    String? replyToId,
    String? replyToText,
    String? replyToSenderId,
    String? replyToSenderName,
  }) async {
    final msgId = _uuid.v4();
    final ref = _storage.ref('group_voice/$groupId/$senderId/$msgId.aac');
    await ref.putFile(audioFile);
    final url = await ref.getDownloadURL();
    final msg = MessageModel(
      id: msgId,
      senderId: senderId,
      senderName: senderName,
      type: MessageType.voice,
      audioUrl: url,
      audioDurationSeconds: durationSeconds,
      timestamp: DateTime.now(),
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderId: replyToSenderId,
      replyToSenderName: replyToSenderName,
    );
    await _db
        .collection(_col)
        .doc(groupId)
        .collection('messages')
        .doc(msgId)
        .set(msg.toFirestore());
    await _updateGroupMeta(groupId, '🎤 Voice message', senderId, senderName, participants);
    return msgId;
  }

  // ── Edit / delete ──────────────────────────────────────────────────────────

  Future<void> editMessage(String groupId, String messageId, String newText) async {
    await _db
        .collection(_col)
        .doc(groupId)
        .collection('messages')
        .doc(messageId)
        .update({'text': newText, 'isEdited': true});
  }

  Future<void> deleteMessage(
    String groupId,
    String messageId, {
    String? audioUrl,
    String? imageUrl,
    String? videoUrl,
  }) async {
    await _db
        .collection(_col)
        .doc(groupId)
        .collection('messages')
        .doc(messageId)
        .delete();
    // Delete associated media from Storage so it isn't orphaned.
    for (final url in [audioUrl, imageUrl, videoUrl]) {
      if (url != null && url.isNotEmpty) {
        try { await _storage.refFromURL(url).delete(); } catch (_) {}
      }
    }
  }
}
