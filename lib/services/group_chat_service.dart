import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:uuid/uuid.dart';
import '../models/group_model.dart';
import '../models/message_model.dart';
import '../utils/media_compressor.dart';
import 'chat_service.dart';
import 'video_thumbs.dart';

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

  /// Any member can upload a new group icon (not just admins).
  Future<String> uploadGroupIcon(String groupId, File file) async {
    final compressed =
        await MediaCompressor.compressImage(file, maxSide: 512, quality: 80);
    final ref = _storage.ref('group_icons/$groupId/icon.jpg');
    await ref.putFile(compressed, SettableMetadata(contentType: 'image/jpeg'));
    final url = await ref.getDownloadURL();
    await _db.collection(_col).doc(groupId).update({'iconUrl': url});
    return url;
  }

  /// Uploads a background wallpaper image to Storage and stores the URL.
  Future<String> uploadGroupBackground(String groupId, File file) async {
    final compressed = await MediaCompressor.compressImage(file);
    final ref = _storage.ref('group_backgrounds/$groupId/bg.jpg');
    await ref.putFile(compressed, SettableMetadata(contentType: 'image/jpeg'));
    return await ref.getDownloadURL();
  }

  /// Persists the shared group background (color OR image URL).
  /// Pass [colorValue] for a solid color, [imageUrl] for a wallpaper,
  /// or neither to reset to the default.
  Future<void> updateGroupBackground(
    String groupId, {
    int?    colorValue,
    String? imageUrl,
  }) async {
    await _db.collection(_col).doc(groupId).update({
      'backgroundColor':    colorValue,
      'backgroundImageUrl': imageUrl,
    });
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
    final since = DateTime.now().subtract(const Duration(days: 2));
    return _db
        .collection(_col)
        .doc(groupId)
        .collection('messages')
        .where('timestamp', isGreaterThan: Timestamp.fromDate(since))
        .orderBy('timestamp')
        .limitToLast(20)
        .snapshots()
        .map((snap) => snap.docs.map(MessageModel.fromFirestore).toList());
  }

  /// Fetches up to 20 messages older than [before], used for pagination.
  Future<List<MessageModel>> loadOlderMessages(
      String groupId, DateTime before) async {
    final since = DateTime.now().subtract(const Duration(days: 2));
    final snap = await _db
        .collection(_col)
        .doc(groupId)
        .collection('messages')
        .where('timestamp', isGreaterThan: Timestamp.fromDate(since))
        .where('timestamp', isLessThan: Timestamp.fromDate(before))
        .orderBy('timestamp')
        .limitToLast(20)
        .get();
    return snap.docs.map(MessageModel.fromFirestore).toList();
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

  /// Writes a group message and the group's preview/unread counters as one
  /// atomic batch, so neither can land without the other.
  ///
  /// This deliberately keeps the property the old fire-and-forget was
  /// protecting: a batch is a *single* round trip, so awaiting it returns as
  /// soon as the write acks. The duplicate-bubble bug came from awaiting a
  /// second sequential write, which no longer happens.
  Future<void> _commitGroupMessage({
    required String groupId,
    required MessageModel msg,
    required String senderName,
    required List<String> participants,
    required String preview,
  }) async {
    final batch = _db.batch();
    final groupRef = _db.collection(_col).doc(groupId);

    batch.set(groupRef.collection('messages').doc(msg.id), msg.toFirestore());

    final updates = <String, dynamic>{
      'lastMessage': preview,
      'lastSenderId': msg.senderId,
      'lastSenderName': senderName,
      'lastMessageTime': Timestamp.fromDate(msg.timestamp),
      // Carried on the group doc so a muted member can still be alerted when
      // they are named — the notifier reads the group, not the message.
      'lastMentions': msg.mentions,
    };
    for (final uid in participants) {
      if (uid != msg.senderId) updates['unread_$uid'] = FieldValue.increment(1);
    }
    batch.update(groupRef, updates);

    await batch.commit();
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
    List<String> mentions = const [],
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
      mentions: mentions,
    );
    await _commitGroupMessage(
      groupId: groupId,
      msg: msg,
      senderName: senderName,
      participants: participants,
      preview: text,
    );
    return msgId;
  }

  Future<String> sendImageMessage({
    required String groupId,
    required String senderId,
    required String senderName,
    required List<String> participants,
    required File imageFile,
    String? text,
    String? replyToId,
    String? replyToText,
    String? replyToImageUrl,
    String? replyToSenderId,
    String? replyToSenderName,
  }) async {
    final msgId = _uuid.v4();
    final compressed = await MediaCompressor.compressImage(imageFile);
    final ref = _storage.ref('group_images/$groupId/$senderId/$msgId.jpg');
    await ref.putFile(compressed, SettableMetadata(contentType: 'image/jpeg'));
    final url = await ref.getDownloadURL();
    final msg = MessageModel(
      id: msgId,
      senderId: senderId,
      senderName: senderName,
      text: text,
      type: MessageType.image,
      imageUrl: url,
      timestamp: DateTime.now(),
      replyToId: replyToId,
      replyToText: replyToText,
      replyToImageUrl: replyToImageUrl,
      replyToSenderId: replyToSenderId,
      replyToSenderName: replyToSenderName,
    );
    await _commitGroupMessage(
      groupId: groupId,
      msg: msg,
      senderName: senderName,
      participants: participants,
      preview: (text != null && text.isNotEmpty) ? '📷 $text' : '📷 Photo',
    );
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
    String? replyToImageUrl,
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
      replyToImageUrl: replyToImageUrl,
      replyToSenderId: replyToSenderId,
      replyToSenderName: replyToSenderName,
    );
    await _commitGroupMessage(
      groupId: groupId,
      msg: msg,
      senderName: senderName,
      participants: participants,
      preview: '🎤 Voice message',
    );
    return msgId;
  }

  Future<String> sendAudioFileMessage({
    required String groupId,
    required String senderId,
    required String senderName,
    required List<String> participants,
    required File audioFile,
    required String fileName,
    required int fileSizeBytes,
    required int durationSeconds,
    String? replyToId,
    String? replyToText,
    String? replyToSenderId,
    String? replyToSenderName,
  }) async {
    final msgId = _uuid.v4();
    final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : 'mp3';
    final ref = _storage.ref('group_audio/$groupId/$senderId/$msgId.$ext');
    await ref.putFile(audioFile, SettableMetadata(contentType: 'audio/$ext'));
    final url = await ref.getDownloadURL();
    final msg = MessageModel(
      id: msgId,
      senderId: senderId,
      senderName: senderName,
      type: MessageType.audioFile,
      audioUrl: url,
      audioDurationSeconds: durationSeconds,
      fileName: fileName,
      fileSizeBytes: fileSizeBytes,
      timestamp: DateTime.now(),
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderId: replyToSenderId,
      replyToSenderName: replyToSenderName,
    );
    await _commitGroupMessage(
      groupId: groupId,
      msg: msg,
      senderName: senderName,
      participants: participants,
      preview: '🎵 Audio',
    );
    return msgId;
  }

  Future<String> sendGifMessage({
    required String groupId,
    required String senderId,
    required String senderName,
    required List<String> participants,
    required String gifUrl,
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
      type: MessageType.gif,
      imageUrl: gifUrl,
      timestamp: DateTime.now(),
      replyToId: replyToId,
      replyToText: replyToText,
      replyToImageUrl: replyToImageUrl,
      replyToSenderId: replyToSenderId,
      replyToSenderName: replyToSenderName,
    );
    await _commitGroupMessage(
      groupId: groupId,
      msg: msg,
      senderName: senderName,
      participants: participants,
      preview: '🎞️ GIF',
    );
    return msgId;
  }

  Future<String> sendStickerMessage({
    required String groupId,
    required String senderId,
    required String senderName,
    required List<String> participants,
    required String sticker,
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
      type: MessageType.sticker,
      text: sticker,
      timestamp: DateTime.now(),
      replyToId: replyToId,
      replyToText: replyToText,
      replyToImageUrl: replyToImageUrl,
      replyToSenderId: replyToSenderId,
      replyToSenderName: replyToSenderName,
    );
    await _commitGroupMessage(
      groupId: groupId,
      msg: msg,
      senderName: senderName,
      participants: participants,
      preview: sticker,
    );
    return msgId;
  }

  Future<String> sendVideoMessage({
    required String groupId,
    required String senderId,
    required String senderName,
    required List<String> participants,
    required File videoFile,
    String? text,
    String? replyToId,
    String? replyToText,
    String? replyToImageUrl,
    String? replyToSenderId,
    String? replyToSenderName,
  }) async {
    final msgId = _uuid.v4();
    final ref = _storage.ref('group_videos/$groupId/$senderId/$msgId.mp4');
    final extras = await VideoThumbs.forUpload(videoFile);
    final uploads = await Future.wait<String?>([
      () async {
        await ref.putFile(videoFile);
        return ref.getDownloadURL();
      }(),
      _uploadThumb(
          extras.thumb, 'group_videos/$groupId/$senderId/${msgId}_thumb.jpg'),
    ]);
    final url = uploads[0]!;
    final msg = MessageModel(
      id: msgId,
      senderId: senderId,
      senderName: senderName,
      text: text,
      type: MessageType.video,
      videoUrl: url,
      videoThumbUrl: uploads[1],
      videoDurationMs: extras.durationMs,
      timestamp: DateTime.now(),
      replyToId: replyToId,
      replyToText: replyToText,
      replyToImageUrl: replyToImageUrl,
      replyToSenderId: replyToSenderId,
      replyToSenderName: replyToSenderName,
    );
    await _commitGroupMessage(
      groupId: groupId,
      msg: msg,
      senderName: senderName,
      participants: participants,
      preview: (text != null && text.isNotEmpty) ? '🎬 $text' : '🎬 Video',
    );
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

  /// Removes the message for the whole group, leaving an `isDeleted` tombstone
  /// so members see "This message was deleted" instead of it silently vanishing.
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

  Future<void> deleteMessage(
    String groupId,
    String messageId, {
    String? audioUrl,
    String? imageUrl,
    String? videoUrl,
    String? videoThumbUrl,
    String? documentUrl,
  }) async {
    await _db
        .collection(_col)
        .doc(groupId)
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
    // The document survives as a tombstone, so onGroupMessageDeleted won't
    // fire — this client-side cleanup is what reclaims the Storage bytes.
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
    // Keep the chat-list preview in sync with the latest remaining message.
    await _refreshLastMessage(groupId);
  }

  /// Hides the message for [uid] only; untouched for every other member.
  ///
  /// Leaves the group's last-message preview alone — it is shared by every
  /// member, so one person hiding a message must not change what the rest see.
  Future<void> deleteMessageForMe(
      String groupId, String messageId, String uid) async {
    try {
      await _db
          .collection(_col)
          .doc(groupId)
          .collection('messages')
          .doc(messageId)
          .update({
        'deletedFor': FieldValue.arrayUnion([uid]),
      });
    } catch (_) {}
  }

  // ── Reactions ──────────────────────────────────────────────────────────────

  Future<void> toggleReaction({
    required String groupId,
    required String messageId,
    required String reactorUid,
    required String emoji,
    required String? current,
  }) async {
    try {
      await _db
          .collection(_col)
          .doc(groupId)
          .collection('messages')
          .doc(messageId)
          .update({
        'reactions.$reactorUid':
            current == emoji ? FieldValue.delete() : emoji,
      });
    } catch (_) {}
  }

  // ── Typing indicator ───────────────────────────────────────────────────────

  /// Stamps typing state on the group document. Readers treat a stamp older
  /// than a few seconds as stale, so an abandoned compose clears itself.
  Future<void> setTyping(String groupId, String uid, String name,
      {required bool typing}) async {
    try {
      await _db.collection(_col).doc(groupId).update({
        'typing_$uid': typing ? Timestamp.now() : null,
        'typingName_$uid': typing ? name : null,
      });
    } catch (_) {}
  }

  // ── Pinned message ─────────────────────────────────────────────────────────

  /// Copies the pinned message's preview onto the group document — messages
  /// themselves are removed after two days by the TTL policy, so a pin holding
  /// only an ID would blank out.
  Future<void> pinMessage({
    required String groupId,
    required MessageModel msg,
    required String pinnedBy,
    required String preview,
  }) async {
    try {
      await _db.collection(_col).doc(groupId).update({
        'pinnedMessageId': msg.id,
        'pinnedText': preview,
        'pinnedSenderName': msg.senderName ?? '',
        'pinnedBy': pinnedBy,
        'pinnedAt': Timestamp.now(),
      });
    } catch (_) {}
  }

  Future<void> unpinMessage(String groupId) async {
    try {
      await _db.collection(_col).doc(groupId).update({
        'pinnedMessageId': FieldValue.delete(),
        'pinnedText': FieldValue.delete(),
        'pinnedSenderName': FieldValue.delete(),
        'pinnedBy': FieldValue.delete(),
        'pinnedAt': FieldValue.delete(),
      });
    } catch (_) {}
  }

  // ── Documents ──────────────────────────────────────────────────────────────

  Future<String> sendDocumentMessage({
    required String groupId,
    required String senderId,
    required String senderName,
    required List<String> participants,
    required File file,
    required String fileName,
    required int fileSizeBytes,
    String? replyToId,
    String? replyToText,
    String? replyToSenderId,
    String? replyToSenderName,
  }) async {
    final msgId = _uuid.v4();
    final ext =
        fileName.contains('.') ? fileName.split('.').last.toLowerCase() : 'bin';
    final ref = _storage.ref('group_documents/$groupId/$senderId/$msgId.$ext');
    await ref.putFile(file);
    final url = await ref.getDownloadURL();

    final msg = MessageModel(
      id: msgId,
      senderId: senderId,
      senderName: senderName,
      documentUrl: url,
      fileName: fileName,
      fileSizeBytes: fileSizeBytes,
      type: MessageType.document,
      timestamp: DateTime.now(),
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderId: replyToSenderId,
      replyToSenderName: replyToSenderName,
    );

    await _commitGroupMessage(
      groupId: groupId,
      msg: msg,
      senderName: senderName,
      participants: participants,
      preview: '📄 $fileName',
    );
    return msgId;
  }

  // ── Search ─────────────────────────────────────────────────────────────────

  /// Text search inside one group. Firestore has no substring operator, so this
  /// filters in memory over the messages that still exist (at most two days').
  Future<List<MessageModel>> searchMessages(
      String groupId, String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    final snap = await _db
        .collection(_col)
        .doc(groupId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .get();
    return snap.docs
        .map(MessageModel.fromFirestore)
        .where((m) =>
            !m.isDeleted &&
            ((m.text?.toLowerCase().contains(q) ?? false) ||
                (m.fileName?.toLowerCase().contains(q) ?? false) ||
                (m.senderName?.toLowerCase().contains(q) ?? false)))
        .toList();
  }

  // ── Forwarding ─────────────────────────────────────────────────────────────

  /// Re-sends an existing message into a group, reusing the Storage URL rather
  /// than re-uploading the media.
  Future<void> forwardMessage({
    required MessageModel source,
    required String groupId,
    required String senderId,
    required String senderName,
    required List<String> participants,
    required String preview,
  }) async {
    final msgId = _uuid.v4();
    final msg = MessageModel(
      id: msgId,
      senderId: senderId,
      senderName: senderName,
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
    await _commitGroupMessage(
      groupId: groupId,
      msg: msg,
      senderName: senderName,
      participants: participants,
      preview: preview,
    );
  }

  /// Recomputes a group's last-message meta from the most recent remaining
  /// message (or clears it). Does not touch unread counts.
  Future<void> _refreshLastMessage(String groupId) async {
    try {
      final snap = await _db
          .collection(_col)
          .doc(groupId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(1)
          .get();
      final Map<String, dynamic> updates;
      if (snap.docs.isEmpty) {
        updates = {
          'lastMessage': '',
          'lastSenderId': '',
          'lastSenderName': '',
          'lastMessageTime': null,
        };
      } else {
        final last = MessageModel.fromFirestore(snap.docs.first);
        updates = {
          'lastMessage': ChatService.messagePreview(last),
          'lastSenderId': last.senderId,
          'lastSenderName': last.senderName ?? '',
          'lastMessageTime': Timestamp.fromDate(last.timestamp),
        };
      }
      await _db.collection(_col).doc(groupId).update(updates);
    } catch (_) {}
  }
}
