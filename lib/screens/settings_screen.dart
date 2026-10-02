import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';
import '../services/chat_prefs.dart';
import '../services/media_cache.dart';
import '../services/tts_service.dart';
import '../services/update_service.dart';
import '../utils/image_sizing.dart';
import '../utils/responsive.dart';
import '../utils/snack_util.dart';
import '../widgets/chat_ui.dart';
import '../widgets/update_dialog.dart';
import 'voice_settings_screen.dart';

/// Everything that used to hide in the chat list's ⋮ menu, plus chat display,
/// storage and app information.
///
/// The actions that need the chat list's own state (changing the profile
/// photo, the shortcut keyword, the notification sound) are passed in rather
/// than duplicated, so there is still exactly one implementation of each.
class SettingsScreen extends StatefulWidget {
  final VoidCallback onEditPhoto;
  final Future<void> Function() onChangeShortcutKeyword;
  final Future<void> Function() onPickNotificationSound;

  const SettingsScreen({
    super.key,
    required this.onEditPhoto,
    required this.onChangeShortcutKeyword,
    required this.onPickNotificationSound,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _prefs = ChatPrefs.instance;
  final _tts = TtsService.instance;

  String _version = '';
  int? _cacheBytes;
  bool _clearing = false;
  bool _checkingUpdate = false;

  /// Cache folders this app owns inside the temporary directory.
  static const _cacheDirs = [
    'chatMediaCache', // chat/status media (media_cache.dart)
    'libCachedImageData', // avatars and other network images
    'tts_plans',
    'tts_audio',
    'video_frames',
  ];

  @override
  void initState() {
    super.initState();
    _prefs.addListener(_refresh);
    _tts.addListener(_refresh);
    _tts.init();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) {
        setState(() => _version = '${info.version} (${info.buildNumber})');
      }
    });
    _measureCache();
  }

  @override
  void dispose() {
    _prefs.removeListener(_refresh);
    _tts.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  // ── Storage ────────────────────────────────────────────────────────────────

  Future<void> _measureCache() async {
    try {
      final root = (await getTemporaryDirectory()).path;
      var total = 0;
      for (final name in _cacheDirs) {
        final dir = Directory('$root/$name');
        if (!await dir.exists()) continue;
        await for (final e in dir.list(recursive: true, followLinks: false)) {
          if (e is File) total += await e.length();
        }
      }
      if (mounted) setState(() => _cacheBytes = total);
    } catch (_) {
      if (mounted) setState(() => _cacheBytes = 0);
    }
  }

  Future<void> _clearCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear cached media?'),
        content: const Text(
            'Downloaded photos, videos, voice notes and read-aloud audio are '
            'removed from this phone. Nothing is deleted from your chats; '
            'media downloads again when you open it.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      await mediaCacheManager.emptyCache();
      await CachedNetworkImageProvider.defaultCacheManager.emptyCache();
      final root = (await getTemporaryDirectory()).path;
      for (final name in ['tts_plans', 'tts_audio', 'video_frames']) {
        final dir = Directory('$root/$name');
        if (await dir.exists()) await dir.delete(recursive: true);
      }
      PaintingBinding.instance.imageCache.clear();
      if (mounted) context.showSuccess('Cache cleared');
    } catch (_) {
      if (mounted) context.showError('Could not clear everything');
    }
    if (mounted) setState(() => _clearing = false);
    await _measureCache();
  }

  // ── About ──────────────────────────────────────────────────────────────────

  Future<void> _checkForUpdate() async {
    setState(() => _checkingUpdate = true);
    final info = await UpdateService.checkForUpdate();
    if (!mounted) return;
    setState(() => _checkingUpdate = false);
    if (info == null) {
      context.showSuccess("You're on the latest version");
    } else {
      await UpdateDialog.show(context, info);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final profile = provider.profile;
    final sizeLabel = ChatPrefs.textSizes
        .firstWhere((t) => t.$2 == _prefs.textScale,
            orElse: () => ChatPrefs.textSizes[1])
        .$1;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F4FC),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: const ChatHeaderBackground(),
        title: const Text('Settings',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 21)),
      ),
      body: ContentWidth(
        maxWidth: 720,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            // ── Profile ──────────────────────────────────────────────────
            _Card(
              child: InkWell(
                onTap: widget.onEditPhoto,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    CircleAvatar(
                      radius: 32,
                      backgroundColor: ChatStyle.violet,
                      backgroundImage: profile?.photoUrl != null
                          ? avatarImage(profile!.photoUrl!, radius: 32)
                          : null,
                      child: profile?.photoUrl == null
                          ? Text(
                              (profile?.name.isNotEmpty ?? false)
                                  ? profile!.name[0].toUpperCase()
                                  : '?',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700),
                            )
                          : null,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(profile?.name ?? '',
                              style: const TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w800,
                                  color: ChatStyle.ink)),
                          const SizedBox(height: 3),
                          const Text('Tap to view or change your photo',
                              style: TextStyle(
                                  fontSize: 13, color: ChatStyle.mist)),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded,
                        color: ChatStyle.mist),
                  ]),
                ),
              ),
            ),

            // ── Chats ────────────────────────────────────────────────────
            const _Header('Chats'),
            _Card(
              child: Column(children: [
                _Tile(
                  icon: Icons.format_size_rounded,
                  title: 'Message text size',
                  subtitle: sizeLabel,
                  onTap: _pickTextSize,
                ),
                const _Divider(),
                _SwitchTile(
                  icon: Icons.keyboard_return_rounded,
                  title: 'Enter key sends',
                  subtitle: 'Send with the keyboard instead of a new line',
                  value: _prefs.enterSends,
                  onChanged: _prefs.setEnterSends,
                ),
                const _Divider(),
                _Tile(
                  icon: Icons.bolt_rounded,
                  title: 'Chat shortcut keyword',
                  subtitle: 'Type it in an expense note to open chat',
                  onTap: widget.onChangeShortcutKeyword,
                ),
                const _Divider(),
                _SwitchTile(
                  icon: Icons.add_to_home_screen_rounded,
                  title: 'Home chat button',
                  subtitle: 'Show a chat button on the calendar screen',
                  value: provider.showHomeChatButton,
                  onChanged: provider.toggleHomeChatButton,
                ),
              ]),
            ),

            // ── Read aloud ───────────────────────────────────────────────
            const _Header('Read aloud'),
            _Card(
              child: Column(children: [
                _Tile(
                  icon: Icons.record_voice_over_rounded,
                  title: 'Voice',
                  subtitle: '${_tts.character.label} · '
                      '${_tts.useCloud ? 'Gemini voice' : 'Phone voice'}',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const VoiceSettingsScreen()),
                  ),
                ),
                const _Divider(),
                _SwitchTile(
                  icon: Icons.campaign_rounded,
                  title: 'Read new messages aloud',
                  subtitle: 'While a chat is open, with the phone voice',
                  value: _tts.autoRead,
                  onChanged: _tts.setAutoRead,
                ),
              ]),
            ),

            // ── Notifications ────────────────────────────────────────────
            const _Header('Notifications'),
            _Card(
              child: _Tile(
                icon: Icons.notifications_active_rounded,
                title: 'Notification sound',
                subtitle: 'Choose the tone for new messages',
                onTap: widget.onPickNotificationSound,
              ),
            ),

            // ── Storage ──────────────────────────────────────────────────
            const _Header('Storage'),
            _Card(
              child: _Tile(
                icon: Icons.cleaning_services_rounded,
                title: 'Clear cached media',
                subtitle: _cacheBytes == null
                    ? 'Calculating…'
                    : 'Using ${formatBytes(_cacheBytes!)} on this phone',
                trailing: _clearing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : null,
                onTap: _clearing ? null : _clearCache,
              ),
            ),

            // ── About ────────────────────────────────────────────────────
            const _Header('About'),
            _Card(
              child: Column(children: [
                _Tile(
                  icon: Icons.system_update_rounded,
                  title: 'Check for updates',
                  subtitle: _version.isEmpty ? '' : 'Version $_version',
                  trailing: _checkingUpdate
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : null,
                  onTap: _checkingUpdate ? null : _checkForUpdate,
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickTextSize() async {
    final picked = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Message text size',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            for (final (label, scale) in ChatPrefs.textSizes)
              ListTile(
                title: Text(label,
                    style: TextStyle(
                        fontSize: 15 * scale, fontWeight: FontWeight.w600)),
                subtitle: Text('Naan veetuku poren — see you soon',
                    style: TextStyle(fontSize: 13 * scale)),
                trailing: scale == _prefs.textScale
                    ? const Icon(Icons.check_circle_rounded,
                        color: ChatStyle.violet)
                    : null,
                onTap: () => Navigator.pop(ctx, scale),
              ),
          ]),
        ),
      ),
    );
    if (picked != null) await _prefs.setTextScale(picked);
  }
}

