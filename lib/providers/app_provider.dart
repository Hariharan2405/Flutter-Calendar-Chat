import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import '../models/note_model.dart';
import '../models/expense_model.dart';
import '../models/user_profile_model.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/notes_service.dart';
import '../services/expense_service.dart';
import '../services/notification_service.dart';
import '../screens/chat_detail_screen.dart';

enum ExpenseViewMode { day, week, month, year, custom }

class AppProvider extends ChangeNotifier {
  final AuthService _authService = AuthService();
  final NotesService _notesService = NotesService();
  final ExpenseService _expenseService = ExpenseService();
  final ChatService _chatService = ChatService();

  StreamSubscription<QuerySnapshot>? _chatNotifSub;

  String? _userId;
  UserProfileModel? _profile;
  DateTime _selectedDate = DateTime.now();
  DateTime _focusedDate = DateTime.now();
  ExpenseViewMode _expenseViewMode = ExpenseViewMode.day;
  DateTime? _customStart;
  DateTime? _customEnd;

  List<NoteModel> _notesForSelectedDate = [];
  List<ExpenseModel> _expenses = [];
  Set<String> _datesWithNotes = {};
  Set<String> _datesWithExpenses = {};

  StreamSubscription<List<NoteModel>>? _notesSub;
  StreamSubscription<List<ExpenseModel>>? _expensesSub;

  bool _isLoading = true;
  String? _errorMessage;

  // ── Getters ──────────────────────────────────────────────────────────────────
  String? get userId => _userId;
  UserProfileModel? get profile => _profile;
  bool get profileReady => _profile != null;
  String? get errorMessage => _errorMessage;
  DateTime get selectedDate => _selectedDate;
  DateTime get focusedDate => _focusedDate;
  ExpenseViewMode get expenseViewMode => _expenseViewMode;
  DateTime? get customStart => _customStart;
  DateTime? get customEnd => _customEnd;
  List<NoteModel> get notesForSelectedDate => _notesForSelectedDate;
  List<ExpenseModel> get expenses => _expenses;
  Set<String> get datesWithNotes => _datesWithNotes;
  Set<String> get datesWithExpenses => _datesWithExpenses;
  bool get isLoading => _isLoading;

  double get totalExpenses => _expenses.fold(0, (s, e) => s + e.amount);
  List<CategorySummary> get categoryBreakdown =>
      ExpenseService.summarizeByCategory(_expenses);

