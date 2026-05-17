import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import '../main.dart' show navigatorKey;
import '../models/note_model.dart';
import '../models/expense_model.dart';
import '../models/user_profile_model.dart';
import '../models/call_model.dart';
import '../services/auth_service.dart';
import '../services/call_service.dart';
import '../services/chat_service.dart';
import '../services/notes_service.dart';
import '../services/expense_service.dart';
import '../services/notification_service.dart';
import '../screens/call_screen.dart';
import '../screens/incoming_call_screen.dart';

enum ExpenseViewMode { day, week, month, year, custom }

// Set to true while ChatListScreen is on screen so incoming calls
// auto-push IncomingCallScreen without requiring a notification tap.
class ChatListTracker {
  static bool isActive = false;
}

class AppProvider extends ChangeNotifier {
  final AuthService _authService = AuthService();
  final NotesService _notesService = NotesService();
  final ExpenseService _expenseService = ExpenseService();
  final ChatService _chatService = ChatService();
  final CallService _callService = CallService();

  StreamSubscription<QuerySnapshot>? _incomingCallSub;
  // Tracks callIds currently being shown in IncomingCallScreen to avoid duplicates
  final Set<String> _showingCallIds = {};

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
      _listenForIncomingCalls();
      _profile = await _chatService.getUserProfile(_userId!);
      unawaited(_saveFcmToken());
      _setupCallNotificationHandlers();
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

  // ── Incoming Call Listener ────────────────────────────────────────────────
  void _listenForIncomingCalls() {
    if (_userId == null) return;
    _incomingCallSub?.cancel();
    _incomingCallSub =
        _callService.incomingCallsFor(_userId!).listen((snap) async {
      for (final change in snap.docChanges) {
        if (change.type != DocumentChangeType.added) continue;
        if (_callService.isInCall) continue;

        final data = change.doc.data() as Map<String, dynamic>;
        final status = data['status'] as String?;
        if (status != 'ringing') continue;
        final callId = change.doc.id;
        final callerId = data['callerId'] as String;
        final isVideo = data['type'] == 'video';

        final caller = await _chatService.getUserProfile(callerId);
        if (caller == null) continue;

        // Always show a notification banner (visible on any screen)
        await NotificationService.showIncomingCallNotification(
          callerName: caller.name,
          callId: callId,
          callerId: callerId,
          isVideo: isVideo,
        );

        // If the user is already browsing the chat list, push IncomingCallScreen now
        if (ChatListTracker.isActive && !_showingCallIds.contains(callId)) {
          _showingCallIds.add(callId);
          navigatorKey.currentState?.push(MaterialPageRoute(
            builder: (_) => IncomingCallScreen(
              callId: callId,
              caller: caller,
              callType: isVideo ? CallType.video : CallType.voice,
              currentUid: _userId!,
            ),
          )).then((_) => _showingCallIds.remove(callId));
        }
      }
    });
  }

  // Called by ChatListScreen on open — finds any still-ringing call and pushes
  // IncomingCallScreen. Handles the case where the call arrived before the user
  // navigated to the chat list.
  Future<void> showPendingCallIfRinging() async {
    if (_callService.isInCall || _userId == null) return;
    final snap = await FirebaseFirestore.instance
        .collection('calls')
        .where('calleeId', isEqualTo: _userId)
        .where('status', isEqualTo: 'ringing')
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return;
    final doc = snap.docs.first;
    final callId = doc.id;
    if (_showingCallIds.contains(callId)) return;
    _showingCallIds.add(callId);

    final data = doc.data();
    final callerId = data['callerId'] as String;
    final isVideo = data['type'] == 'video';
    final caller = await _chatService.getUserProfile(callerId);
    if (caller == null) {
      _showingCallIds.remove(callId);
      return;
    }
    navigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => IncomingCallScreen(
        callId: callId,
        caller: caller,
        callType: isVideo ? CallType.video : CallType.voice,
        currentUid: _userId!,
      ),
    )).then((_) => _showingCallIds.remove(callId));
  }

  // ── Call notification handlers ────────────────────────────────────────────
  void _setupCallNotificationHandlers() {
    // Incoming call notification tap → pop everything back to the calendar home screen.
    // The user then navigates to the chat list where IncomingCallScreen auto-appears.
    NotificationService.onCallNotificationTap = (_) {
      navigatorKey.currentState?.popUntil((route) => route.isFirst);
    };

    // Ongoing call notification tap → return to active voice call
    NotificationService.onOngoingCallNotificationTap = _returnToActiveCall;

    // Background FCM tap → same: go to home screen
    FirebaseMessaging.onMessageOpenedApp.listen((msg) {
      if (msg.data['type'] == 'incoming_call') {
        navigatorKey.currentState?.popUntil((route) => route.isFirst);
      }
    });

    // Killed-state launch → open app at home; user navigates to chat list
    NotificationService.getCallLaunchData().then((_) {});
  }

  void _returnToActiveCall() {
    if (!_callService.isInCall) return;
    final otherUser = _callService.minimizedOtherUser;
    final callType = _callService.minimizedCallType;
    final currentUid = _callService.minimizedCurrentUid;
    final isOutgoing = _callService.minimizedIsOutgoing;
    final callId = _callService.activeCallId;
    if (otherUser == null || callType == null || currentUid == null ||
        isOutgoing == null || callId == null) return;
    navigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => CallScreen(
        callId: callId,
        isOutgoing: isOutgoing,
        callType: callType,
        otherUser: otherUser,
        currentUid: currentUid,
        isRestoring: true,
      ),
    ));
  }

  @override
  void dispose() {
    _notesSub?.cancel();
    _expensesSub?.cancel();
    _incomingCallSub?.cancel();
    super.dispose();
  }
}
