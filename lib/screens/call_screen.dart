import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../constants/app_theme.dart';
import '../models/call_model.dart';
import '../models/user_profile_model.dart';
import '../services/call_service.dart';
import '../services/notification_service.dart';
import '../services/system_services.dart';

enum _CallState { connecting, connected, ended, declined }

class CallScreen extends StatefulWidget {
  final String callId;
  final bool isOutgoing;
  final CallType callType;
  final UserProfileModel otherUser;
  final String currentUid;
  // true when the user returns to a minimized voice call via the ongoing notification
  final bool isRestoring;

  const CallScreen({
    super.key,
    required this.callId,
    required this.isOutgoing,
    required this.callType,
    required this.otherUser,
    required this.currentUid,
    this.isRestoring = false,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final CallService _callService = CallService();
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  _CallState _callState = _CallState.connecting;
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  bool _isVideoOff = false;
  bool _hasRemoteVideo = false;
  bool _minimized = false;
  bool _isInPipMode = false;

  int _durationSeconds = 0;
  Timer? _durationTimer;

  bool get _isVideo => widget.callType == CallType.video;

  @override
  void initState() {
    super.initState();
    SystemServices.onPipModeChanged = (isInPip) {
      if (mounted) setState(() => _isInPipMode = isInPip);
    };
    _initRenderers();
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    if (_isVideo) await SystemServices.setPipEnabled(true);

    if (widget.isRestoring) {
      await NotificationService.cancelOngoingCallNotification();
      _callService.updateCallbacks(
        onLocalStream: (stream) {
          if (mounted) setState(() => _localRenderer.srcObject = stream);
        },
        onRemoteStream: (stream) {
          if (mounted) setState(() {
            _remoteRenderer.srcObject = stream;
            _hasRemoteVideo = _isVideo;
          });
        },
        onStatusChange: _handleStatusChange,
      );
      if (mounted) setState(() {
        _isMuted = _callService.isMuted;
        _isSpeakerOn = _callService.isSpeakerOn;
        _isVideoOff = _callService.isVideoOff;
        if (_callService.isConnected) {
          _callState = _CallState.connected;
        }
      });
    } else if (widget.isOutgoing) {
      await _startOutgoing();
    } else {
      await _startIncoming();
    }
  }

  Future<void> _startOutgoing() async {
    await _callService.startCall(
      callerId: widget.currentUid,
      calleeId: widget.otherUser.uid,
      isVideo: _isVideo,
      onLocalStream: (stream) {
        if (mounted) setState(() => _localRenderer.srcObject = stream);
      },
      onRemoteStream: (stream) {
        if (mounted) setState(() {
          _remoteRenderer.srcObject = stream;
          _hasRemoteVideo = _isVideo;
        });
      },
      onStatusChange: _handleStatusChange,
    );
  }

  Future<void> _startIncoming() async {
    await _callService.answerCall(
      callId: widget.callId,
      isVideo: _isVideo,
      onLocalStream: (stream) {
        if (mounted) setState(() => _localRenderer.srcObject = stream);
      },
      onRemoteStream: (stream) {
        if (mounted) setState(() {
          _remoteRenderer.srcObject = stream;
          _hasRemoteVideo = _isVideo;
        });
      },
      onStatusChange: _handleStatusChange,
    );
  }

  void _handleStatusChange(String status) {
    if (!mounted) return;
    if (status == 'connected') {
      setState(() => _callState = _CallState.connected);
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _durationSeconds++);
      });
    } else if (status == 'ended') {
      _endLocally(_CallState.ended);
    } else if (status == 'declined') {
      _endLocally(_CallState.declined);
    }
  }

  void _endLocally(_CallState reason) {
    _durationTimer?.cancel();
    if (_isVideo) SystemServices.setPipEnabled(false).ignore();
    NotificationService.cancelOngoingCallNotification().ignore();
    // Null the renderer sources first so no black WebRTC frame is shown
    // during the 2-second "Call ended" pause before the screen pops.
    if (mounted) setState(() {
      _localRenderer.srcObject = null;
      _remoteRenderer.srcObject = null;
      _callState = reason;
    });
    _callService.cleanup();
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> _hangUp() async {
    _durationTimer?.cancel();
    if (_isVideo) await SystemServices.setPipEnabled(false);
    await NotificationService.cancelOngoingCallNotification();
    if (mounted) setState(() {
      _localRenderer.srcObject = null;
      _remoteRenderer.srcObject = null;
    });
    await _callService.endCall();
    if (mounted) Navigator.pop(context);
  }

  // Voice call: pop the screen but keep the WebRTC session alive.
  // An ongoing notification lets the user tap back into the call.
  Future<void> _minimizeVoiceCall() async {
    _minimized = true;
    _callService.setMinimizedMeta(
      otherUser: widget.otherUser,
      callType: widget.callType,
      currentUid: widget.currentUid,
      isOutgoing: widget.isOutgoing,
    );
    // Replace UI callbacks with minimal ones so remote hang-up is still handled
    _callService.updateCallbacks(
      onLocalStream: (_) {},
      onRemoteStream: (_) {},
      onStatusChange: (status) {
        if (status == 'ended' || status == 'declined') {
          _callService.cleanup(); // triggers onCallEndedExternally
        }
      },
    );
    CallService.onCallEndedExternally = () {
      NotificationService.cancelOngoingCallNotification().ignore();
    };
    await NotificationService.showOngoingCallNotification(
      otherUserName: widget.otherUser.name,
      callId: widget.callId,
    );
    if (mounted) Navigator.pop(context);
  }

  String get _statusText {
    switch (_callState) {
      case _CallState.connecting:
        return widget.isOutgoing ? 'Calling...' : 'Connecting...';
      case _CallState.connected:
        return _formatDuration(_durationSeconds);
      case _CallState.ended:
        return 'Call ended';
      case _CallState.declined:
        return 'Call declined';
    }
  }

  String _formatDuration(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_isVideo) {
          // Video: enter Android PiP — screen stays alive in floating window
          await SystemServices.enterPip();
        } else {
          // Voice: minimize — pop screen, call continues, ongoing notification shown
          await _minimizeVoiceCall();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF1A0A3C),
        body: _isVideo ? _buildVideoCall() : _buildVoiceCall(),
      ),
    );
  }

  // ── Voice call UI ─────────────────────────────────────────────────────────

  Widget _buildVoiceCall() {
    return SafeArea(
      child: Column(
        children: [
          const Spacer(),
          CircleAvatar(
            radius: 60,
            backgroundColor: AppColors.primary,
            child: Text(
              widget.otherUser.name[0].toUpperCase(),
              style: const TextStyle(
                  fontSize: 44,
                  fontWeight: FontWeight.bold,
                  color: Colors.white),
            ),
          ),
          const SizedBox(height: 24),
          Text(widget.otherUser.name,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(_statusText,
              style: const TextStyle(color: Colors.white60, fontSize: 16)),
          const Spacer(),
          _buildVoiceControls(),
          const SizedBox(height: 48),
        ],
      ),
    );
  }

  Widget _buildVoiceControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ControlButton(
            icon: _isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
            label: _isMuted ? 'Unmute' : 'Mute',
            onTap: () async {
              await _callService.toggleMute();
              setState(() => _isMuted = _callService.isMuted);
            },
          ),
          // End call — large red button in center
          GestureDetector(
            onTap: _hangUp,
            child: Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                  color: Colors.red, shape: BoxShape.circle),
              child: const Icon(Icons.call_end_rounded,
                  color: Colors.white, size: 34),
            ),
          ),
          _ControlButton(
            icon: _isSpeakerOn
                ? Icons.volume_up_rounded
                : Icons.volume_down_rounded,
            label: _isSpeakerOn ? 'Speaker' : 'Earpiece',
            onTap: () async {
              await _callService.toggleSpeaker();
              setState(() => _isSpeakerOn = _callService.isSpeakerOn);
            },
          ),
        ],
      ),
    );
  }

  // ── Video call UI ─────────────────────────────────────────────────────────

  Widget _buildVideoCall() {
    return Stack(
      children: [
        // Remote video (full screen)
        _hasRemoteVideo
            ? RTCVideoView(_remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
            : Container(
                color: const Color(0xFF1A0A3C),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircleAvatar(
                        radius: 52,
                        backgroundColor: AppColors.primary,
                        child: Text(
                          widget.otherUser.name[0].toUpperCase(),
                          style: const TextStyle(
                              fontSize: 38,
                              fontWeight: FontWeight.bold,
                              color: Colors.white),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(widget.otherUser.name,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Text(_statusText,
                          style: const TextStyle(
                              color: Colors.white60, fontSize: 14)),
                    ],
                  ),
                ),
              ),

        // Hide all overlays in PiP mode — only the remote video is visible
        if (!_isInPipMode) ...[
          // Local video thumbnail (top-right)
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            right: 16,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 100,
                height: 140,
                child: _isVideoOff
                    ? Container(
                        color: Colors.black54,
                        child: const Icon(Icons.videocam_off_rounded,
                            color: Colors.white54, size: 28))
                    : RTCVideoView(_localRenderer,
                        mirror: true,
                        objectFit: RTCVideoViewObjectFit
                            .RTCVideoViewObjectFitCover),
              ),
            ),
          ),

          // Status chip when connected
          if (_callState == _CallState.connected)
            Positioned(
              top: MediaQuery.of(context).padding.top + 16,
              left: 16,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(_statusText,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13)),
              ),
            ),

          // Video controls at bottom
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 32,
            left: 0,
            right: 0,
            child: _buildVideoControls(),
          ),
        ],
      ],
    );
  }

  Widget _buildVideoControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _ControlButton(
          icon: _isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
          label: _isMuted ? 'Unmute' : 'Mute',
          onTap: () async {
            await _callService.toggleMute();
            setState(() => _isMuted = _callService.isMuted);
          },
        ),
        _ControlButton(
          icon: _isVideoOff
              ? Icons.videocam_off_rounded
              : Icons.videocam_rounded,
          label: _isVideoOff ? 'Start video' : 'Stop video',
          onTap: () async {
            await _callService.toggleVideo();
            setState(() => _isVideoOff = _callService.isVideoOff);
          },
        ),
        // End call
        GestureDetector(
          onTap: _hangUp,
          child: Container(
            width: 68,
            height: 68,
            decoration: const BoxDecoration(
                color: Colors.red, shape: BoxShape.circle),
            child: const Icon(Icons.call_end_rounded,
                color: Colors.white, size: 32),
          ),
        ),
        _ControlButton(
          icon: Icons.flip_camera_android_rounded,
          label: 'Flip',
          onTap: () => _callService.switchCamera(),
        ),
        _ControlButton(
          icon: _isSpeakerOn
              ? Icons.volume_up_rounded
              : Icons.volume_down_rounded,
          label: 'Speaker',
          onTap: () async {
            await _callService.toggleSpeaker();
            setState(() => _isSpeakerOn = _callService.isSpeakerOn);
          },
        ),
      ],
    );
  }

  @override
  void dispose() {
    SystemServices.onPipModeChanged = null;
    _durationTimer?.cancel();
    if (!_minimized) {
      // Only cleanup WebRTC if we truly ended — not if we just minimized
      _callService.cleanup();
    }
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
          const SizedBox(height: 6),
          Text(label,
              style:
                  const TextStyle(color: Colors.white60, fontSize: 11)),
        ],
      ),
    );
  }
}
