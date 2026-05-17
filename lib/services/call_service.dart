import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import '../models/call_model.dart';
import '../models/user_profile_model.dart';

class CallService {
  static final CallService _instance = CallService._();
  factory CallService() => _instance;
  CallService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final _uuid = const Uuid();

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  final List<RTCIceCandidate> _pendingCandidates = [];

  StreamSubscription? _callDocSub;
  StreamSubscription? _remoteCandidatesSub;

  // Mutable callbacks — updated when call is restored after minimize
  void Function(String)? _onStatusChange;
  void Function(MediaStream)? _onRemoteStream;

  // Metadata for restoring a minimized voice call
  UserProfileModel? minimizedOtherUser;
  CallType? minimizedCallType;
  String? minimizedCurrentUid;
  bool? minimizedIsOutgoing;

  // AppProvider sets this to cancel the ongoing notification when the remote hangs up
  static void Function()? onCallEndedExternally;

  String? activeCallId;
  bool _remoteDescSet = false;
  bool _connected = false;
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  bool _isVideoOff = false;

  bool get isMuted => _isMuted;
  bool get isSpeakerOn => _isSpeakerOn;
  bool get isVideoOff => _isVideoOff;
  bool get isInCall => _pc != null;
  bool get isConnected => _connected;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  static const _iceConfig = {
    'iceServers': [
      {
        'urls': [
          'stun:stun.l.google.com:19302',
          'stun:stun1.l.google.com:19302',
          'stun:stun2.l.google.com:19302',
          'stun:stun3.l.google.com:19302',
          'stun:stun4.l.google.com:19302',
        ]
      },
      {
        'urls': 'turn:openrelay.metered.ca:80',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:openrelay.metered.ca:443',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:openrelay.metered.ca:443?transport=tcp',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
    ],
  };

  // ── Shared peer connection setup ──────────────────────────────────────────

  Future<void> _initPC({required bool isVideo}) async {
    _pc = await createPeerConnection(_iceConfig);

    _pc!.onIceConnectionState = (state) {
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          if (!_connected) {
            _connected = true;
            _onStatusChange?.call('connected');
            if (!isVideo) Helper.setSpeakerphoneOn(false).ignore();
          }
          break;
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          _onStatusChange?.call('ended');
          break;
        default:
          break;
      }
    };

    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        _onRemoteStream?.call(event.streams[0]);
      }
    };
  }

  // ── Outgoing call ─────────────────────────────────────────────────────────

  Future<String> startCall({
    required String callerId,
    required String calleeId,
    required bool isVideo,
    required void Function(MediaStream) onLocalStream,
    required void Function(MediaStream) onRemoteStream,
    required void Function(String status) onStatusChange,
  }) async {
    final callId = _uuid.v4();
    activeCallId = callId;
    _isMuted = false;
    _isSpeakerOn = isVideo;
    _onStatusChange = onStatusChange;
    _onRemoteStream = onRemoteStream;

    _localStream = await _getMedia(isVideo);
    onLocalStream(_localStream!);

    await _initPC(isVideo: isVideo);

    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    final callRef = _db.collection('calls').doc(callId);

    // Wire up ICE callback BEFORE setLocalDescription so no candidates are missed
    _pc!.onIceCandidate = (c) {
      if (c.candidate == null) return;
      callRef.collection('callerCandidates').add({
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);

    await callRef.set({
      'callerId': callerId,
      'calleeId': calleeId,
      'type': isVideo ? 'video' : 'voice',
      'status': 'ringing',
      'offer': {'type': offer.type, 'sdp': offer.sdp},
      'createdAt': Timestamp.now(),
    });

    _callDocSub = callRef.snapshots().listen((snap) async {
      if (!snap.exists) return;
      final data = snap.data()!;
      final status = data['status'] as String?;

      if (status == 'answered' && data['answer'] != null && !_remoteDescSet) {
        _remoteDescSet = true;
        final answer = data['answer'] as Map<String, dynamic>;
        await _pc!.setRemoteDescription(
          RTCSessionDescription(answer['sdp'], answer['type']),
        );
        for (final c in List.of(_pendingCandidates)) {
          await _pc!.addCandidate(c);
        }
        _pendingCandidates.clear();
      } else if (status == 'ended' || status == 'declined') {
        _onStatusChange?.call(status!);
      }
    });

    _remoteCandidatesSub =
        callRef.collection('calleeCandidates').snapshots().listen((snap) async {
      for (final change in snap.docChanges) {
        if (change.type != DocumentChangeType.added) continue;
        final d = change.doc.data()!;
        final candidate = RTCIceCandidate(
          d['candidate'], d['sdpMid'], d['sdpMLineIndex'],
        );
        if (_remoteDescSet) {
          await _pc!.addCandidate(candidate);
        } else {
          _pendingCandidates.add(candidate);
        }
      }
    });

    return callId;
  }

  // ── Incoming call (answer) ────────────────────────────────────────────────

  Future<void> answerCall({
    required String callId,
    required bool isVideo,
    required void Function(MediaStream) onLocalStream,
    required void Function(MediaStream) onRemoteStream,
    required void Function(String status) onStatusChange,
  }) async {
    activeCallId = callId;
    _isMuted = false;
    _isSpeakerOn = isVideo;
    _onStatusChange = onStatusChange;
    _onRemoteStream = onRemoteStream;

    final callRef = _db.collection('calls').doc(callId);
    final snap = await callRef.get();
    if (!snap.exists) return;
    final offer = (snap.data()!['offer']) as Map<String, dynamic>;

    _localStream = await _getMedia(isVideo);
    onLocalStream(_localStream!);

    await _initPC(isVideo: isVideo);

    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    // Wire up ICE callback BEFORE setLocalDescription so no candidates are missed
    _pc!.onIceCandidate = (c) {
      if (c.candidate == null) return;
      callRef.collection('calleeCandidates').add({
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };

    await _pc!.setRemoteDescription(
      RTCSessionDescription(offer['sdp'], offer['type']),
    );
    _remoteDescSet = true;

    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);

    await callRef.update({
      'status': 'answered',
      'answer': {'type': answer.type, 'sdp': answer.sdp},
    });

    _remoteCandidatesSub =
        callRef.collection('callerCandidates').snapshots().listen((snap) async {
      for (final change in snap.docChanges) {
        if (change.type != DocumentChangeType.added) continue;
        final d = change.doc.data()!;
        await _pc!.addCandidate(RTCIceCandidate(
          d['candidate'], d['sdpMid'], d['sdpMLineIndex'],
        ));
      }
    });

    _callDocSub = callRef.snapshots().listen((snap) {
      if (!snap.exists) return;
      final status = snap.data()?['status'];
      if (status == 'ended' || status == 'declined') {
        _onStatusChange?.call(status as String);
      }
    });
  }

  // ── Restore a minimized voice call in a new CallScreen ────────────────────

  void updateCallbacks({
    required void Function(MediaStream) onLocalStream,
    required void Function(MediaStream) onRemoteStream,
    required void Function(String) onStatusChange,
  }) {
    _onStatusChange = onStatusChange;
    _onRemoteStream = onRemoteStream;
    if (_localStream != null) onLocalStream(_localStream!);
    if (_remoteStream != null) onRemoteStream(_remoteStream!);
    if (_connected) onStatusChange('connected');
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
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !_isMuted);
  }

  Future<void> toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
    await Helper.setSpeakerphoneOn(_isSpeakerOn);
  }

  Future<void> switchCamera() async {
    final videoTrack = _localStream?.getVideoTracks().firstOrNull;
    if (videoTrack != null) await Helper.switchCamera(videoTrack);
  }

  Future<void> toggleVideo() async {
    _isVideoOff = !_isVideoOff;
    _localStream?.getVideoTracks().forEach((t) => t.enabled = !_isVideoOff);
  }

  // ── End / decline ─────────────────────────────────────────────────────────

  Future<void> endCall() async {
    if (activeCallId != null) {
      try {
        await _db.collection('calls').doc(activeCallId).update({'status': 'ended'});
      } catch (_) {}
    }
    await cleanup();
  }

  Future<void> declineCall(String callId) async {
    try {
      await _db.collection('calls').doc(callId).update({'status': 'declined'});
    } catch (_) {}
  }

  Future<void> cleanup() async {
    _callDocSub?.cancel();
    _remoteCandidatesSub?.cancel();
    _callDocSub = null;
    _remoteCandidatesSub = null;
    _pendingCandidates.clear();

    _localStream?.getTracks().forEach((t) => t.stop());
    await _localStream?.dispose();
    _localStream = null;
    _remoteStream = null;

    await _pc?.close();
    _pc = null;
    activeCallId = null;
    _remoteDescSet = false;
    _connected = false;
    _isMuted = false;
    _isVideoOff = false;
    _onStatusChange = null;
    _onRemoteStream = null;
    minimizedOtherUser = null;
    minimizedCallType = null;
    minimizedCurrentUid = null;
    minimizedIsOutgoing = null;

    onCallEndedExternally?.call();
    onCallEndedExternally = null;

    try {
      await Helper.setSpeakerphoneOn(false);
    } catch (_) {}
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

  Future<MediaStream> _getMedia(bool isVideo) async {
    return await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': isVideo
          ? {'facingMode': 'user', 'width': 1280, 'height': 720}
          : false,
    });
  }
}