/// "12.4 MB"-style size for display.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

// ── Pieces ───────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 22, 6, 8),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
                color: ChatStyle.mist)),
      );
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: ChatStyle.bubbleShadow,
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(color: Colors.transparent, child: child),
      );
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => const Divider(
      height: 1, indent: 64, endIndent: 16, color: Color(0xFFEDEAF7));
}

class _IconBadge extends StatelessWidget {
  final IconData icon;
  const _IconBadge(this.icon);

  @override
  Widget build(BuildContext context) => Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: ChatStyle.violet.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(icon, color: ChatStyle.violet, size: 20),
      );
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        leading: _IconBadge(icon),
        title: Text(title,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700, color: ChatStyle.ink)),
        subtitle: subtitle.isEmpty
            ? null
            : Text(subtitle,
                style: const TextStyle(fontSize: 12.5, color: ChatStyle.mist)),
        trailing: trailing ??
            const Icon(Icons.chevron_right_rounded, color: ChatStyle.mist),
        onTap: onTap,
      );
}

class _SwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        secondary: _IconBadge(icon),
        title: Text(title,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700, color: ChatStyle.ink)),
        subtitle: Text(subtitle,
            style: const TextStyle(fontSize: 12.5, color: ChatStyle.mist)),
        value: value,
        activeThumbColor: Colors.white,
        activeTrackColor: ChatStyle.violet,
        onChanged: onChanged,
      );
}
