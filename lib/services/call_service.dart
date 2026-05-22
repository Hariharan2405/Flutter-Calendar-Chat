import 'dart:async';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';
import '../models/call_model.dart';
import '../models/user_profile_model.dart';

class CallService {
  // Get free App ID from console.agora.io:
  // 1. Sign up → Create Project → Testing Mode (no certificate needed)
  // 2. Copy App ID below
  static const _appId = '8697549310aa4dbfacfaa76d9dd6c027';

  static final CallService _instance = CallService._();
  factory CallService() => _instance;
  CallService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final _uuid = const Uuid();

  RtcEngine? _engine;
  StreamSubscription? _callDocSub;

  void Function(String)? _onStatusChange;
  void Function(int remoteUid)? _onRemoteUserJoined;

  UserProfileModel? minimizedOtherUser;
  CallType? minimizedCallType;
  String? minimizedCurrentUid;
  bool? minimizedIsOutgoing;

  static void Function()? onCallEndedExternally;

  String? activeCallId;
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  bool _isVideoOff = false;
  bool _isConnected = false;
  int? _remoteUid;

  // Call log data — populated during the call, written on end
  String? _callerName;
  String? _calleeName;
  String? _callTypeStr;
  DateTime? _callConnectedAt;

  bool get isMuted => _isMuted;
  bool get isSpeakerOn => _isSpeakerOn;
  bool get isVideoOff => _isVideoOff;
  bool get isInCall => _engine != null;
  bool get isConnected => _isConnected;
  int? get remoteUid => _remoteUid;
  RtcEngine? get engine => _engine;

  // ── Engine setup ──────────────────────────────────────────────────────────

  Future<void> _initEngine({required bool isVideo}) async {
    _engine = createAgoraRtcEngine();
    await _engine!.initialize(RtcEngineContext(
      appId: _appId,
      channelProfile: ChannelProfileType.channelProfileCommunication,
    ));

    await _engine!.setClientRole(role: ClientRoleType.clientRoleBroadcaster);
    await _engine!.enableAudio();

    if (isVideo) {
      await _engine!.enableVideo();
      await _engine!.startPreview();
    }

    _engine!.registerEventHandler(RtcEngineEventHandler(
      onUserJoined: (connection, remoteUid, elapsed) {
        _callConnectedAt = DateTime.now();
        _remoteUid = remoteUid;
        _isConnected = true;
        _onStatusChange?.call('connected');
        _onRemoteUserJoined?.call(remoteUid);
      },
      onUserOffline: (connection, remoteUid, reason) {
        _isConnected = false;
        _remoteUid = null;
        _onStatusChange?.call('ended');
      },
      onConnectionStateChanged: (connection, state, reason) {
        if (state == ConnectionStateType.connectionStateFailed) {
          _onStatusChange?.call('ended');
        }
      },
    ));
  }

  // ── Outgoing call ─────────────────────────────────────────────────────────

  Future<String> startCall({
    required String callerId,
    required String calleeId,
    required String callerName,
    required String calleeName,
    required bool isVideo,
    required void Function(int remoteUid) onRemoteUserJoined,
    required void Function(String status) onStatusChange,
  }) async {
    await _requestPermissions(isVideo);

    // Delete any stale call docs from this caller that were never cleaned up
    try {
      final stale = await _db.collection('calls')
          .where('callerId', isEqualTo: callerId)
          .where('status', whereIn: ['calling', 'ringing'])
          .get();
      for (final doc in stale.docs) {
        doc.reference.delete().ignore();
      }
    } catch (_) {}

    final callId = _uuid.v4();
    activeCallId = callId;
    _callerName = callerName;
    _calleeName = calleeName;
    _callTypeStr = isVideo ? 'video' : 'voice';
    _isMuted = false;
    _isSpeakerOn = isVideo;
    _onStatusChange = onStatusChange;
    _onRemoteUserJoined = onRemoteUserJoined;

    await _initEngine(isVideo: isVideo);

    await _engine!.joinChannel(
      token: '',
      channelId: callId,
      uid: 0,
      options: ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        publishMicrophoneTrack: true,
        publishCameraTrack: isVideo,
        autoSubscribeAudio: true,
        autoSubscribeVideo: isVideo,
      ),
    );

    if (!isVideo) {
      try { await _engine!.setEnableSpeakerphone(false); } catch (_) {}
    }

    // status:'calling' = created, waiting for callee device to receive FCM.
    // Callee's app updates it to 'ringing' when the notification is delivered.
    await _db.collection('calls').doc(callId).set({
      'callerId': callerId,
      'calleeId': calleeId,
      'callerName': callerName,
      'calleeName': calleeName,
      'type': _callTypeStr,
      'status': 'calling',
      'createdAt': Timestamp.now(),
    });

    _callDocSub = _db.collection('calls').doc(callId).snapshots().listen((snap) {
      if (!snap.exists) return;
      final status = snap.data()?['status'] as String?;
      if (status == 'ringing') {
        _onStatusChange?.call('ringing');
      } else if (status == 'ended' || status == 'declined') {
        _onStatusChange?.call(status!);
      }
    });

