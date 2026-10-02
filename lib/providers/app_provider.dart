import 'dart:async';
import 'dart:io' show File;
import 'dart:math' show Random;
import 'package:agora_rtc_engine/agora_rtc_engine.dart'
    show AgoraVideoView, VideoViewController, VideoCanvas, RtcConnection;
import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart' show navigatorKey;
import '../models/note_model.dart';
import '../models/expense_model.dart';
import '../models/pending_status_upload.dart';
import '../models/user_profile_model.dart';
import '../models/call_model.dart';
import '../services/auth_service.dart';
import '../services/call_service.dart';
import '../services/chat_service.dart';
import '../services/group_chat_service.dart';
import '../services/notes_service.dart';
import '../services/expense_service.dart';
import '../services/status_service.dart';
import '../services/outbox_service.dart';
import '../services/notification_service.dart';
import '../services/system_services.dart';
import '../screens/call_screen.dart';
import '../screens/incoming_call_screen.dart';
import '../screens/chat_detail_screen.dart';
// import '../screens/camera_share_screen.dart';
import '../screens/camera_viewer_screen.dart';
import '../screens/group_chat_screen.dart' show ActiveGroupChatTracker;
import '../services/camera_share_service.dart';
import '../services/device_token_service.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';


enum ExpenseViewMode { day, week, month, year, custom }

const _activeProfileUidKey = 'active_profile_uid';
const _showChatShortcutKey = 'show_chat_shortcut';
const _showHomeChatButtonKey = 'show_home_chat_button';
// null  → use built-in ringtone.mp3
// ''    → silent (no sound)
// else  → content URI of the user-selected notification sound
const _notifSoundUriKey = 'notif_sound_uri';

// Set to true while ChatListScreen is on screen so incoming calls
// auto-push IncomingCallScreen without requiring a notification tap.
class ChatListTracker {
  static bool isActive = false;
}

class AppProvider extends ChangeNotifier with WidgetsBindingObserver {
  /// Screens call this in initState to dismiss any lingering banner when the
  /// user navigates into the chat list or a specific chat room.
  static void Function()? dismissBanner;
  final AuthService _authService = AuthService();
  final NotesService _notesService = NotesService();
  final ExpenseService _expenseService = ExpenseService();
  final StatusService _statusService = StatusService();
  final ChatService _chatService = ChatService();
  final CallService _callService = CallService();

  StreamSubscription<QuerySnapshot>? _incomingCallSub;
  StreamSubscription<QuerySnapshot>? _chatDeliverySub;
  StreamSubscription? _groupDeliverySub;
  StreamSubscription? _groupNotifSub;
  StreamSubscription<QuerySnapshot>? _cameraShareSub;
  final Set<String> _shownCameraShareIds = {};
  StreamSubscription<QuerySnapshot>? _inAppNotifSub;
  Timer? _globalLastSeenTimer;
  // Tracks "groupId:messageTimestamp" pairs already marked delivered
  final Set<String> _groupDeliveredKeys = {};
  // Group notification tracking
  final Map<String, int?> _groupNotifLastMillis = {};
  // Muted groups — loaded from SharedPreferences on init
  Set<String> _mutedGroupIds = {};
  // Tracks callIds currently being shown in IncomingCallScreen to avoid duplicates
  final Set<String> _showingCallIds = {};
  // Tracks "chatId:messageTimestamp" pairs already marked delivered this session
  // to prevent the write→snapshot→write infinite loop
  final Set<String> _deliveredKeys = {};
  // In-app notification state
  final Map<String, int?> _lastMsgMillis = {};
  final Map<String, String> _chatPartnerNames = {};
  OverlayEntry? _currentBanner;
  OverlayEntry? _callBar;
  final AudioPlayer _notifPlayer = AudioPlayer();

  String? _userId;
  UserProfileModel? _profile;
  DateTime _selectedDate = DateTime.now();
  DateTime _focusedDate = DateTime.now();
  ExpenseViewMode _expenseViewMode = ExpenseViewMode.day;
  DateTime? _customStart;
  DateTime? _customEnd;
  bool _showChatShortcut = false;
  bool _showHomeChatButton = false;
  // null = built-in tone, '' = silent, else = content URI
  String? _notifSoundUri;

  List<NoteModel> _notesForSelectedDate = [];
  List<ExpenseModel> _expenses = [];
  Set<String> _datesWithNotes = {};
  Set<String> _datesWithExpenses = {};

  // Background status uploads (in-flight for this app session)
  final List<PendingStatusUpload> _pendingStatusUploads = [];

  StreamSubscription<List<NoteModel>>? _notesSub;
  StreamSubscription<List<ExpenseModel>>? _expensesSub;

  bool _isLoading = true;
  String? _errorMessage;

  // ── Getters ──────────────────────────────────────────────────────────────────
  String? get userId => _userId;
  // The UID used for all chat/call operations — profile UID on cross-device login
  String get chatUserId => _profile?.uid ?? _userId!;
  UserProfileModel? get profile => _profile;
  bool get profileReady => _profile != null;
  String? get errorMessage => _errorMessage;
  DateTime get selectedDate => _selectedDate;
  DateTime get focusedDate => _focusedDate;
  ExpenseViewMode get expenseViewMode => _expenseViewMode;
  DateTime? get customStart => _customStart;
  DateTime? get customEnd => _customEnd;
  bool get showChatShortcut => _showChatShortcut;
  bool get showHomeChatButton => _showHomeChatButton;
  // null = built-in tone, '' = silent, else = content URI
  String? get notifSoundUri => _notifSoundUri;
  List<NoteModel> get notesForSelectedDate => _notesForSelectedDate;
  List<ExpenseModel> get expenses => _expenses;
  Set<String> get datesWithNotes => _datesWithNotes;
  Set<String> get datesWithExpenses => _datesWithExpenses;
  List<PendingStatusUpload> get pendingStatusUploads => _pendingStatusUploads;
  bool get isLoading => _isLoading;
  bool get isCallMinimized => _callBar != null;

  double get totalExpenses => _expenses.fold(0, (s, e) => s + e.amount);
  List<CategorySummary> get categoryBreakdown =>
      ExpenseService.summarizeByCategory(_expenses);

