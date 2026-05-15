import 'package:cloud_firestore/cloud_firestore.dart';

class UserProfileModel {
  final String uid;
  final String name;
  final String? password;
  final String? description; // chat alias shown to others
  final DateTime createdAt;
  final DateTime lastSeen;

  UserProfileModel({
    required this.uid,
    required this.name,
    this.password,
    this.description,
    required this.createdAt,
    required this.lastSeen,
  });

  factory UserProfileModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final createdAt = (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
    final lastSeen = (data['lastSeen'] as Timestamp?)?.toDate() ?? createdAt;
    return UserProfileModel(
      uid: doc.id,
      name: data['name'] as String? ?? 'Unknown',
      password: data['password'] as String?,
      description: data['description'] as String?,
      createdAt: createdAt,
      lastSeen: lastSeen,
    );
  }

  Map<String, dynamic> toFirestore() => {
        'name': name,
        'createdAt': Timestamp.fromDate(createdAt),
        'lastSeen': Timestamp.fromDate(lastSeen),
      };
}
