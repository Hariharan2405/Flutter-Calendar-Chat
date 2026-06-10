import 'dart:async';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../constants/app_theme.dart';
import '../services/camera_share_service.dart';
import '../services/system_services.dart';

/// Harry's screen — receives the target's one-way camera + audio stream.
///
/// PiP modes
/// ──────────
/// • System PiP : press HOME → OS mini-window. Controls hidden; only video.
///                Press HOME again or tap window → return to full screen.
/// • In-app PiP : tap Minimize → floating draggable overlay inside the app
///                (handled by AppProvider via CameraShareService.onViewerMinimized).
///
/// Other features
/// ──────────────
/// • Tap video    → toggle overlay controls (immersive mode)
/// • Mute button  → silence incoming audio
/// • Flip button  → remotely switch target's camera
/// • Background   → foreground-service notification keeps stream alive
class CameraViewerScreen extends StatefulWidget {
  final String shareId;
  final String channelId;
  final String targetName;
  final String requesterId;

  const CameraViewerScreen({
    super.key,
    required this.shareId,
    required this.channelId,
    required this.targetName,
    required this.requesterId,
  });

  @override
  State<CameraViewerScreen> createState() => _CameraViewerScreenState();
}

class _CameraViewerScreenState extends State<CameraViewerScreen> {
  final _service = CameraShareService();

  RtcEngine? _engine;
  int?    _remoteUid;
  String  _status        = 'pending';
  String  _cameraFacing  = 'front';
  bool    _isMuted       = false;
  bool    _showControls  = true;
  bool    _isInSystemPip = false; // system/OS PiP window is active
  bool    _isMinimized   = false; // in-app PiP (screen popped, overlay showing)
  bool    _isMinimizing  = false;