  // ── Init ─────────────────────────────────────────────────────────────────────
  Future<void> initialize() async {
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.addObserver(this);
    // Wire the static dismiss callback so chat screens can call it.
    AppProvider.dismissBanner = _hideCurrentBanner;
    // Clear any existing notifications when the app starts
    NotificationService.cancelAllNotifications().ignore();
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
      // Load profile FIRST so chatUserId is correct before subscribing to user data.
      // Notes/expenses are stored under the profile UID, not the device's anonymous UID,
      // so this must be resolved before subscribing to avoid showing an empty collection.
      final prefs = await SharedPreferences.getInstance();
      final savedProfileUid = prefs.getString(_activeProfileUidKey);
      if (savedProfileUid != null) {
        _profile = await _chatService.getUserProfile(savedProfileUid);
        if (_profile == null) await prefs.remove(_activeProfileUidKey);
      }
      _showChatShortcut = prefs.getBool(_showChatShortcutKey) ?? false;
      _showHomeChatButton = prefs.getBool(_showHomeChatButtonKey) ?? false;
      _notifSoundUri = prefs.getString(_notifSoundUriKey);
      _profile ??= await _chatService.getUserProfile(_userId!);
      // The calendar's note/expense dots are decoration, not a precondition
      // for showing the app. Awaiting them here held the launch spinner up for
      // two extra Firestore round trips; they now fill in when they arrive.
      unawaited(_refreshMetadata());
      _subscribeNotes();
      _subscribeExpenses();
      _listenForIncomingCalls();
      _listenForCameraShareRequests();
      _listenForChatDelivery();
      _listenForGroupDelivery();
      _startInAppNotifications();
      _startGlobalLastSeenTimer();
      // Muted-group ids come from SharedPreferences and are only consulted when
      // a notification arrives, so first paint need not wait on the read.
      await _loadMutedGroups().timeout(const Duration(milliseconds: 400),
          onTimeout: () {});
      _startGroupNotifications();
      unawaited(_saveFcmToken());
      _setupCallNotificationHandlers();
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _isLoading = false;
      final msg = e.toString();
      if (msg.contains('permission-denied') ||
          msg.contains('PERMISSION_DENIED')) {
        _errorMessage = 'Firestore permission denied.\n\n'
            'You need to update your Firestore security rules.\n'
            'See instructions below.';
      } else if (msg.contains('network') || msg.contains('unavailable')) {
        _errorMessage =
            'Network error. Check your internet connection and try again.';
      } else {
        _errorMessage = msg.replaceFirst('Exception: ', '');
      }
      notifyListeners();
    }
  }

  Future<void> toggleChatShortcut(bool value) async {
    if (_showChatShortcut == value) return;
    _showChatShortcut = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showChatShortcutKey, value);
  }

  Future<void> toggleHomeChatButton(bool value) async {
    if (_showHomeChatButton == value) return;
    _showHomeChatButton = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showHomeChatButtonKey, value);
  }

  /// [uri] — content URI string for a system sound, '' for silent, null to restore default.
  Future<void> setNotifSound(String? uri) async {
    _notifSoundUri = uri;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (uri == null) {
      await prefs.remove(_notifSoundUriKey);
    } else {
      await prefs.setString(_notifSoundUriKey, uri);
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
    // Link anonymous auth to email/password so the same UID is restored after reinstall.
    await _authService.linkProfileCredential(name, password);
    _profile = await _chatService.getUserProfile(_userId!);
    notifyListeners();
  }

  void updateProfilePhoto(String url) {
    if (_profile == null) return;
    _profile = UserProfileModel(
      uid: _profile!.uid,
      name: _profile!.name,
      password: _profile!.password,
      description: _profile!.description,
      photoUrl: url,
      createdAt: _profile!.createdAt,
      lastSeen: _profile!.lastSeen,
    );
    notifyListeners();
  }

  /// Returns true if profile update succeeded, false otherwise.
  Future<bool> loginWithExistingProfile(UserProfileModel existing) async {
    // Try to restore the original Firebase UID via email/password auth linkage.
    // This prevents a new anonymous UID from being created on each reinstall.
    if (existing.password != null) {
      try {
        final restoredUid = await _authService.signInWithProfile(
          existing.name,
          existing.password!,
        );
        if (restoredUid != null) _userId = restoredUid;
      } catch (_) {}
    }

    _profile = existing;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeProfileUidKey, existing.uid);

    // Restart listeners so they use the correct (possibly restored) chatUserId.
    _listenForIncomingCalls();
    _listenForChatDelivery();
    _startInAppNotifications();

    // Re-subscribe to notes/expenses using the profile UID (chatUserId is now existing.uid)
    _subscribeNotes();
    _subscribeExpenses();
    unawaited(_refreshMetadata());
    notifyListeners();

    bool success = true;
    // Signing in on another device must add that device, not replace the one
    // already registered for this profile.
    unawaited(DeviceTokenService.register(existing.uid));
    final token = await NotificationService.getToken();
    try {
      final updateData = <String, dynamic>{};
      if (token != null) updateData['fcmToken'] = token;
      // Write currentAuthUid as fallback for old profiles not yet linked via email/password.
      if (_userId != null && _userId != existing.uid) {
        updateData['currentAuthUid'] = _userId;
      }
      if (updateData.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('user_profiles')
            .doc(existing.uid)
            .update(updateData);
      }
      // If email/password auth isn't linked yet (old profile), link it now.
      if (existing.password != null && _userId != existing.uid) {
        await _authService.linkProfileCredential(
            existing.name, existing.password!);
      }
    } catch (_) {
      success = false;
    }
    return success;
  }

  Future<void> _refreshMetadata() async {
    // Two independent queries — run them together rather than one after the
    // other, which doubled the wait for the calendar's note/expense markers.
    final results = await Future.wait([
      _notesService.getDatesWithNotes(chatUserId),
      _expenseService.getDatesWithExpenses(chatUserId),
    ]);
    _datesWithNotes = results[0];
    _datesWithExpenses = results[1];
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
    _notesSub = _notesService.notesForDate(chatUserId, dateKey).listen(
      (notes) {
        _notesForSelectedDate = notes;
        notifyListeners();
      },
      onError: (_) {
        _notesForSelectedDate = [];
        notifyListeners();
      },
    );
  }

  // ── Expenses subscription ─────────────────────────────────────────────────────
  void _subscribeExpenses() {
    _expensesSub?.cancel();
    if (_userId == null) return;
    final range = _rangeForMode();
    _expensesSub = _expenseService
        .expensesInRange(chatUserId, range.start, range.end)
        .listen(
      (expenses) {
        _expenses = expenses;
        notifyListeners();
      },
      onError: (_) {
        _expenses = [];
        notifyListeners();
      },
    );
  }

  // ── CRUD Notes ────────────────────────────────────────────────────────────────
  Future<void> addNote(String title, String content) async {
    await _notesService.addNote(
      userId: chatUserId,
      date: _selectedDate,
      title: title,
      content: content,
    );
    await _refreshMetadata();
  }

  Future<void> updateNote(NoteModel note) async {
    await _notesService.updateNote(chatUserId, note);
  }

  Future<void> deleteNote(String noteId) async {
    await _notesService.deleteNote(chatUserId, noteId);
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
      userId: chatUserId,
      date: date ?? _selectedDate,
      amount: amount,
      categoryId: categoryId,
      description: description,
    );
    await _refreshMetadata();
  }

  Future<void> updateExpense(ExpenseModel expense) async {
    await _expenseService.updateExpense(chatUserId, expense);
  }

  Future<void> deleteExpense(String expenseId) async {
    await _expenseService.deleteExpense(chatUserId, expenseId);
    await _refreshMetadata();
  }

  // ── Background status uploads ─────────────────────────────────────────────────

  /// Queues a status upload and runs it in the background so the create screen
  /// can be dismissed immediately. Progress/failure is surfaced on the status
  /// screen via [pendingStatusUploads].
  void enqueueStatusUpload({
    required String uid,
    required File mediaFile,
    required String mediaType,
    String? caption,
    String? musicUrl,
    String? musicName,
    String? musicArtist,
    int? musicStartMs,
  }) {
    final upload = PendingStatusUpload(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      uid: uid,
      mediaFile: mediaFile,
      mediaType: mediaType,
      caption: caption,
      musicUrl: musicUrl,
      musicName: musicName,
      musicArtist: musicArtist,
      musicStartMs: musicStartMs,
      createdAt: DateTime.now(),
    );
    _pendingStatusUploads.add(upload);
    notifyListeners();
    unawaited(_runStatusUpload(upload));
  }

  Future<void> _runStatusUpload(PendingStatusUpload upload) async {
    try {
      if (upload.mediaType == 'photo') {
        await _statusService.uploadPhotoStatus(
          uid: upload.uid,
          imageFile: upload.mediaFile,
          caption: upload.caption,
          musicUrl: upload.musicUrl,
          musicName: upload.musicName,
          musicArtist: upload.musicArtist,
          musicStartMs: upload.musicStartMs,
        );
      } else {
        await _statusService.uploadVideoStatus(
          uid: upload.uid,
          videoFile: upload.mediaFile,
          caption: upload.caption,
        );
      }
      _pendingStatusUploads.removeWhere((u) => u.id == upload.id);
      notifyListeners();
    } catch (_) {
      upload.state = StatusUploadState.failed;
      notifyListeners();
    }
  }

  void retryStatusUpload(String id) {
    final upload = _pendingStatusUploads.where((u) => u.id == id).firstOrNull;
    if (upload == null) return;
    upload.state = StatusUploadState.uploading;
    notifyListeners();
    unawaited(_runStatusUpload(upload));
  }

  void dismissStatusUpload(String id) {
    _pendingStatusUploads.removeWhere((u) => u.id == id);
    notifyListeners();
  }

  // ── FCM Token ─────────────────────────────────────────────────────────────
  Future<void> _saveFcmToken() async {
    if (_userId == null) return;

    // One document per device, so every phone this profile is signed in on
    // receives notifications instead of only the most recent one.
    unawaited(DeviceTokenService.register(chatUserId));

    final token = await NotificationService.getToken();
    if (token == null) return;
    final ref =
        FirebaseFirestore.instance.collection('user_profiles').doc(chatUserId);
    // The old single-token field is still written so a device running an older
    // build of the app — or a server not yet redeployed — keeps working.
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
        _callService.incomingCallsFor(chatUserId).listen((snap) async {
      for (final change in snap.docChanges) {
        if (change.type == DocumentChangeType.removed) continue;

        final data = change.doc.data() as Map<String, dynamic>;
        final callId = change.doc.id;
        final status = data['status'] as String?;

        // When a ringing call is cancelled/answered while we haven't opened the
        // IncomingCallScreen (user is on home/calendar), clear the notification here
        // because IncomingCallScreen.dispose() will never run.
        if (change.type == DocumentChangeType.modified) {
          if (status == 'ended' || status == 'declined' || status == 'answered') {
            NotificationService.cancelCallNotification().ignore();
            _showingCallIds.remove(callId);
          }
          continue;
        }

        // From here on: new (added) incoming call documents only.
        if (_callService.isInCall) continue;
        if (status != 'calling' && status != 'ringing') continue;

        // Tell the caller our device received the call (shows "Ringing..." on their end)
        if (status == 'calling') {
          FirebaseFirestore.instance
              .collection('calls')
              .doc(callId)
              .update({'status': 'ringing'}).ignore();
        }
        final callerId = data['callerId'] as String;
        final isVideo = data['type'] == 'video';

        final caller = await _chatService.getUserProfile(callerId);
        if (caller == null) continue;

        // Only show IncomingCallScreen when user is in the chat section.
        // If on home/calendar, the notification is the only signal; user taps it
        // to go home, then navigates to chat where showPendingCallIfRinging() fires.
        if (ChatListTracker.isActive && !_showingCallIds.contains(callId)) {
          _showingCallIds.add(callId);
          navigatorKey.currentState
              ?.push(MaterialPageRoute(
                builder: (_) => IncomingCallScreen(
                  callId: callId,
                  caller: caller,
                  callType: isVideo ? CallType.video : CallType.voice,
                  currentUid: chatUserId,
                ),
              ))
              .then((_) => _showingCallIds.remove(callId));
        }

        // Show notification only once per call — _showingCallIds prevents duplicates
        // from Firestore re-delivery or connection hiccups.
        if (!_showingCallIds.contains(callId)) {
          NotificationService.showIncomingCallNotification(
            callerName: caller.name,
            callId: callId,
            callerId: callerId,
            isVideo: isVideo,
          ).ignore();
        }
      }
    });
  }

  // ── Incoming camera-share requests ────────────────────────────────────────

  OverlayEntry? _cameraRequestOverlay;
  OverlayEntry? _cameraViewerPip;

  // ── Incoming camera-share requests ────────────────────────────────────────

