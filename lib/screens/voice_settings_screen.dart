import 'package:flutter/material.dart';

import '../constants/app_theme.dart';
import '../services/system_services.dart';
import '../services/tts_service.dart';
import '../utils/responsive.dart';

/// Picks the read-aloud voice and tunes how messages are spoken.
class VoiceSettingsScreen extends StatefulWidget {
  const VoiceSettingsScreen({super.key});

  @override
  State<VoiceSettingsScreen> createState() => _VoiceSettingsScreenState();
}

class _VoiceSettingsScreenState extends State<VoiceSettingsScreen> {
  final _tts = TtsService.instance;

  @override
  void initState() {
    super.initState();
    _tts.addListener(_onTts);
    _tts.init();
  }

  @override
  void dispose() {
    _tts.removeListener(_onTts);
    _tts.stop();
    super.dispose();
  }

  void _onTts() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Read messages aloud')),
      body: ContentWidth(
        maxWidth: 720,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
          children: [
            _card(
              title: 'Voice',
              subtitle: 'Tap a voice to hear it',
              child: Column(
                children:
                    VoiceCharacter.values.map((c) => _voiceRow(c)).toList(),
              ),
            ),
            _card(
              title: 'Speaking speed',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    const Icon(Icons.directions_walk_rounded,
                        size: 18, color: AppColors.textSecondary),
                    Expanded(
                      child: Slider(
                        value: _tts.rate,
                        min: 0.2,
                        max: 1.0,
                        divisions: 16,
                        activeColor: AppColors.primary,
                        label: '${(_tts.rate * 100).round()}%',
                        onChanged: (v) => _tts.setRate(v),
                        onChangeEnd: (_) => _tts.preview(_tts.character),
                      ),
                    ),
                    const Icon(Icons.directions_run_rounded,
                        size: 18, color: AppColors.textSecondary),
                  ],
                ),
              ),
            ),
            _card(
              title: 'Voice engine',
              child: RadioGroup<bool>(
                groupValue: _tts.useCloud,
                onChanged: (v) => _tts.setUseCloud(v ?? true),
                child: Column(
                  children: [
                    RadioListTile<bool>(
                      value: true,
                      // A build without a key can't use Gemini at all.
                      enabled: _tts.cloudAvailable,
                      activeColor: AppColors.primary,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16),
                      title: const Text('Gemini voice (recommended)',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        _tts.cloudAvailable
                            ? 'Natural Tamil and English on every phone, and '
                                'Tanglish converted to proper Tamil. Free, needs '
                                'internet. The free allowance is small — about '
                                '10–20 new messages a day — but messages you '
                                'have played once replay free. Message text is '
                                'sent to Google, which may use it to improve '
                                'its products.'
                            : 'Not available in this build of the app.',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    if (_tts.useCloud && _tts.lastFallbackReason != null)
                      ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 16),
                        leading: const Icon(Icons.hourglass_bottom_rounded,
                            color: AppColors.accent),
                        title: Text(_tts.lastFallbackReason!,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600)),
                        subtitle: const Text(
                          'Messages already played still play from memory. '
                          'New ones use the phone voice until Gemini is '
                          'available again.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    RadioListTile<bool>(
                      value: false,
                      activeColor: AppColors.primary,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16),
                      title: const Text('Device voice (offline)',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: const Text(
                        'Works without internet and keeps text on the phone, but '
                        'Tamil only works if this phone has a Tamil voice, and '
                        'Tanglish is approximate.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    // Device-voice details only matter when that engine is used.
                    if (!_tts.useCloud) ...[
                      const Divider(height: 1),
                      SwitchListTile(
                        value: _tts.transliterateTanglish,
                        onChanged: _tts.setTransliterateTanglish,
                        activeThumbColor: AppColors.primary,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 16),
                        title: const Text('Read Tanglish as Tamil',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                        subtitle: const Text(
                          'Converts Tamil typed in English letters before '
                          'speaking. Needs a Tamil voice on this phone.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      const Divider(height: 1),
                      _tamilStatusRow(),
                    ],
                  ],
                ),
              ),
            ),
            _card(
              title: 'Automatic',
              child: SwitchListTile(
                value: _tts.autoRead,
                onChanged: _tts.setAutoRead,
                activeThumbColor: AppColors.primary,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: const Text('Read new messages aloud',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                subtitle: const Text(
                  'Incoming text messages are spoken automatically while the '
                  'chat is open, using the phone voice to save the Gemini '
                  'allowance.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                _tts.useCloud
                    ? "If Gemini can't be reached, messages are read "
                        'with the device voice instead.'
                    : 'Device voices come from the text-to-speech engine on this '
                        'phone, so quality depends on it.',
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Pieces ─────────────────────────────────────────────────────────────────

  Widget _card(
      {required String title, String? subtitle, required Widget child}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding:
                  EdgeInsets.fromLTRB(16, 14, 16, subtitle == null ? 4 : 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title.toUpperCase(),
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.1,
                          color: AppColors.textSecondary)),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(subtitle,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textSecondary)),
                    ),
                ],
              ),
            ),
            child,
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _voiceRow(VoiceCharacter c) {
    final selected = _tts.character == c;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary
              : AppColors.primary.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(
          _iconFor(c),
          size: 20,
          color: selected ? Colors.white : AppColors.primary,
        ),
      ),
      title: Text(c.label,
          style: TextStyle(
              fontSize: 15,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: AppColors.textPrimary)),
      subtitle: Text(c.description, style: const TextStyle(fontSize: 12)),
      trailing: IconButton(
        icon: Icon(
          (_tts.speakingId == '__preview__' || _tts.isLoading('__preview__')) &&
                  selected
              ? Icons.stop_circle_outlined
              : Icons.play_circle_outline_rounded,
          color: AppColors.primary,
        ),
        tooltip: 'Preview',
        onPressed: () {
          if (_tts.speakingId == '__preview__' ||
              _tts.isLoading('__preview__')) {
            _tts.stop();
          } else {
            _tts.setCharacter(c);
            _tts.preview(c);
          }
        },
      ),
      selected: selected,
      onTap: () {
        _tts.setCharacter(c);
        _tts.preview(c);
      },
    );
  }

  IconData _iconFor(VoiceCharacter c) => switch (c) {
        VoiceCharacter.male => Icons.face_6_rounded,
        VoiceCharacter.female => Icons.face_3_rounded,
        VoiceCharacter.child => Icons.child_care_rounded,
        VoiceCharacter.comic => Icons.emoji_emotions_rounded,
      };

  /// Tamil voice data is a separate download in Android's TTS settings. Without
  /// it every Tamil run silently falls back to the English voice and sounds
  /// wrong, so the state is surfaced rather than left to guesswork.
  Widget _tamilStatusRow() {
    final ok = _tts.tamilAvailable;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(
        ok ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
        color: ok ? AppColors.expenseIndicator : AppColors.accent,
      ),
      title: Text(ok ? 'Tamil voice installed' : 'Tamil voice not installed',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Text(
        ok
            ? 'Tamil and Tanglish messages will be spoken in Tamil.'
            : 'Tamil will be read with the English voice until you install '
                'Tamil voice data. Open text-to-speech settings, then tap the '
                'gear next to your engine → Install voice data → Tamil.',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: ok
          ? null
          : TextButton(
              onPressed: () async {
                final opened = await SystemServices.openTtsSettings();
                if (!mounted) return;
                if (!opened) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Open Settings → System → Languages → '
                            'Text-to-speech output')),
                  );
                }
              },
              child: const Text('Open'),
            ),
      onTap: ok ? null : () => _tts.refreshVoices(),
    );
  }
}
