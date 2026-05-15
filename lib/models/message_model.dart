import 'package:cloud_firestore/cloud_firestore.dart';

enum MessageType { text, voice }

class MessageModel {
  final String id;
  final String senderId;
  final String? text;
  final String? audioUrl;
  final int? audioDurationSeconds;
  final MessageType type;
  final DateTime timestamp;
  final bool isEdited;

  MessageModel({
    required this.id,
    required this.senderId,
    this.text,
    this.audioUrl,
    this.audioDurationSeconds,
    required this.type,
    required this.timestamp,
    this.isEdited = false,
  });

  factory MessageModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return MessageModel(
      id: doc.id,
      senderId: data['senderId'] ?? '',
      text: data['text'],
      audioUrl: data['audioUrl'],
      audioDurationSeconds: data['audioDurationSeconds'],
      type: data['type'] == 'voice' ? MessageType.voice : MessageType.text,
      timestamp: (data['timestamp'] as Timestamp).toDate(),
      isEdited: data['isEdited'] ?? false,
    );
  }

  Map<String, dynamic> toFirestore() => {
        'senderId': senderId,
        if (text != null) 'text': text,
        if (audioUrl != null) 'audioUrl': audioUrl,
        if (audioDurationSeconds != null)
          'audioDurationSeconds': audioDurationSeconds,
        'type': type == MessageType.voice ? 'voice' : 'text',
        'timestamp': Timestamp.fromDate(timestamp),
        'isEdited': isEdited,
      };
}