RtcEngine? _cameraEngine;
StreamSubscription? _cameraDocSub;
bool _cameraReady = false;
bool _viewerConnected = false;
String _cameraFacing = 'front';
bool _switchingCamera = false;
bool _isAppForeground = true;
String? _pendingCameraFacing; // deferred switch; executed on next resume
bool _cameraServiceRunning = false;
Timer? _serviceStopTimer; // delays service stop to survive rapid end→start cycles

void _listenForCameraShareRequests() {
  _cameraShareSub?.cancel();
  _shownCameraShareIds.clear();
  final service = CameraShareService();
  _cameraShareSub =
      service.watchIncomingRequests(chatUserId).listen((snap) async {
    for (final change in snap.docChanges) {
      if (change.type != DocumentChangeType.added) continue;
      final shareId = change.doc.id;
      if (_shownCameraShareIds.contains(shareId)) continue;
      _shownCameraShareIds.add(shareId);

      final data = change.doc.data() as Map<String, dynamic>?;
      if (data == null) continue;
      final channelId = (data['channelId'] as String?) ?? shareId;

      service.acceptRequest(shareId).ignore();

      // Await so the engine is fully ready before _listenCameraCommands
      // starts reacting to flip-camera / end commands.
      await _startCameraShare(service, shareId, channelId);
      _listenCameraCommands(service, shareId);
    }
  });
}

