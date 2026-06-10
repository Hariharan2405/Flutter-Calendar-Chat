import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';

/// Manages a one-way camera stream: target publishes video, requester subscribes.
/// Signalling is done through the `camera_shares` Firestore collection.
class CameraShareService {
  static const _appId = '8697549310aa4dbfacfaa76d9dd6c027';
  static const _col = 'camera_shares';

  static final CameraShareService _i = CameraShareService._();
  factory CameraShareService() => _i;
  CameraShareService._();

  final _db = FirebaseFirestore.instance;
  final _uuid = const Uuid();

  RtcEngine? _engine;
  RtcEngine? get engine => _engine;

  // ── Static session state (survives screen pop during minimize) ────────────

  /// Called by AppProvider to show the in-app floating PiP overlay.
  static void Function()? onViewerMinimized;

  static String? _activeShareId;
  static String? _activeChannelId;
  static String? _activeTargetName;
  static int?    _activeRemoteUid;

  static String? get activeShareId   => _activeShareId;
  static String? get activeChannelId => _activeChannelId;
  static String? get activeTargetName => _activeTargetName;
  static int?    get activeRemoteUid  => _activeRemoteUid;

  static void setActiveSession({
    required String shareId,
    required String channelId,
    required String targetName,
    int? remoteUid,
  }) {
    _activeShareId   = shareId;
    _activeChannelId = channelId;
    _activeTargetName = targetName;
    _activeRemoteUid  = remoteUid;
  }

  static void clearActiveSession() {
    _activeShareId = _activeChannelId = _activeTargetName = null;
    _activeRemoteUid = null;
  }

  static ({String shareId, String channelId, String targetName, int? remoteUid})?
      get activeSession {
    if (_activeShareId == null || _activeChannelId == null) return null;
    return (
      shareId:    _activeShareId!,
      channelId:  _activeChannelId!,
      targetName: _activeTargetName ?? '',
      remoteUid:  _activeRemoteUid,
    );
  }

  // ── Signalling ─────────────────────────────────────────────────────────────

  /// Returns (shareId, channelId) so the caller doesn't need a second read.
  Future<({String shareId, String channelId})> createRequest({
    required String requesterId,
    required String requesterName,
    required String targetId,
  }) async {
    final shareId = _uuid.v4();
    final channelId = _uuid.v4();
    await _db.collection(_col).doc(shareId).set({
      'requesterId': requesterId,
      'requesterName': requesterName,
      'targetId': targetId,
      'status': 'pending',     // pending → active | rejected | ended
      'channelId': channelId,
      'cameraFacing': 'front', // requester can flip this remotely
      'createdAt': FieldValue.serverTimestamp(),
    });
    return (shareId: shareId, channelId: channelId);
  }

  Future<void> acceptRequest(String shareId) =>
      _db.collection(_col).doc(shareId).update({'status': 'active'});

  Future<void> rejectRequest(String shareId) =>
      _db.collection(_col).doc(shareId).update({'status': 'rejected'});

  Future<void> endShare(String shareId) async {
    try {
      await _db.collection(_col).doc(shareId).update({'status': 'ended'});
    } catch (_) {}
    await cleanup();
  }

  /// Called by the requester to flip the target's camera front ↔ back.
  Future<void> requestCameraSwitch(String shareId, String facing) =>
      _db.collection(_col).doc(shareId).update({'cameraFacing': facing});

  Stream<DocumentSnapshot> watchShare(String shareId) =>
      _db.collection(_col).doc(shareId).snapshots();

  Stream<QuerySnapshot> watchIncomingRequests(String targetId) =>
      _db
          .collection(_col)
          .where('targetId', isEqualTo: targetId)
          .where('status', isEqualTo: 'pending')
          .snapshots();

  // ── Agora: target (publisher, video only) ─────────────────────────────────

  Future<RtcEngine> initAsPublisher({
    required String channelId,
    void Function(int uid)? onViewerJoined,
  }) async {
    await cleanup();
    _engine = createAgoraRtcEngine();
    await _engine!.initialize(RtcEngineContext(
      appId: _appId,
      channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
    ));
    await _engine!.setClientRole(role: ClientRoleType.clientRoleBroadcaster);
    await _engine!.enableVideo();
    await _engine!.enableAudio();
    await _engine!.startPreview();
    _engine!.registerEventHandler(RtcEngineEventHandler(
      onUserJoined: (_, uid, __) => onViewerJoined?.call(uid),
    ));
    await _engine!.joinChannel(
      token: '',
      channelId: channelId,
      uid: 0,
      options: const ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        publishCameraTrack: true,
        publishMicrophoneTrack: true,   // send mic audio
        autoSubscribeAudio: false,
        autoSubscribeVideo: false,
      ),
    );
    return _engine!;
  }

  /// Switch front/back on the target device.
  Future<void> switchLocalCamera() => _engine?.switchCamera() ?? Future.value();

  // ── Agora: requester (subscriber, video only) ─────────────────────────────

  Future<RtcEngine> initAsSubscriber({
    required String channelId,
    required void Function(int uid) onRemoteJoined,
    required void Function() onRemoteLeft,
  }) async {
    await cleanup();
    _engine = createAgoraRtcEngine();
    await _engine!.initialize(RtcEngineContext(
      appId: _appId,
      channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
    ));
    await _engine!.setClientRole(role: ClientRoleType.clientRoleAudience);
    await _engine!.enableVideo();
    await _engine!.enableAudio();
    _engine!.registerEventHandler(RtcEngineEventHandler(
      onUserJoined: (_, uid, __) => onRemoteJoined(uid),
      onUserOffline: (_, uid, __) => onRemoteLeft(),
    ));
    await _engine!.joinChannel(
      token: '',
      channelId: channelId,
      uid: 0,
      options: const ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleAudience,
        publishCameraTrack: false,
        publishMicrophoneTrack: false,
        autoSubscribeAudio: true,   // receive target's audio
        autoSubscribeVideo: true,
      ),
    );
    return _engine!;
  }

  // ── Cleanup ────────────────────────────────────────────────────────────────

  /// Synchronously clears the engine reference without releasing it.
  /// Call this before releasing the engine manually so concurrent code
  /// (e.g. initAsPublisher's internal cleanup) sees null and skips a double-release.
  void clearEngineRef() => _engine = null;

  Future<void> cleanup() async {
    try { await _engine?.leaveChannel(); } catch (_) {}
    try { await _engine?.release(); } catch (_) {}
    _engine = null;
  }
}
