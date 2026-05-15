import 'dart:async';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import '../constants/app_theme.dart';

class VoicePreviewSheet extends StatefulWidget {
  final String audioPath;
  final int durationSeconds;
  final Future<void> Function() onSend;

  const VoicePreviewSheet({
    super.key,
    required this.audioPath,
    required this.durationSeconds,
    required this.onSend,
  });

  @override
  State<VoicePreviewSheet> createState() => _VoicePreviewSheetState();
}

class _VoicePreviewSheetState extends State<VoicePreviewSheet> {
  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;
  bool _isSending = false;
  int _playedSeconds = 0;
  StreamSubscription? _positionSub;
  StreamSubscription? _completeSub;

  @override
  void initState() {
    super.initState();
    _positionSub = _player.onPositionChanged.listen((pos) {
      if (mounted) setState(() => _playedSeconds = pos.inSeconds);
    });
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() { _isPlaying = false; _playedSeconds = 0; });
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.durationSeconds;
    final progress = total > 0 ? (_playedSeconds / total).clamp(0.0, 1.0) : 0.0;

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: AppColors.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Voice Message Preview',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                color: AppColors.textPrimary),
          ),
          const SizedBox(height: 20),
          // Waveform + progress
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _togglePlay,
                  child: Container(
                    width: 44, height: 44,
                    decoration: const BoxDecoration(
                      color: AppColors.primary, shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: Colors.white, size: 24,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 6,
                          backgroundColor: AppColors.divider,
                          valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_fmt(_playedSeconds),
                              style: const TextStyle(fontSize: 11,
                                  color: AppColors.textSecondary)),
                          Text(_fmt(total),
                              style: const TextStyle(fontSize: 11,
                                  color: AppColors.textSecondary)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Action buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isSending ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.delete_outline, color: AppColors.holiday),
                  label: const Text('Delete',
                      style: TextStyle(color: AppColors.holiday)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.holiday),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isSending ? null : _send,
                  icon: _isSending
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.send_rounded),
                  label: Text(_isSending ? 'Sending...' : 'Send'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.expenseIndicator,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      await _player.pause();
      setState(() => _isPlaying = false);
    } else {
      await _player.play(DeviceFileSource(widget.audioPath));
      setState(() => _isPlaying = true);
    }
  }

  Future<void> _send() async {
    await _player.stop();
    setState(() => _isSending = true);
    try {
      await widget.onSend();
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => _isSending = false);
    }
  }

  String _fmt(int s) {
    return '${(s ~/ 60).toString().padLeft(1, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _completeSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}