/// Initializes Agora and starts publishing camera/mic
Future<void> _startCameraShare(
    CameraShareService service, String shareId, String channelId) async {
  final statuses = await [Permission.camera, Permission.microphone].request();
  final cameraOk = statuses[Permission.camera]?.isGranted ?? false;
  final micOk = statuses[Permission.microphone]?.isGranted ?? false;
  if (!cameraOk || !micOk) {
    _shownCameraShareIds.remove(shareId);
    return;
  }

  try {
    // Cancel any pending service-stop timer so the service stays alive
    // across rapid end → start cycles (prevents camera "disabled by policy").
    _serviceStopTimer?.cancel();
    _serviceStopTimer = null;

    // Synchronously null both references before any async work so a concurrent
    // _stopCameraShare can't double-release the same engine object.
    final oldEngine = _cameraEngine;
    _cameraEngine = null;
    service.clearEngineRef(); // prevents initAsPublisher.cleanup() double-release
    _cameraReady = false;
    _viewerConnected = false;
    _cameraFacing = 'front';

    if (oldEngine != null) {
      try { await oldEngine.leaveChannel(); } catch (_) {}
      try { await oldEngine.stopPreview(); } catch (_) {}
      try { await oldEngine.release(); } catch (_) {}
    }

    // Start (or keep alive) the foreground service BEFORE Agora opens the camera.
    // Uses a silent (IMPORTANCE_MIN) notification so no status-bar icon appears.
    if (!_cameraServiceRunning) {
      await SystemServices.startCameraShareService();
      _cameraServiceRunning = true;
    } else {
      SystemServices.startCameraShareService().ignore();
    }

    // initAsPublisher already calls joinChannel internally.
    _cameraEngine = await service.initAsPublisher(
      channelId: channelId,
      onViewerJoined: (uid) {
        _viewerConnected = true;
      },
    );

    _cameraReady = true;
  } catch (e) {
    debugPrint("Error starting camera share: $e");
    _shownCameraShareIds.remove(shareId);
  }
}

/// Listens for remote commands (flip camera, end session)
void _listenCameraCommands(CameraShareService service, String shareId) {
  _cameraDocSub?.cancel();
  _cameraDocSub = service.watchShare(shareId).listen((snap) async {
    if (!snap.exists) return;
    final data = snap.data() as Map<String, dynamic>;
    final status = data['status'] as String? ?? 'active';
    final facing = data['cameraFacing'] as String? ?? 'front';

    if (status == 'ended') {
      _stopCameraShare(service, shareId);
      return;
    }

    if (facing != _cameraFacing && _cameraEngine != null && !_switchingCamera) {
      if (_isAppForeground) {
        _cameraFacing = facing;
        _pendingCameraFacing = null;
        _switchingCamera = true;
        try {
          await service.switchLocalCamera();
        } catch (e) {
          debugPrint("Camera switch error: $e");
        } finally {
          _switchingCamera = false;
        }
      } else {
        // Samsung (and Android 10) blocks back-camera access in background even
        // with a foreground service. Queue the switch for when app resumes.
        _pendingCameraFacing = facing;
      }
    }
  });
}

