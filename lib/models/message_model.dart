import 'package:cloud_firestore/cloud_firestore.dart';

enum MessageType { text, voice, image, gif }

class MessageModel {
  final String id;
  final String senderId;
  final String? text;
  final String? audioUrl;
  final int? audioDurationSeconds;
  final String? imageUrl;
  final String? replyToId;
  final String? replyToText;
  final String? replyToSenderId;
  final MessageType type;
  final DateTime timestamp;
  final bool isEdited;

  MessageModel({
    required this.id,
    required this.senderId,
    this.text,
    this.audioUrl,
    this.audioDurationSeconds,
    this.imageUrl,
    this.replyToId,
    this.replyToText,
    this.replyToSenderId,
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
      default:
        type = MessageType.text;
    }
    return MessageModel(
      id: doc.id,
      senderId: data['senderId'] ?? '',
      text: data['text'],
      audioUrl: data['audioUrl'],
      audioDurationSeconds: data['audioDurationSeconds'],
      imageUrl: data['imageUrl'],
      replyToId: data['replyToId'],
      replyToText: data['replyToText'],
      replyToSenderId: data['replyToSenderId'],
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
      default:
        typeStr = 'text';
    }
    return {
      'senderId': senderId,
      if (text != null) 'text': text,
      if (audioUrl != null) 'audioUrl': audioUrl,
      if (audioDurationSeconds != null) 'audioDurationSeconds': audioDurationSeconds,
      if (imageUrl != null) 'imageUrl': imageUrl,
      if (replyToId != null) 'replyToId': replyToId,
      if (replyToText != null) 'replyToText': replyToText,
      if (replyToSenderId != null) 'replyToSenderId': replyToSenderId,
      'type': typeStr,
      'timestamp': Timestamp.fromDate(timestamp),
      'isEdited': isEdited,
    };
  }
}
