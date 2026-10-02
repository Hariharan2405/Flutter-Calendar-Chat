import 'package:cloud_firestore/cloud_firestore.dart';

enum MessageType { text, voice, image, gif, sticker, video, audioFile, document }

class MessageModel {
  final String id;
  final String senderId;
  final String? senderName; // populated for group messages
  final String? text;
  final String? audioUrl;
  final int? audioDurationSeconds;
  // For audioFile and document messages: original file name and size in bytes.
  final String? fileName;
  final int? fileSizeBytes;
  final String? documentUrl;
  final String? imageUrl;
  final String? videoUrl;

  /// A still frame of [videoUrl], uploaded alongside it so the bubble shows
  /// the video instead of a black box until it is played.
  final String? videoThumbUrl;
  final int? videoDurationMs;
  final String? replyToId;
  final String? replyToText;
  final String? replyToImageUrl;
  final String? replyToSenderId;
  final String? replyToSenderName; // for group reply attribution

  /// A tiny JPEG (base64) of what was replied to. Stored inline rather than as
  /// a link because a status's photo or video is deleted after 24 hours, which
  /// would leave the reply preview broken.
  final String? replyToThumb;
  final MessageType type;
  final DateTime timestamp;
  final bool isEdited;
  /// Emoji reactions, keyed by the reacting user's UID. One emoji per person.
  final Map<String, String> reactions;
  /// True once this message has been re-sent into another chat, so the bubble
  /// can label it rather than passing it off as original.
  final bool isForwarded;
  /// UIDs mentioned via @name in a group message.
  final List<String> mentions;
  /// UIDs that removed this message for themselves only. Filtered client-side;
  /// the document stays intact for everyone else.
  final List<String> deletedFor;
  /// Deleted for everyone: content and media are stripped but the document
  /// remains as a tombstone so both sides see "This message was deleted".
  final bool isDeleted;

  MessageModel({
    required this.id,
    required this.senderId,
    this.senderName,
    this.text,
    this.audioUrl,
    this.audioDurationSeconds,
    this.fileName,
    this.fileSizeBytes,
    this.documentUrl,
    this.imageUrl,
    this.videoUrl,
    this.replyToId,
    this.replyToText,
    this.replyToImageUrl,
    this.replyToSenderId,
    this.replyToSenderName,
    this.replyToThumb,
    this.videoThumbUrl,
    this.videoDurationMs,
    required this.type,
    required this.timestamp,
    this.isEdited = false,
    this.reactions = const {},
    this.isForwarded = false,
    this.mentions = const [],
    this.deletedFor = const [],
    this.isDeleted = false,
  });

  /// True when [uid] should not see this message at all — they removed it for
  /// themselves.
  bool isHiddenFor(String uid) => deletedFor.contains(uid);

  factory MessageModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final MessageType type;
    switch (data['type']) {
      case 'voice':
        type = MessageType.voice;
        break;
      case 'image':
        type = MessageType.image;
        break;
      case 'gif':
        type = MessageType.gif;
        break;
      case 'sticker':
        type = MessageType.sticker;
        break;
      case 'video':
        type = MessageType.video;
        break;
      case 'audioFile':
        type = MessageType.audioFile;
        break;
      case 'document':
        type = MessageType.document;
        break;
      default:
        type = MessageType.text;
    }
    return MessageModel(
      id: doc.id,
      senderId: data['senderId'] ?? '',
      senderName: data['senderName'] as String?,
      text: data['text'],
      audioUrl: data['audioUrl'],
      audioDurationSeconds: data['audioDurationSeconds'],
      fileName: data['fileName'] as String?,
      fileSizeBytes: data['fileSizeBytes'] as int?,
      documentUrl: data['documentUrl'] as String?,
      imageUrl: data['imageUrl'],
      videoUrl: data['videoUrl'],
      videoThumbUrl: data['videoThumbUrl'] as String?,
      videoDurationMs: (data['videoDurationMs'] as num?)?.toInt(),
      replyToId: data['replyToId'],
      replyToText: data['replyToText'],
      replyToImageUrl: data['replyToImageUrl'],
      replyToSenderId: data['replyToSenderId'],
      replyToSenderName: data['replyToSenderName'] as String?,
      replyToThumb: data['replyToThumb'] as String?,
      type: type,
      // timestamp may be null briefly (Firestore pending-write state) before
      // the server confirms FieldValue.serverTimestamp().
      timestamp: data['timestamp'] != null
          ? (data['timestamp'] as Timestamp).toDate()
          : DateTime.now(),
      isEdited: data['isEdited'] ?? false,
      reactions: (data['reactions'] as Map?)
              ?.map((k, v) => MapEntry(k as String, v as String)) ??
          const {},
      isForwarded: data['isForwarded'] ?? false,
      mentions: (data['mentions'] as List?)?.cast<String>() ?? const [],
      deletedFor: (data['deletedFor'] as List?)?.cast<String>() ?? const [],
      isDeleted: data['isDeleted'] ?? false,
    );
  }

  Map<String, dynamic> toFirestore() {
    final String typeStr;
    switch (type) {
      case MessageType.voice:
        typeStr = 'voice';
        break;
      case MessageType.image:
        typeStr = 'image';
        break;
      case MessageType.gif:
        typeStr = 'gif';
        break;
      case MessageType.sticker:
        typeStr = 'sticker';
        break;
      case MessageType.video:
        typeStr = 'video';
        break;
      case MessageType.audioFile:
        typeStr = 'audioFile';
        break;
      case MessageType.document:
        typeStr = 'document';
        break;
      default:
        typeStr = 'text';
    }
    return {
      'senderId': senderId,
      if (text != null) 'text': text,
      if (audioUrl != null) 'audioUrl': audioUrl,
      if (audioDurationSeconds != null) 'audioDurationSeconds': audioDurationSeconds,
      if (fileName != null) 'fileName': fileName,
      if (fileSizeBytes != null) 'fileSizeBytes': fileSizeBytes,
      if (documentUrl != null) 'documentUrl': documentUrl,
      if (imageUrl != null) 'imageUrl': imageUrl,
      if (videoUrl != null) 'videoUrl': videoUrl,
      if (videoThumbUrl != null) 'videoThumbUrl': videoThumbUrl,
      if (videoDurationMs != null) 'videoDurationMs': videoDurationMs,
      if (replyToId != null) 'replyToId': replyToId,
      if (replyToText != null) 'replyToText': replyToText,
      if (replyToImageUrl != null) 'replyToImageUrl': replyToImageUrl,
      if (replyToSenderId != null) 'replyToSenderId': replyToSenderId,
      if (replyToSenderName != null) 'replyToSenderName': replyToSenderName,
      if (replyToThumb != null) 'replyToThumb': replyToThumb,
      if (senderName != null) 'senderName': senderName,
      'type': typeStr,
      // Server timestamp: Firestore stamps this at the moment the write is
      // committed on the server, AFTER any Storage upload completes.
      // This guarantees correct ordering even when uploads take many seconds,
      // and eliminates client-clock drift for all message types.
      'timestamp': FieldValue.serverTimestamp(),
      // expireAt: keep using local DateTime so the 2-day window is exact.
      'expireAt': Timestamp.fromDate(DateTime.now().add(const Duration(days: 2))),
      'isEdited': isEdited,
      if (reactions.isNotEmpty) 'reactions': reactions,
      if (isForwarded) 'isForwarded': true,
      if (mentions.isNotEmpty) 'mentions': mentions,
      if (deletedFor.isNotEmpty) 'deletedFor': deletedFor,
      if (isDeleted) 'isDeleted': true,
    };
  }
}