  // ── Init ─────────────────────────────────────────────────────────────────────
  Future<void> initialize() async {
    try {
      _userId = await _authService.ensureSignedIn().timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw Exception(
          'Connection timed out.\n\nCheck that:\n'
          '• Anonymous Auth is enabled in Firebase Console\n'
          '• Firestore database has been created\n'
          '• Internet connection is available',
        ),
      );
      await _refreshMetadata();
      _subscribeNotes();
      _subscribeExpenses();
      _listenForChatNotifications();
      _profile = await _chatService.getUserProfile(_userId!);
      unawaited(_saveFcmToken());
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _isLoading = false;
      final msg = e.toString();
      if (msg.contains('permission-denied') || msg.contains('PERMISSION_DENIED')) {
        _errorMessage = 'Firestore permission denied.\n\n'
            'You need to update your Firestore security rules.\n'
            'See instructions below.';
      } else if (msg.contains('network') || msg.contains('unavailable')) {
        _errorMessage = 'Network error. Check your internet connection and try again.';
      } else {
        _errorMessage = msg.replaceFirst('Exception: ', '');
      }
      notifyListeners();
    }
  }

  Future<void> retryInitialize() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    await initialize();
  }

  Future<void> createProfile(String name, String password) async {
    if (_userId == null) return;
    await _chatService.saveUserProfile(_userId!, name, password);
    _profile = await _chatService.getUserProfile(_userId!);
    notifyListeners();
  }

  Future<void> loginWithExistingProfile(UserProfileModel existing) async {
    _profile = existing;
    notifyListeners();
    // Update FCM token on the existing profile doc so this device gets notifications
    final token = await NotificationService.getToken();
    if (token != null) {
      await FirebaseFirestore.instance
          .collection('user_profiles')
          .doc(existing.uid)
          .update({'fcmToken': token});
    }
  }

  Future<void> _refreshMetadata() async {
    _datesWithNotes = await _notesService.getDatesWithNotes(_userId!);
    _datesWithExpenses = await _expenseService.getDatesWithExpenses(_userId!);
    notifyListeners();
  }

  // ── Date selection ────────────────────────────────────────────────────────────
  void selectDate(DateTime date) {
    _selectedDate = date;
    _subscribeNotes();
    if (_expenseViewMode == ExpenseViewMode.day) {
      _subscribeExpenses();
    }
    notifyListeners();
  }

  void setFocusedDate(DateTime date) {
    _focusedDate = date;
    notifyListeners();
  }

  // ── Expense view mode ─────────────────────────────────────────────────────────
  void setExpenseViewMode(ExpenseViewMode mode) {
    _expenseViewMode = mode;
    _subscribeExpenses();
    notifyListeners();
  }

  void setCustomRange(DateTime start, DateTime end) {
    _customStart = start;
    _customEnd = end;
    _expenseViewMode = ExpenseViewMode.custom;
    _subscribeExpenses();
    notifyListeners();
  }

  DateTimeRange _rangeForMode() {
    final now = _selectedDate;
    switch (_expenseViewMode) {
      case ExpenseViewMode.day:
        return DateTimeRange(start: now, end: now);
      case ExpenseViewMode.week:
        final start = now.subtract(Duration(days: now.weekday - 1));
        final end = start.add(const Duration(days: 6));
        return DateTimeRange(start: start, end: end);
      case ExpenseViewMode.month:
        return DateTimeRange(
          start: DateTime(now.year, now.month, 1),
          end: DateTime(now.year, now.month + 1, 0),
        );
      case ExpenseViewMode.year:
        return DateTimeRange(
          start: DateTime(now.year, 1, 1),
          end: DateTime(now.year, 12, 31),
        );
      case ExpenseViewMode.custom:
        return DateTimeRange(
          start: _customStart ?? now,
          end: _customEnd ?? now,
        );
    }
  }

  // ── Notes subscription ────────────────────────────────────────────────────────
  void _subscribeNotes() {
    _notesSub?.cancel();
    if (_userId == null) return;
    final dateKey = NoteModel.dateToKey(_selectedDate);
    _notesSub = _notesService.notesForDate(_userId!, dateKey).listen((notes) {
      _notesForSelectedDate = notes;
      notifyListeners();
    });
  }

  // ── Expenses subscription ─────────────────────────────────────────────────────
  void _subscribeExpenses() {
    _expensesSub?.cancel();
    if (_userId == null) return;
    final range = _rangeForMode();
    _expensesSub = _expenseService
        .expensesInRange(_userId!, range.start, range.end)
        .listen((expenses) {
      _expenses = expenses;
      notifyListeners();
    });
  }

  // ── CRUD Notes ────────────────────────────────────────────────────────────────
  Future<void> addNote(String title, String content) async {
    await _notesService.addNote(
      userId: _userId!,
      date: _selectedDate,
      title: title,
      content: content,
    );
    await _refreshMetadata();
  }

  Future<void> updateNote(NoteModel note) async {
    await _notesService.updateNote(_userId!, note);
  }

  Future<void> deleteNote(String noteId) async {
    await _notesService.deleteNote(_userId!, noteId);
    await _refreshMetadata();
  }

  // ── CRUD Expenses ─────────────────────────────────────────────────────────────
  Future<void> addExpense({
    required double amount,
    required String categoryId,
    required String description,
    DateTime? date,
  }) async {
    await _expenseService.addExpense(
      userId: _userId!,
      date: date ?? _selectedDate,
      amount: amount,
      categoryId: categoryId,
      description: description,
    );
    await _refreshMetadata();
  }

  Future<void> updateExpense(ExpenseModel expense) async {
    await _expenseService.updateExpense(_userId!, expense);
  }

  Future<void> deleteExpense(String expenseId) async {
    await _expenseService.deleteExpense(_userId!, expenseId);
    await _refreshMetadata();
  }

  // ── FCM Token ─────────────────────────────────────────────────────────────
  Future<void> _saveFcmToken() async {
    if (_userId == null) return;
    final token = await NotificationService.getToken();
    if (token == null) return;
    final ref = FirebaseFirestore.instance.collection('user_profiles').doc(_userId);
    // Use update() so we never create a partial document for users who haven't
    // set their name yet — update() is a no-op (throws) if the doc doesn't exist.
    try {
      await ref.update({'fcmToken': token});
    } catch (_) {
      return; // Document doesn't exist yet — token will be saved after name setup
    }
    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
      ref.update({'fcmToken': newToken}).ignore();
    });
  }

  // ── Chat Notifications ────────────────────────────────────────────────────
  void _listenForChatNotifications() {
    if (_userId == null) return;
    _chatNotifSub?.cancel();
    _chatNotifSub = _chatService.allChatsFor(_userId!).listen((snapshot) {
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.modified) {
          final data = change.doc.data() as Map<String, dynamic>;
          final lastSenderId = data['lastSenderId'] as String?;
          final chatId = change.doc.id;
          // Notify only if: message is from someone else AND user is not in that chat
          if (lastSenderId != null &&
              lastSenderId != _userId &&
              ActiveChatTracker.activeChatId != chatId) {
            NotificationService.showNewMessage();
          }
        }
      }
    });
  }

  @override
  void dispose() {
    _notesSub?.cancel();
    _expensesSub?.cancel();
    _chatNotifSub?.cancel();
    super.dispose();
  }
}
