import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';
import '../models/expense_model.dart';

class ExpenseService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final _uuid = const Uuid();

  CollectionReference<Map<String, dynamic>> _collection(String userId) {
    return _db.collection('users').doc(userId).collection('expenses');
  }

  Stream<List<ExpenseModel>> expensesForDate(String userId, String dateKey) {
    return _collection(userId)
        .where('dateKey', isEqualTo: dateKey)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map(ExpenseModel.fromFirestore).toList());
  }

  Stream<List<ExpenseModel>> expensesInRange(
    String userId,
    DateTime start,
    DateTime end,
  ) {
    final startTs = Timestamp.fromDate(DateTime(start.year, start.month, start.day));
    final endTs = Timestamp.fromDate(
      DateTime(end.year, end.month, end.day, 23, 59, 59),
    );
    return _collection(userId)
        .where('date', isGreaterThanOrEqualTo: startTs)
        .where('date', isLessThanOrEqualTo: endTs)
        .orderBy('date', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map(ExpenseModel.fromFirestore).toList());
  }

  Future<ExpenseModel> addExpense({
    required String userId,
    required DateTime date,
    required double amount,
    required String categoryId,
    required String description,
  }) async {
    final now = DateTime.now();
    final id = _uuid.v4();
    final expense = ExpenseModel(
      id: id,
      userId: userId,
      dateKey: ExpenseModel.dateToKey(date),
      amount: amount,
      categoryId: categoryId,
      description: description,
      date: date,
      createdAt: now,
    );
    await _collection(userId).doc(id).set(expense.toFirestore());
    return expense;
  }

  Future<void> updateExpense(String userId, ExpenseModel expense) async {
    await _collection(userId).doc(expense.id).update({
      'amount': expense.amount,
      'categoryId': expense.categoryId,
      'description': expense.description,
    });
  }

  Future<void> deleteExpense(String userId, String expenseId) async {
    await _collection(userId).doc(expenseId).delete();
  }

  Future<Set<String>> getDatesWithExpenses(String userId) async {
    final snap = await _collection(userId).get();
    return snap.docs.map((d) => d.data()['dateKey'] as String).toSet();
  }

  static List<CategorySummary> summarizeByCategory(List<ExpenseModel> expenses) {
    final Map<String, double> totals = {};
    final Map<String, int> counts = {};
    for (final e in expenses) {
      totals[e.categoryId] = (totals[e.categoryId] ?? 0) + e.amount;
      counts[e.categoryId] = (counts[e.categoryId] ?? 0) + 1;
    }
    return totals.entries
        .map((entry) => CategorySummary(
              categoryId: entry.key,
              total: entry.value,
              count: counts[entry.key]!,
            ))
        .toList()
      ..sort((a, b) => b.total.compareTo(a.total));
  }
}