  StreamSubscription? _docSub;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    // Listen for system PiP mode changes
    SystemServices.onPipModeChanged = (inPip) {
      if (mounted) setState(() => _isInSystemPip = inPip);
    };
    _listenStatus();
  }

  @override
  void dispose() {
    SystemServices.onPipModeChanged = null;
    WakelockPlus.disable();
    _docSub?.cancel();
    if (!_isMinimized) {
      // Full cleanup only when not minimized to in-app PiP.
      _service.cleanup();
      CameraShareService.clearActiveSession();
      SystemServices.setPipEnabled(false).ignore();
    }
    super.dispose();
  }

  // ── Firestore listener ────────────────────────────────────────────────────

  void _listenStatus() {
    _docSub = _service.watchShare(widget.shareId).listen((snap) async {
      if (!snap.exists) return;
      final data    = snap.data() as Map<String, dynamic>;
      final status  = data['status']       as String? ?? 'pending';
      final facing  = data['cameraFacing'] as String? ?? 'front';

      if (status == 'active' && _status != 'active') {
        // Guard against duplicate Firestore events (optimistic + server confirm)
        if (mounted) setState(() => _status = 'active');
        try {
          _engine = await _service.initAsSubscriber(
            channelId: widget.channelId,
            onRemoteJoined: (uid) {
              if (mounted) setState(() => _remoteUid = uid);
              // Keep session info fresh for the in-app PiP overlay
              CameraShareService.setActiveSession(
                shareId:    widget.shareId,
                channelId:  widget.channelId,
                targetName: widget.targetName,
                remoteUid:  uid,
              );
            },
            onRemoteLeft: () {
              if (mounted) setState(() => _remoteUid = null);
            },
          );
          // Enable system PiP on HOME press.
          // NOTE: we intentionally do NOT call startCallService here.
          // That service uses foregroundServiceType="microphone" which requires
          // RECORD_AUDIO at runtime.  Harry is a subscriber — no mic needed —
          // so starting it would throw a SecurityException and kill the process.
          SystemServices.setPipEnabled(true).ignore();
        } catch (_) {
          if (mounted) Navigator.pop(context);
          return;
        }
      }

      if (status == 'rejected' || status == 'ended') {
        await _service.cleanup();
        CameraShareService.clearActiveSession();
        SystemServices.setPipEnabled(false).ignore();
        if (mounted) {
          setState(() => _status = status);
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) Navigator.pop(context);
          });
        }
        return;
      }

      if (mounted) setState(() { _status = status; _cameraFacing = facing; });
    });
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _end() async {
    _docSub?.cancel();
    await _service.endShare(widget.shareId);
    CameraShareService.clearActiveSession();
    SystemServices.setPipEnabled(false).ignore();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _flipCamera() async {
    final next = _cameraFacing == 'front' ? 'back' : 'front';
    await _service.requestCameraSwitch(widget.shareId, next);
  }

  Future<void> _toggleMute() async {
    final next = !_isMuted;
    await _engine?.muteAllRemoteAudioStreams(next);
    if (mounted) setState(() => _isMuted = next);
  }

  void _toggleControls() => setState(() => _showControls = !_showControls);

  /// Minimize to in-app floating PiP overlay.
  Future<void> _minimize() async {
    if (_isMinimizing) return;
    setState(() => _isMinimizing = true);
    _isMinimized = true;
    _docSub?.cancel(); // overlay takes over Firestore listening
    CameraShareService.setActiveSession(
      shareId:    widget.shareId,
      channelId:  widget.channelId,
      targetName: widget.targetName,
      remoteUid:  _remoteUid,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
      CameraShareService.onViewerMinimized?.call();
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isLive = _status == 'active' && _remoteUid != null && _engine != null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: isLive && !_isInSystemPip ? _toggleControls : null,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── Video ───────────────────────────────────────────────────────
            isLive
                ? AgoraVideoView(
                    key: ValueKey('cam_remote_$_remoteUid'),
                    controller: VideoViewController.remote(
                      rtcEngine: _engine!,
                      canvas: VideoCanvas(uid: _remoteUid!),
                      connection:
                          RtcConnection(channelId: widget.channelId),
                    ),
                  )
                : Center(child: _buildStatusWidget()),

            // ── Overlay — hidden in system PiP, toggled by tap otherwise ───
            if (!_isInSystemPip)
              AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 220),
                child: IgnorePointer(
                  ignoring: !_showControls,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Gradient scrims
                      Positioned(
                        top: 0, left: 0, right: 0,
                        child: _Scrim(begin: Alignment.topCenter),
                      ),
                      Positioned(
                        bottom: 0, left: 0, right: 0,
                        child: _Scrim(begin: Alignment.bottomCenter),
                      ),

                      // Top bar: name + minimize + flip + mute
                      SafeArea(
                        bottom: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: Row(children: [
                            // Name chip
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.black45,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                const Icon(Icons.videocam_rounded,
                                    color: Colors.white70, size: 16),
                                const SizedBox(width: 6),
                                Text(widget.targetName,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14)),
                              ]),
                            ),
                            const Spacer(),
                            if (_status == 'active') ...[
                              // Minimize (in-app PiP)
                              _IconBtn(
                                  icon: Icons.picture_in_picture_rounded,
                                  onTap: _minimize),
                              const SizedBox(width: 8),
                              // Mute
                              _IconBtn(
                                icon: _isMuted
                                    ? Icons.volume_off_rounded
                                    : Icons.volume_up_rounded,
                                onTap: _toggleMute,
                                active: _isMuted,
                              ),
                              const SizedBox(width: 8),
                              // Camera flip
                              _IconBtn(
                                icon: _cameraFacing == 'front'
                                    ? Icons.camera_rear_rounded
                                    : Icons.camera_front_rounded,
                                onTap: _flipCamera,
                              ),
                            ],
                          ]),
                        ),
                      ),

                      // Bottom: hint + end
                      Positioned(
                        bottom: 32, left: 0, right: 0,
                        child: SafeArea(
                          top: false,
                          child: Column(children: [
                            if (isLive)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Text(
                                  'Tap to hide controls',
                                  style: TextStyle(
                                      color: Colors.white
                                          .withValues(alpha: 0.45),
                                      fontSize: 11),
                                ),
                              ),
                            GestureDetector(
                              onTap: _end,
                              child: Container(
                                width: 60, height: 60,
                                decoration: const BoxDecoration(
                                    color: Colors.red,
                                    shape: BoxShape.circle),
                                child: const Icon(Icons.call_end_rounded,
                                    color: Colors.white, size: 28),
                              ),
                            ),
                          ]),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusWidget() {
    if (_status == 'rejected') {
      return _StatusMsg(
          icon: Icons.do_not_disturb_rounded,
          color: Colors.red,
          text: '${widget.targetName} denied the request');
    }
    if (_status == 'ended') {
      return const _StatusMsg(
          icon: Icons.stop_circle_rounded,
          color: Colors.grey,
          text: 'Camera sharing ended');
    }
    return _StatusMsg(
      icon: Icons.videocam_rounded,
      color: AppColors.primary,
      text: _status == 'active'
          ? 'Connecting to ${widget.targetName}…'
          : 'Waiting for ${widget.targetName} to allow…',
      showSpinner: true,
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  const _IconBtn({required this.icon, required this.onTap, this.active = false});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: active
                ? Colors.white.withValues(alpha: 0.25)
                : Colors.black45,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      );
}

class _Scrim extends StatelessWidget {
  final Alignment begin;
  const _Scrim({required this.begin});

  @override
  Widget build(BuildContext context) => Container(
        height: 130,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: begin,
            end: begin == Alignment.topCenter
                ? Alignment.bottomCenter
                : Alignment.topCenter,
            colors: [
              Colors.black.withValues(alpha: 0.62),
              Colors.transparent,
            ],
          ),
        ),
      );
}

class _StatusMsg extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  final bool showSpinner;
  const _StatusMsg(
      {required this.icon,
      required this.color,
      required this.text,
      this.showSpinner = false});

  @override
  Widget build(BuildContext context) =>
      Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, color: color, size: 56),
        const SizedBox(height: 16),
        Text(text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 16)),
        if (showSpinner) ...[
          const SizedBox(height: 24),
          const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                  color: Colors.white54, strokeWidth: 2)),
        ],
      ]);
}
