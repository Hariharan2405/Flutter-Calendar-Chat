import 'package:flutter/material.dart';

import '../constants/app_theme.dart';
import '../services/tts_service.dart';
import '../utils/tanglish.dart';

/// Small speaker control shown inside a text bubble.
///
/// Rebuilds only itself off [TtsService], so one message starting or stopping
/// does not rebuild the whole message list.
class SpeakButton extends StatelessWidget {
  final String messageId;
  final String text;

  /// Tint for a bubble on a coloured (outgoing) background.
  final bool onDark;

  const SpeakButton({
    super.key,
    required this.messageId,
    required this.text,
    required this.onDark,
  });

  @override
  Widget build(BuildContext context) {
    // Nothing readable (emoji-only, a bare link) — no point offering a button.
    if (!isSpeakable(text)) return const SizedBox.shrink();

    final tts = TtsService.instance;
    return ListenableBuilder(
      listenable: tts,
      builder: (_, __) {
        final speaking = tts.isSpeaking(messageId);
        final loading = tts.isLoading(messageId);
        final active = speaking || loading;
        final color = onDark
            ? Colors.white.withValues(alpha: active ? 1 : 0.7)
            : (active ? AppColors.primary : AppColors.textSecondary);
        return InkWell(
          // Tapping while loading cancels, same as tapping while speaking.
          onTap: () => tts.speak(messageId, text),
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            child: loading
                ? SizedBox(
                    width: 15,
                    height: 15,
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: CircularProgressIndicator(
                          strokeWidth: 1.6, color: color),
                    ),
                  )
                : Icon(
                    speaking
                        ? Icons.stop_circle_rounded
                        : Icons.volume_up_rounded,
                    size: 15,
                    color: color,
                  ),
          ),
        );
      },
    );
  }
}