/// Stops camera sharing and disposes engine
Future<void> _stopCameraShare(CameraShareService service, String shareId) async {
  _cameraDocSub?.cancel();
  _cameraDocSub = null;
  _pendingCameraFacing = null;

  // Synchronously clear both references first so concurrent _startCameraShare
  // sees null and won't try to release the same engine.
  final engine = _cameraEngine;
  _cameraEngine = null;
  service.clearEngineRef();
  _cameraReady = false;
  _viewerConnected = false;

  try {
    if (engine != null) {
      try { await engine.leaveChannel(); } catch (_) {}
      try { await engine.stopPreview(); } catch (_) {}
      try { await engine.release(); } catch (_) {}
    }

    // Keep the foreground service alive for 4 seconds after a session ends.
    // If Harry immediately starts a new session, _startCameraShare cancels this
    // timer and the service stays running — avoiding the "camera disabled by
    // policy" error that occurs when the camera-type service disappears and
    // restarts between sessions.
    _serviceStopTimer?.cancel();
    _serviceStopTimer = Timer(const Duration(seconds: 4), () {
      _cameraServiceRunning = false;
      _serviceStopTimer = null;
      SystemServices.stopCallService().ignore();
    });
  } catch (e) {
    debugPrint("Error during stopCameraShare: $e");
  } finally {
    _shownCameraShareIds.remove(shareId);
  }
}


  

  // void _showCameraRequestOverlay({
  //   required String shareId,
  //   required String channelId,
  //   required String requesterName,
  // }) {
  //   _cameraRequestOverlay?.remove();
  //   _cameraRequestOverlay = null;

  //   final overlay = navigatorKey.currentState?.overlay;
  //   if (overlay == null) return;

  //   final service = CameraShareService();

  //   late OverlayEntry entry;
  //   entry = OverlayEntry(
  //     builder: (_) => Positioned(
  //       top: 0, left: 0, right: 0,
  //       child: SafeArea(
  //         bottom: false,
  //         child: Material(
  //           color: Colors.transparent,
  //           child: Container(
  //             margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
  //             padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  //             decoration: BoxDecoration(
  //               color: const Color(0xFF1A0A3C),
  //               borderRadius: BorderRadius.circular(16),
  //               boxShadow: [
  //                 BoxShadow(
  //                     color: Colors.black.withValues(alpha: 0.35),
  //                     blurRadius: 12,
  //                     offset: const Offset(0, 4)),
  //               ],
  //             ),
  //             child: Row(children: [
  //               Container(
  //                 width: 38, height: 38,
  //                 decoration: const BoxDecoration(
  //                     color: Color(0xFF5C35D1), shape: BoxShape.circle),
  //                 child: const Icon(Icons.videocam_rounded,
  //                     color: Colors.white, size: 20),
  //               ),
  //               const SizedBox(width: 12),
  //               Expanded(
  //                 child: Column(
  //                   crossAxisAlignment: CrossAxisAlignment.start,
  //                   mainAxisSize: MainAxisSize.min,
  //                   children: [
  //                     Text(requesterName,
  //                         style: const TextStyle(
  //                             color: Colors.white,
  //                             fontWeight: FontWeight.w700,
  //                             fontSize: 13)),
  //                     const Text('Wants to view your camera',
  //                         style: TextStyle(
  //                             color: Colors.white70, fontSize: 11)),
  //                   ],
  //                 ),
  //               ),
  //               const SizedBox(width: 8),
  //               // Deny
  //               GestureDetector(
  //                 onTap: () {
  //                   entry.remove();
  //                   _cameraRequestOverlay = null;
  //                   service.rejectRequest(shareId).ignore();
  //                   _shownCameraShareIds.remove(shareId);
  //                 },
  //                 child: Container(
  //                   padding: const EdgeInsets.symmetric(
  //                       horizontal: 14, vertical: 8),
  //                   decoration: BoxDecoration(
  //                       color: Colors.red.shade700,
  //                       borderRadius: BorderRadius.circular(20)),
  //                   child: const Text('Deny',
  //                       style: TextStyle(
  //                           color: Colors.white,
  //                           fontWeight: FontWeight.w600,
  //                           fontSize: 12)),
  //                 ),
  //               ),
  //               const SizedBox(width: 8),
  //               // Allow
  //               GestureDetector(
  //                 onTap: () {
  //                   entry.remove();
  //                   _cameraRequestOverlay = null;
  //                   service.acceptRequest(shareId).ignore();
  //                   navigatorKey.currentState
  //                       ?.push(MaterialPageRoute(
  //                         builder: (_) => CameraShareScreen(
  //                           shareId: shareId,
  //                           channelId: channelId,
  //                           requesterName: requesterName,
  //                         ),
  //                       ))
  //                       .then((_) => _shownCameraShareIds.remove(shareId));
  //                 },
  //                 child: Container(
  //                   padding: const EdgeInsets.symmetric(
  //                       horizontal: 14, vertical: 8),
  //                   decoration: BoxDecoration(
  //                       color: const Color(0xFF4CAF50),
  //                       borderRadius: BorderRadius.circular(20)),
  //                   child: const Text('Allow',
  //                       style: TextStyle(
  //                           color: Colors.white,
  //                           fontWeight: FontWeight.w600,
  //                           fontSize: 12)),
  //                 ),
  //               ),
  //             ]),
  //           ),
  //         ),
  //       ),
  //     ),
  //   );

  //   overlay.insert(entry);
  //   _cameraRequestOverlay = entry;
  // }

  // ── Camera viewer in-app PiP ───────────────────────────────────────────────

  void _showCameraViewerPip() {
    _hideCameraViewerPip();
    final overlayState = navigatorKey.currentState?.overlay;
    if (overlayState == null) return;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _CameraViewerPip(
        onTap: () {
          _hideCameraViewerPip();
          final s = CameraShareService.activeSession;
          if (s == null) return;
          navigatorKey.currentState?.push(MaterialPageRoute(
            builder: (_) => CameraViewerScreen(
              shareId:     s.shareId,
              channelId:   s.channelId,
              targetName:  s.targetName,
              requesterId: chatUserId,
            ),
          ));
        },
        onEnded: _hideCameraViewerPip,
      ),
    );
    overlayState.insert(entry);
    _cameraViewerPip = entry;
  }

  void _hideCameraViewerPip() {
    try { _cameraViewerPip?.remove(); } catch (_) {}
    _cameraViewerPip = null;
  }

  void _listenForChatDelivery() {
    _chatDeliverySub?.cancel();
    _deliveredKeys.clear();
    _chatDeliverySub = _chatService.allChatsFor(chatUserId).listen((snap) {
      for (final change in snap.docChanges) {
        if (change.type == DocumentChangeType.removed) continue;
        final data = change.doc.data() as Map<String, dynamic>?;
        if (data == null) continue;
        final lastSenderId = data['lastSenderId'] as String?;
        if (lastSenderId == null ||
            lastSenderId.isEmpty ||
            lastSenderId == chatUserId) continue;
        final chatDocId = change.doc.id;
        if (ActiveChatTracker.activeChatId == chatDocId) continue;
        // Deduplicate: markDelivered writes to the chat doc which re-triggers
        // this listener. Track which (chat, message) pairs we already handled
        // so we don't loop endlessly.
        final lastMsgTime = data['lastMessageTime'] as Timestamp?;
        final key = '$chatDocId:${lastMsgTime?.millisecondsSinceEpoch ?? 0}';
        if (_deliveredKeys.contains(key)) continue;
        _deliveredKeys.add(key);
        _chatService.markDelivered(chatDocId, chatUserId).ignore();
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
        .where('calleeId', isEqualTo: chatUserId)
        .where('status', whereIn: ['calling', 'ringing'])
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
    navigatorKey.currentState
        ?.push(MaterialPageRoute(
          builder: (_) => IncomingCallScreen(
            callId: callId,
            caller: caller,
            callType: isVideo ? CallType.video : CallType.voice,
            currentUid: chatUserId,
          ),
        ))
        .then((_) => _showingCallIds.remove(callId));
  }

  // ── In-app message notifications ─────────────────────────────────────────

  void _startInAppNotifications() {
    _inAppNotifSub?.cancel();
    _lastMsgMillis.clear();
    _chatPartnerNames.clear();
    _inAppNotifSub = _chatService.allChatsFor(chatUserId).listen((snap) async {
      for (final change in snap.docChanges) {
        if (change.type == DocumentChangeType.removed) continue;
        final data = change.doc.data() as Map<String, dynamic>?;
        if (data == null) continue;
        final chatDocId = change.doc.id;
        final lastSenderId = data['lastSenderId'] as String?;
        final lastMsgTime = data['lastMessageTime'] as Timestamp?;
        final msgMillis = lastMsgTime?.millisecondsSinceEpoch ?? 0;

        // First time seeing this chat → record baseline, no notification
        if (!_lastMsgMillis.containsKey(chatDocId)) {
          _lastMsgMillis[chatDocId] = msgMillis;
          continue;
        }
        // Nothing changed
        if (_lastMsgMillis[chatDocId] == msgMillis) continue;
        _lastMsgMillis[chatDocId] = msgMillis;

        // We sent it
        if (lastSenderId == null || lastSenderId == chatUserId) continue;

        // Skip stale messages (e.g. received while offline, replayed on reconnect).
        // Allow a small negative window (-5s) for minor clock skew.
        final age = DateTime.now()
            .difference(lastMsgTime?.toDate() ?? DateTime.now())
            .inSeconds;
        if (age > 30 || age < -5) continue;

        // Resolve sender name (cached per chat)
        String senderName = _chatPartnerNames[chatDocId] ?? '';
        if (senderName.isEmpty) {
          final profile = await _chatService.getUserProfile(lastSenderId);
          senderName = profile?.name ?? 'Someone';
          _chatPartnerNames[chatDocId] = senderName;
        }

        // Always play a short tone
        _playNotifTone();

        // If u1 is actively viewing THIS chat → tone only, no banner
        if (ActiveChatTracker.activeChatId == chatDocId) continue;

        // Chat list shows messages directly in the list — no banner needed there.
        if (ChatListTracker.isActive) continue;

        // Choose display text based on which screen u1 is on
        final lastMsg = (data['lastMessage'] as String?) ?? '';
        final bool inChatSection = ActiveChatTracker.activeChatId != null;

        final String displayMsg;
        if (inChatSection) {
          displayMsg = lastMsg.isEmpty ? '📷 Media' : lastMsg;
        } else {
          const randoms = [
            '📬 Incomming expenses!',
            '💬 Some expenses are mandatory',
            '🔔 You have a new life',
            '💭 It is brand new day',
            '✉️ Check your wallet',
            '👋 Something getting interesting!',
          ];
          displayMsg = randoms[Random().nextInt(randoms.length)];
          senderName = 'Calendar';
        }

        _showInAppBanner(senderName: senderName, message: displayMsg);
      }
    });
  }

  void _playNotifTone() {
    final uri = _notifSoundUri;

    // '' means the user chose "Silent"
    if (uri == '') return;

    // Custom system sound — play via RingtoneManager on the native side
    if (uri != null) {
      SystemServices.playNotificationSound(uri).ignore();
      Future.delayed(const Duration(milliseconds: 2000),
          () => SystemServices.stopNotificationSound().ignore());
      return;
    }

    // Default: built-in asset tone without stealing audio focus
    _notifPlayer.stop().then((_) async {
      await _notifPlayer.setAudioContext(AudioContext(
        android: AudioContextAndroid(
          audioFocus: AndroidAudioFocus.none,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.notificationEvent,
          isSpeakerphoneOn: false,
          stayAwake: false,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.ambient,
          options: {AVAudioSessionOptions.mixWithOthers},
        ),
      ));
      await _notifPlayer.setVolume(0.5);
      await _notifPlayer.play(AssetSource('sounds/ringtone.mp3'));
      Future.delayed(const Duration(milliseconds: 1500),
          () => _notifPlayer.stop().ignore());
    }).ignore();
  }

  void _hideCurrentBanner() {
    try { _currentBanner?.remove(); } catch (_) {}
    _currentBanner = null;
  }

  void _showInAppBanner({
    required String senderName,
    required String message,
  }) {
    final overlayState = navigatorKey.currentState?.overlay;
    if (overlayState == null) return;

    // Dismiss any previous banner without animation (replacing it)
    try {
      _currentBanner?.remove();
    } catch (_) {}
    _currentBanner = null;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _InAppBanner(
        senderName: senderName,
        message: message,
        onDismiss: () {
          try {
            entry.remove();
          } catch (_) {}
          if (_currentBanner == entry) _currentBanner = null;
        },
      ),
    );
    overlayState.insert(entry);
    _currentBanner = entry;
    // No auto-dismiss timer — banner stays until:
    //  • user taps it (onDismiss above)
    //  • a new notification arrives (replaces it at the top of this method)
    //  • user enters the chat list or a chat room (screens call dismissBanner)
  }

  // ── Call notification handlers ────────────────────────────────────────────
  void _setupCallNotificationHandlers() {
    // Incoming call notification tap → pop everything back to the calendar home screen.
    NotificationService.onCallNotificationTap = (_) {
      navigatorKey.currentState?.popUntil((route) => route.isFirst);
    };

    // Ongoing call notification tap → return to active voice call
    NotificationService.onOngoingCallNotificationTap = _returnToActiveCall;

    // Foreground service notification tap (native Android) → same
    SystemServices.onReturnToCall = _returnToActiveCall;

    // Camera viewer in-app PiP
    CameraShareService.onViewerMinimized = _showCameraViewerPip;

    // Show/hide floating call bar when call is minimized or ended
    CallService.onCallMinimized = _showCallBar;
    CallService.onCallEnded = () {
      SystemServices.setPipEnabled(false).ignore();
      // Always stop the foreground service + clear all call-related notifications
      // when cleanup() fires, regardless of which code path ended the call.
      SystemServices.stopCallService().ignore();
      NotificationService.cancelOngoingCallNotification().ignore();
      NotificationService.cancelCallNotification().ignore();
      _hideCallBar();
    };

    // Foreground FCM → show a local notification so the user sees it even
    // when the app is open. Firestore listeners handle in-app banners/tones,
    // but the system notification is needed for lock-screen / status-bar.
    FirebaseMessaging.onMessage.listen((msg) {
      final type = msg.data['type'] as String?;
      if (type == 'incoming_call') {
        // Handled by the Firestore call listener — skip duplicate notification.
        return;
      }
      // For chat / group messages show a system notification so it appears on
      // the status bar even when the app is fully in the foreground.
      if (msg.notification != null) {
        NotificationService.showFcmNotification(msg).ignore();
      }
    });

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
    if (!_callService.isInCall) {
      SystemServices.setPipEnabled(false).ignore();
      _hideCallBar();
      return;
    }
    _hideCallBar();
    // If the screen is already in the navigation stack (user pressed HOME instead
    // of the minimize button), the app simply comes to the foreground — no push needed.
    if (CallScreen.isOnStack) return;
    final otherUser = _callService.minimizedOtherUser;
    final callType = _callService.minimizedCallType;
    final currentUid = _callService.minimizedCurrentUid;
    final isOutgoing = _callService.minimizedIsOutgoing;
    final callId = _callService.activeCallId;
    if (otherUser == null ||
        callType == null ||
        currentUid == null ||
        isOutgoing == null ||
        callId == null) return;

    // Delay ensures the PiP's AgoraVideoView is fully disposed and its Agora cleanup
    // (setupRemoteVideo null) has propagated to the native SDK before the new view registers.
    Future.delayed(const Duration(milliseconds: 300), () {
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
    });
  }

  void _showCallBar() {
    _hideCallBar();
    final overlayState = navigatorKey.currentState?.overlay;
    if (overlayState == null) return;
    final isVideo = _callService.minimizedCallType == CallType.video;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => isVideo
          ? _CallVideoPip(
              callService: _callService,
              onTap: _returnToActiveCall,
            )
          : _CallBar(
              callService: _callService,
              onTap: _returnToActiveCall,
            ),
    );
    overlayState.insert(entry);
    _callBar = entry;
    notifyListeners();
  }

  void _hideCallBar() {
    if (_callBar == null) return;
    try { _callBar?.remove(); } catch (_) {}
    _callBar = null;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      NotificationService.cancelAllNotifications().ignore();
      if (_profile != null) _chatService.updateOnReturn(chatUserId).ignore();
      // Execute any camera switch that was deferred while app was backgrounded.
      if (_pendingCameraFacing != null) _executePendingCameraSwitch();
      // Retry anything that failed to send while offline.
      unawaited(OutboxService.instance.drain());
    }
  }

  Future<void> _executePendingCameraSwitch() async {
    final facing = _pendingCameraFacing;
    _pendingCameraFacing = null;
    if (facing == null || facing == _cameraFacing || _cameraEngine == null || _switchingCamera) return;
    _cameraFacing = facing;
    _switchingCamera = true;
    try {
      await CameraShareService().switchLocalCamera();
    } catch (e) {
      debugPrint('Camera switch on resume: $e');
    } finally {
      _switchingCamera = false;
    }
  }

  // ── Group mute state ──────────────────────────────────────────────────────

  static const _mutedGroupsKey = 'muted_group_ids';

  static const _mutesSyncedKey = 'muted_groups_synced_to_server';

  Future<void> _loadMutedGroups() async {
    final prefs = await SharedPreferences.getInstance();
    _mutedGroupIds = Set<String>.from(prefs.getStringList(_mutedGroupsKey) ?? []);
    unawaited(_backfillMutedGroups(prefs));
  }

  /// Mutes used to be stored only on the device. Now that notifications are
  /// sent by a Cloud Function, groups muted before this change would start
  /// pushing again unless the server is told about them — so the existing
  /// local set is published once.
  Future<void> _backfillMutedGroups(SharedPreferences prefs) async {
    if (prefs.getBool(_mutesSyncedKey) ?? false) return;
    if (_mutedGroupIds.isEmpty) {
      await prefs.setBool(_mutesSyncedKey, true);
      return;
    }
    try {
      final db = FirebaseFirestore.instance;
      await Future.wait(_mutedGroupIds.map((id) => db
          .collection('group_chats')
          .doc(id)
          .update({
            'mutedBy': FieldValue.arrayUnion([chatUserId])
          })
          .catchError((_) {})));
      await prefs.setBool(_mutesSyncedKey, true);
    } catch (_) {
      // Leave the flag unset so the next launch retries.
    }
  }

  bool isGroupMuted(String groupId) => _mutedGroupIds.contains(groupId);

  Future<void> setGroupMuted(String groupId, bool muted) async {
    if (muted) {
      _mutedGroupIds.add(groupId);
    } else {
      _mutedGroupIds.remove(groupId);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_mutedGroupsKey, _mutedGroupIds.toList());
    notifyListeners();

    // Push notifications are sent by a Cloud Function, which cannot see this
    // device's local preferences — mirror the choice onto the group document
    // so a muted group stays quiet on the server side too.
    try {
      await FirebaseFirestore.instance
          .collection('group_chats')
          .doc(groupId)
          .update({
        'mutedBy': muted
            ? FieldValue.arrayUnion([chatUserId])
            : FieldValue.arrayRemove([chatUserId]),
      });
    } catch (_) {}
  }

  // ── Group in-app notifications ─────────────────────────────────────────────

  void _startGroupNotifications() {
    _groupNotifSub?.cancel();
    _groupNotifLastMillis.clear();
    final groupService = GroupChatService();
    _groupNotifSub = groupService.getAllGroupsFor(chatUserId).listen((groups) async {
      for (final group in groups) {
        final msgMillis = group.lastMessageTime?.millisecondsSinceEpoch ?? 0;

        // First time seeing this group — record baseline, no notification
        if (!_groupNotifLastMillis.containsKey(group.id)) {
          _groupNotifLastMillis[group.id] = msgMillis;
          continue;
        }
        if (_groupNotifLastMillis[group.id] == msgMillis) continue;
        _groupNotifLastMillis[group.id] = msgMillis;

        // I sent it
        if (group.lastSenderId.isEmpty || group.lastSenderId == chatUserId) continue;

        // Muted by user — unless this message named me directly. Muting a busy
        // group shouldn't mean missing the one message actually addressed to you.
        final mentionsMe = group.lastMentions.contains(chatUserId);
        if (isGroupMuted(group.id) && !mentionsMe) continue;

        // User is currently viewing this group
        if (ActiveGroupChatTracker.activeGroupId == group.id) continue;

        _playNotifTone();

        // Chat list shows the group directly — no banner needed there.
        if (ChatListTracker.isActive) continue;

        // Show banner on every screen except the chat list and the group itself.
        // Mirror private-chat behaviour: disguise sender/message when the user
        // is NOT currently in any chat section.
        final bool inChatSection = ActiveChatTracker.activeChatId != null ||
            ActiveGroupChatTracker.activeGroupId != null;

        final String displaySender;
        final String displayMsg;
        if (inChatSection) {
          final sender = group.lastSenderName.isEmpty ? '' : group.lastSenderName;
          displaySender = sender.isNotEmpty ? '${group.name} · $sender' : group.name;
          displayMsg = group.lastMessage.isEmpty ? '📷 Media' : group.lastMessage;
        } else {
          const randoms = [
            '📬 Incomming expenses!',
            '💬 Some expenses are mandatory',
            '🔔 You have a new life',
            '💭 It is brand new day',
            '✉️ Check your wallet',
            '👋 Something getting interesting!',
          ];
          displaySender = 'Calendar';
          displayMsg = randoms[Random().nextInt(randoms.length)];
        }
        _showInAppBanner(senderName: displaySender, message: displayMsg);
      }
    });
  }

  // ── Global last-seen heartbeat ─────────────────────────────────────────────

  void _startGlobalLastSeenTimer() {
    _globalLastSeenTimer?.cancel();
    _globalLastSeenTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_profile != null) _chatService.updateOnReturn(chatUserId).ignore();
    });
  }

  // ── Group chat delivery tracking ───────────────────────────────────────────

  void _listenForGroupDelivery() {
    _groupDeliverySub?.cancel();
    _groupDeliveredKeys.clear();
    final groupService = GroupChatService();
    _groupDeliverySub = groupService.getAllGroupsFor(chatUserId).listen((groups) {
      for (final group in groups) {
        if (group.lastSenderId.isEmpty || group.lastSenderId == chatUserId) continue;
        if (group.lastMessageTime == null) continue;
        // Skip if the user is currently viewing this group — the screen calls
        // markRead itself, which implicitly marks delivery. Writing here too
        // would cause duplicate Firestore writes on every message.
        if (ActiveGroupChatTracker.activeGroupId == group.id) continue;
        final key = '${group.id}:${group.lastMessageTime!.millisecondsSinceEpoch}';
        if (_groupDeliveredKeys.contains(key)) continue;
        _groupDeliveredKeys.add(key);
        groupService.markDelivered(group.id, chatUserId).ignore();
      }
    });
  }

  @override
  void dispose() {
    _globalLastSeenTimer?.cancel();
    _serviceStopTimer?.cancel();
    if (_cameraServiceRunning) {
      _cameraServiceRunning = false;
      SystemServices.stopCallService().ignore();
    }
    _notesSub?.cancel();
    _expensesSub?.cancel();
    _incomingCallSub?.cancel();
    _chatDeliverySub?.cancel();
    _groupDeliverySub?.cancel();
    _groupNotifSub?.cancel();
    _cameraShareSub?.cancel();
    _cameraDocSub?.cancel();
    _cameraRequestOverlay?.remove();
    _cameraViewerPip?.remove();
    _inAppNotifSub?.cancel();
    _notifPlayer.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

// ── In-app notification banner ─────────────────────────────────────────────────

class _InAppBanner extends StatefulWidget {
  final String senderName;
  final String message;
  final VoidCallback onDismiss;
  const _InAppBanner({
    required this.senderName,
    required this.message,
    required this.onDismiss,
  });

  @override
  State<_InAppBanner> createState() => _InAppBannerState();
}

class _InAppBannerState extends State<_InAppBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<Offset> _slide;
  Timer? _autoTimer;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 280));
    _slide = Tween<Offset>(begin: const Offset(0, -1.5), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _ctrl.forward();
    _autoTimer = Timer(const Duration(seconds: 4), _dismiss);
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    if (!mounted) return;
    await _ctrl.reverse();
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: SlideTransition(
          position: _slide,
          child: GestureDetector(
            onTap: _dismiss,
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) < -100) _dismiss();
            },
            child: Material(
              color: Colors.transparent,
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF5C35D1),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: Colors.white.withValues(alpha: 0.2),
                      child: Text(
                        widget.senderName.isNotEmpty
                            ? widget.senderName[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.senderName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            widget.message,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _dismiss,
                      child: const Icon(Icons.close_rounded,
                          color: Colors.white54, size: 18),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Floating call bar — visible on all screens while call is minimised ─────────

class _CallBar extends StatefulWidget {
  final CallService callService;
  final VoidCallback onTap;
  const _CallBar({required this.callService, required this.onTap});

  @override
  State<_CallBar> createState() => _CallBarState();
}

class _CallBarState extends State<_CallBar> {
  Timer? _timer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    final connectedAt = widget.callService.callConnectedAt;
    if (connectedAt != null) {
      _seconds = DateTime.now().difference(connectedAt).inSeconds;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _fmt(int s) {
    final m = s ~/ 60;
    return '${m.toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isVideo =
        widget.callService.minimizedCallType == CallType.video;
    final name = widget.callService.minimizedOtherUser?.name ?? 'Call';

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Material(
          color: Colors.transparent,
          child: Container(
            color: const Color(0xFF1B5E20),
            padding: EdgeInsets.fromLTRB(
              16,
              MediaQuery.of(context).padding.top + 2,
              16,
              8,
            ),
            child: Row(
              children: [
                Icon(
                  isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                  color: Colors.white,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  _fmt(_seconds),
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Tap to return',
                  style: TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Floating video PiP — draggable in-app video overlay ───────────────────────

class _CallVideoPip extends StatefulWidget {
  final CallService callService;
  final VoidCallback onTap;
  const _CallVideoPip({required this.callService, required this.onTap});

  @override
  State<_CallVideoPip> createState() => _CallVideoPipState();
}

class _CallVideoPipState extends State<_CallVideoPip> {
  Timer? _timer;
  int _seconds = 0;
  Offset _position = const Offset(16, 120);
  bool _isSystemPip = false;

  static const double _w = 140;
  static const double _h = 190;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    final connectedAt = widget.callService.callConnectedAt;
    if (connectedAt != null) {
      _seconds = DateTime.now().difference(connectedAt).inSeconds;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });

    SystemServices.onPipModeChanged = (isInPip) {
      if (mounted) {
        setState(() => _isSystemPip = isInPip);
        if (!isInPip) {
          Future.delayed(const Duration(milliseconds: 100), () {
            if (mounted) widget.onTap(); // Auto-restore full screen when leaving OS PiP
          });
        }
      }
    };
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    SystemServices.onPipModeChanged = null;
    _timer?.cancel();
    super.dispose();
  }

  String _fmt(int s) {
    final m = s ~/ 60;
    return '${m.toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  void _onDrag(DragUpdateDetails d) {
    final size = MediaQuery.of(context).size;
    setState(() {
      _position = Offset(
        (_position.dx + d.delta.dx).clamp(0, size.width - _w),
        (_position.dy + d.delta.dy).clamp(
            MediaQuery.of(context).padding.top, size.height - _h - 32),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.callService.engine;
    final remoteUid = widget.callService.remoteUid;
    final callId = widget.callService.activeCallId;
    final name = widget.callService.minimizedOtherUser?.name ?? '';

    final videoWidget = engine != null && remoteUid != null && callId != null
        ? AgoraVideoView(
            key: ValueKey('pip_remote_${remoteUid}_$callId'),
            controller: VideoViewController.remote(
              rtcEngine: engine,
              canvas: VideoCanvas(uid: remoteUid),
              connection: RtcConnection(channelId: callId),
            ),
          )
        : Container(
            color: const Color(0xFF1A0A3C),
            child: Center(
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.bold),
              ),
            ),
          );

    if (_isSystemPip) {
      // When in OS PiP, take up the entire OS PiP window, hiding the home screen
      return Positioned.fill(
        child: Material(
          color: Colors.black,
          child: videoWidget,
        ),
      );
    }

    return Positioned(
      left: _position.dx,
      top: _position.dy,
      child: GestureDetector(
        onPanUpdate: _onDrag,
        onTap: widget.onTap,
        child: Material(
          color: Colors.transparent,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: _w,
              height: _h,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  videoWidget,
                  // Bottom info strip
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.75),
                            Colors.transparent,
                          ],
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.videocam_rounded,
                              color: Colors.white70, size: 12),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              name,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            _fmt(_seconds),
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Drag handle hint
                  Positioned(
                    top: 6,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        width: 30,
                        height: 3,
                        decoration: BoxDecoration(
                          color: Colors.white38,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Camera viewer in-app PiP overlay ─────────────────────────────────────────

class _CameraViewerPip extends StatefulWidget {
  final VoidCallback onTap;
  final VoidCallback onEnded;
  const _CameraViewerPip({required this.onTap, required this.onEnded});

  @override
  State<_CameraViewerPip> createState() => _CameraViewerPipState();
}

class _CameraViewerPipState extends State<_CameraViewerPip> {
  Offset _position   = const Offset(16, 120);
  bool _isSystemPip  = false;
  StreamSubscription? _docSub;

  static const double _w = 140;
  static const double _h = 186;

  @override
  void initState() {
    super.initState();
    final shareId = CameraShareService.activeShareId;
    if (shareId != null) {
      _docSub = CameraShareService().watchShare(shareId).listen((snap) {
        if (!snap.exists) { widget.onEnded(); return; }
        final status = (snap.data() as Map<String, dynamic>?)?['status'] as String?;
        if (status == 'ended' || status == 'rejected') widget.onEnded();
      });
    }
    SystemServices.onPipModeChanged = (isInPip) {
      if (mounted) {
        setState(() => _isSystemPip = isInPip);
        if (!isInPip) {
          Future.delayed(const Duration(milliseconds: 100), () {
            if (mounted) widget.onTap();
          });
        }
      }
    };
  }

  @override
  void dispose() {
    SystemServices.onPipModeChanged = null;
    _docSub?.cancel();
    super.dispose();
  }

  void _onDrag(DragUpdateDetails d) {
    final size = MediaQuery.of(context).size;
    setState(() {
      _position = Offset(
        (_position.dx + d.delta.dx).clamp(0, size.width  - _w),
        (_position.dy + d.delta.dy).clamp(
            MediaQuery.of(context).padding.top, size.height - _h - 32),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final service   = CameraShareService();
    final engine    = service.engine;
    final remoteUid = CameraShareService.activeRemoteUid;
    final channelId = CameraShareService.activeChannelId;
    final name      = CameraShareService.activeTargetName ?? '';

    final video = engine != null && remoteUid != null && channelId != null
        ? AgoraVideoView(
            key: ValueKey('cvpip_${remoteUid}_$channelId'),
            controller: VideoViewController.remote(
              rtcEngine: engine,
              canvas: VideoCanvas(uid: remoteUid),
              connection: RtcConnection(channelId: channelId),
            ),
          )
        : Container(
            color: Colors.black,
            child: Center(
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: const TextStyle(
                    color: Colors.white, fontSize: 36,
                    fontWeight: FontWeight.bold),
              ),
            ),
          );

    if (_isSystemPip) {
      return Positioned.fill(
          child: Material(color: Colors.black, child: video));
    }

    return Positioned(
      left: _position.dx,
      top:  _position.dy,
      child: GestureDetector(
        onPanUpdate: _onDrag,
        onTap: widget.onTap,
        child: SizedBox(
          width: _w, height: _h,
          child: Stack(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: video,
            ),
            // Name
            Positioned(
              bottom: 6, left: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 10,
                        fontWeight: FontWeight.w600)),
              ),
            ),
            // End button
            Positioned(
              top: 4, right: 4,
              child: GestureDetector(
                onTap: () async {
                  final sid = CameraShareService.activeShareId;
                  widget.onEnded();
                  if (sid != null) await CameraShareService().endShare(sid);
                  SystemServices.stopCallService().ignore();
                },
                child: Container(
                  width: 22, height: 22,
                  decoration: const BoxDecoration(
                      color: Colors.red, shape: BoxShape.circle),
                  child: const Icon(Icons.close_rounded,
                      color: Colors.white, size: 14),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
