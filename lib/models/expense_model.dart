import 'package:cloud_firestore/cloud_firestore.dart';

class ExpenseModel {
  final String id;
  final String userId;
  final String dateKey; // YYYY-MM-DD
  final double amount;
  final String categoryId;
  final String description;
  final DateTime date;
  final DateTime createdAt;

  ExpenseModel({
    required this.id,
    required this.userId,
    required this.dateKey,
    required this.amount,
    required this.categoryId,
    required this.description,
    required this.date,
    required this.createdAt,
  });

  factory ExpenseModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ExpenseModel(
      id: doc.id,
      userId: data['userId'] ?? '',
      dateKey: data['dateKey'] ?? '',
      amount: (data['amount'] as num).toDouble(),
      categoryId: data['categoryId'] ?? 'others',
      description: data['description'] ?? '',
      date: (data['date'] as Timestamp).toDate(),
      createdAt: (data['createdAt'] as Timestamp).toDate(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'userId': userId,
      'dateKey': dateKey,
      'amount': amount,
      'categoryId': categoryId,
      'description': description,
      'date': Timestamp.fromDate(date),
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }

  ExpenseModel copyWith({
    double? amount,
    String? categoryId,
    String? description,
  }) {
    return ExpenseModel(
      id: id,
      userId: userId,
      dateKey: dateKey,
      amount: amount ?? this.amount,
      categoryId: categoryId ?? this.categoryId,
      description: description ?? this.description,
      date: date,
      createdAt: createdAt,
    );
  }

  static String dateToKey(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}

class CategorySummary {
  final String categoryId;
  final double total;
  final int count;

  CategorySummary({
    required this.categoryId,
    required this.total,
    required this.count,
  });
}
