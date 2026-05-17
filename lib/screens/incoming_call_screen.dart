import 'dart:async';
import 'package:flutter/material.dart';
import '../constants/app_theme.dart';
import '../models/call_model.dart';
import '../models/user_profile_model.dart';
import '../services/call_service.dart';
import '../services/notification_service.dart';
import '../services/system_services.dart';
import 'call_screen.dart';

class IncomingCallScreen extends StatefulWidget {
  final String callId;
  final UserProfileModel caller;
  final CallType callType;
  final String currentUid;

  const IncomingCallScreen({
    super.key,
    required this.callId,
    required this.caller,
    required this.callType,
    required this.currentUid,
  });

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with SingleTickerProviderStateMixin {
  final CallService _callService = CallService();
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;
  StreamSubscription? _callStatusSub;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    // Cancel any system call notification shown while app was in background
    NotificationService.cancelCallNotification();
    _startRingtone();

    // Listen directly on the call doc — auto-dismiss if caller cancels/ends
    _callStatusSub = _callService
        .watchCallDoc(widget.callId)
        .listen((snap) {
      if (!snap.exists) {
        if (mounted) Navigator.pop(context);
        return;
      }
      final status = (snap.data() as Map<String, dynamic>?)?['status'];
      if (status == 'ended' || status == 'declined') {
        if (mounted) Navigator.pop(context);
      }
    });
  }

  Future<void> _startRingtone() async {
    await SystemServices.startRingtone();
  }

  Future<void> _stopRingtone() async {
    await SystemServices.stopRingtone();
  }

  @override
  void dispose() {
    _stopRingtone();
    _pulseCtrl.dispose();
    _callStatusSub?.cancel();
    NotificationService.cancelCallNotification();
    super.dispose();
  }

  Future<void> _accept() async {
    await _stopRingtone();
    _callStatusSub?.cancel();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          callId: widget.callId,
          isOutgoing: false,
          callType: widget.callType,
          otherUser: widget.caller,
          currentUid: widget.currentUid,
        ),
      ),
    );
  }

  Future<void> _decline() async {
    await _stopRingtone();
    await _callService.declineCall(widget.callId);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.callType == CallType.video;
    return Scaffold(
      backgroundColor: const Color(0xFF1A0A3C),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            // Caller info
            ScaleTransition(
              scale: _pulseAnim,
              child: CircleAvatar(
                radius: 56,
                backgroundColor: AppColors.primary,
                child: Text(
                  widget.caller.name[0].toUpperCase(),
                  style: const TextStyle(
                      fontSize: 44,
                      fontWeight: FontWeight.bold,
                      color: Colors.white),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              widget.caller.name,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                  color: Colors.white60,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Text(
                  'Incoming ${isVideo ? 'video' : 'voice'} call',
                  style: const TextStyle(color: Colors.white60, fontSize: 16),
                ),
              ],
            ),
            const Spacer(),
            // Action buttons
            Padding(
              padding: const EdgeInsets.fromLTRB(40, 0, 40, 48),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Decline
                  _CallActionButton(
                    icon: Icons.call_end_rounded,
                    color: Colors.red,
                    label: 'Decline',
                    onTap: _decline,
                  ),
                  // Accept
                  _CallActionButton(
                    icon: isVideo
                        ? Icons.videocam_rounded
                        : Icons.call_rounded,
                    color: Colors.green,
                    label: 'Accept',
                    onTap: _accept,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CallActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _CallActionButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 10),
        Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 14)),
      ],
    );
  }
}
