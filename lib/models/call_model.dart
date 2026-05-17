import 'package:cloud_firestore/cloud_firestore.dart';

enum CallType { voice, video }

enum CallStatus { ringing, answered, ended, declined }

class CallModel {
  final String id;
  final String callerId;
  final String calleeId;
  final CallType type;
  final CallStatus status;
  final DateTime createdAt;
  final Map<String, dynamic>? offer;
  final Map<String, dynamic>? answer;

  CallModel({
    required this.id,
    required this.callerId,
    required this.calleeId,
    required this.type,
    required this.status,
    required this.createdAt,
    this.offer,
    this.answer,
  });

  factory CallModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return CallModel(
      id: doc.id,
      callerId: data['callerId'] ?? '',
      calleeId: data['calleeId'] ?? '',
      type: data['type'] == 'video' ? CallType.video : CallType.voice,
      status: _parseStatus(data['status']),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      offer: data['offer'] as Map<String, dynamic>?,
      answer: data['answer'] as Map<String, dynamic>?,
    );
  }

  static CallStatus _parseStatus(String? s) {
    switch (s) {
      case 'answered':
        return CallStatus.answered;
      case 'ended':
        return CallStatus.ended;
      case 'declined':
        return CallStatus.declined;
      default:
        return CallStatus.ringing;
    }
  }
}