    return callId;
  }

  // ── Incoming call (answer) ────────────────────────────────────────────────

  Future<void> answerCall({
    required String callId,
    required bool isVideo,
    required void Function(int remoteUid) onRemoteUserJoined,
    required void Function(String status) onStatusChange,
  }) async {
    await _requestPermissions(isVideo);

    activeCallId = callId;
    _isMuted = false;
    _isSpeakerOn = isVideo;
    _onStatusChange = onStatusChange;
    _onRemoteUserJoined = onRemoteUserJoined;

    // Read names so we can write the call log on end
    final snap = await _db.collection('calls').doc(callId).get();
    if (!snap.exists) return;
    final data = snap.data()!;
    _callerName = data['callerName'] as String?;
    _calleeName = data['calleeName'] as String?;
    _callTypeStr = data['type'] as String?;

    await _initEngine(isVideo: isVideo);

    await _engine!.joinChannel(
      token: '',
      channelId: callId,
      uid: 0,
      options: ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        publishMicrophoneTrack: true,
        publishCameraTrack: isVideo,
        autoSubscribeAudio: true,
        autoSubscribeVideo: isVideo,
      ),
    );

    if (!isVideo) {
      try { await _engine!.setEnableSpeakerphone(false); } catch (_) {}
    }

    await _db.collection('calls').doc(callId).update({'status': 'answered'});

    _callDocSub = _db.collection('calls').doc(callId).snapshots().listen((snap) {
      if (!snap.exists) return;
      final status = snap.data()?['status'] as String?;
      if (status == 'ended' || status == 'declined') {
        _onStatusChange?.call(status!);
      }
    });
  }

  // ── Restore a minimized voice call in a new CallScreen ────────────────────

  void updateCallbacks({
    required void Function(int remoteUid) onRemoteUserJoined,
    required void Function(String) onStatusChange,
  }) {
    _onStatusChange = onStatusChange;
    _onRemoteUserJoined = onRemoteUserJoined;
    if (_remoteUid != null) onRemoteUserJoined(_remoteUid!);
    if (_isConnected) onStatusChange('connected');
  }

  void setMinimizedMeta({
    required UserProfileModel otherUser,
    required CallType callType,
    required String currentUid,
    required bool isOutgoing,
  }) {
    minimizedOtherUser = otherUser;
    minimizedCallType = callType;
    minimizedCurrentUid = currentUid;
    minimizedIsOutgoing = isOutgoing;
  }

  // ── Controls ──────────────────────────────────────────────────────────────

  Future<void> toggleMute() async {
    _isMuted = !_isMuted;
    await _engine?.muteLocalAudioStream(_isMuted);
  }

  Future<void> toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
    try { await _engine?.setEnableSpeakerphone(_isSpeakerOn); } catch (_) {}
  }

  Future<void> switchCamera() async {
    await _engine?.switchCamera();
  }

  Future<void> toggleVideo() async {
    _isVideoOff = !_isVideoOff;
    await _engine?.muteLocalVideoStream(_isVideoOff);
  }

  // ── End / decline ─────────────────────────────────────────────────────────

  Future<void> endCall() async {
    final callId = activeCallId;
    if (callId != null) {
      try {
        final connectedAt = _callConnectedAt;
        if (connectedAt != null) {
          // Call was answered — replace signaling doc with minimal log
          final endedAt = DateTime.now();
          await _db.collection('calls').doc(callId).set({
            'callerName': _callerName,
            'calleeName': _calleeName,
            'type': _callTypeStr,
            'startedAt': Timestamp.fromDate(connectedAt),
            'endedAt': Timestamp.fromDate(endedAt),
            'durationSeconds': endedAt.difference(connectedAt).inSeconds,
          });
        } else {
          // Call never connected — signal ended then delete the signaling doc
          await _db.collection('calls').doc(callId).update({'status': 'ended'});
          Future.delayed(const Duration(seconds: 4), () {
            _db.collection('calls').doc(callId).delete().ignore();
          });
        }
      } catch (_) {}
    }
    await cleanup();
  }

  Future<void> declineCall(String callId) async {
    try {
      await _db.collection('calls').doc(callId).update({'status': 'declined'});
      // Give caller ~4s to read 'declined', then delete
      Future.delayed(const Duration(seconds: 4), () {
        _db.collection('calls').doc(callId).delete().ignore();
      });
    } catch (_) {}
  }

  Future<void> cleanup() async {
    _callDocSub?.cancel();
    _callDocSub = null;

    try { await _engine?.leaveChannel(); } catch (_) {}
    try { await _engine?.release(); } catch (_) {}
    _engine = null;

    activeCallId = null;
    _isMuted = false;
    _isVideoOff = false;
    _isSpeakerOn = false;
    _isConnected = false;
    _remoteUid = null;
    _callConnectedAt = null;
    _callerName = null;
    _calleeName = null;
    _callTypeStr = null;
    _onStatusChange = null;
    _onRemoteUserJoined = null;
    minimizedOtherUser = null;
    minimizedCallType = null;
    minimizedCurrentUid = null;
    minimizedIsOutgoing = null;

    onCallEndedExternally?.call();
    onCallEndedExternally = null;
  }

  // ── Streams ───────────────────────────────────────────────────────────────

  Stream<QuerySnapshot> incomingCallsFor(String uid) {
    return _db
        .collection('calls')
        .where('calleeId', isEqualTo: uid)
        .snapshots();
  }

  Stream<DocumentSnapshot> watchCallDoc(String callId) =>
      _db.collection('calls').doc(callId).snapshots();

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<void> _requestPermissions(bool isVideo) async {
    final permissions = [Permission.microphone];
    if (isVideo) permissions.add(Permission.camera);
    await permissions.request();
  }
}
