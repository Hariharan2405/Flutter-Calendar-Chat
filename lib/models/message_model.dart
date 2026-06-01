import 'package:cloud_firestore/cloud_firestore.dart';

enum MessageType { text, voice, image, gif, sticker, video }

class MessageModel {
  final String id;
  final String senderId;
  final String? senderName; // populated for group messages
  final String? text;
  final String? audioUrl;
  final int? audioDurationSeconds;
  final String? imageUrl;
  final String? videoUrl;
  final String? replyToId;
  final String? replyToText;
  final String? replyToImageUrl;
  final String? replyToSenderId;
  final String? replyToSenderName; // for group reply attribution
  final MessageType type;
  final DateTime timestamp;
  final bool isEdited;

  MessageModel({
    required this.id,
    required this.senderId,
    this.senderName,
    this.text,
    this.audioUrl,
    this.audioDurationSeconds,
    this.imageUrl,
    this.videoUrl,
    this.replyToId,
    this.replyToText,
    this.replyToImageUrl,
    this.replyToSenderId,
    this.replyToSenderName,
    required this.type,
    required this.timestamp,
    this.isEdited = false,
  });

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
      imageUrl: data['imageUrl'],
      videoUrl: data['videoUrl'],
      replyToId: data['replyToId'],
      replyToText: data['replyToText'],
      replyToImageUrl: data['replyToImageUrl'],
      replyToSenderId: data['replyToSenderId'],
      replyToSenderName: data['replyToSenderName'] as String?,
      type: type,
      timestamp: (data['timestamp'] as Timestamp).toDate(),
      isEdited: data['isEdited'] ?? false,
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
      default:
        typeStr = 'text';
    }
    return {
      'senderId': senderId,
      if (text != null) 'text': text,
      if (audioUrl != null) 'audioUrl': audioUrl,
      if (audioDurationSeconds != null) 'audioDurationSeconds': audioDurationSeconds,
      if (imageUrl != null) 'imageUrl': imageUrl,
      if (videoUrl != null) 'videoUrl': videoUrl,
      if (replyToId != null) 'replyToId': replyToId,
      if (replyToText != null) 'replyToText': replyToText,
      if (replyToImageUrl != null) 'replyToImageUrl': replyToImageUrl,
      if (replyToSenderId != null) 'replyToSenderId': replyToSenderId,
      if (replyToSenderName != null) 'replyToSenderName': replyToSenderName,
      if (senderName != null) 'senderName': senderName,
      'type': typeStr,
      'timestamp': Timestamp.fromDate(timestamp),
      'expireAt': Timestamp.fromDate(timestamp.add(const Duration(days: 3))),
      'isEdited': isEdited,
    };
  }
}
