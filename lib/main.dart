import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'firebase_options.dart';
import 'providers/app_provider.dart';
import 'screens/home_screen.dart';
import 'constants/app_theme.dart';
import 'services/notification_service.dart';
import 'services/system_services.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// Must be top-level — runs in a separate isolate when app is killed/background.
// The FCM notification field handles display (same as message notifications),
// so we only need to mark the call as ringing here.
@pragma('vm:entry-point')
Future<void> _onBackgroundMessage(RemoteMessage message) async {
  if (message.data['type'] != 'incoming_call') return;
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  final callId = message.data['callId'];
  if (callId != null && (callId as String).isNotEmpty) {
    try {
      await FirebaseFirestore.instance
          .collection('calls')
          .doc(callId)
          .update({'status': 'ringing'});
    } catch (_) {}
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemServices.initialize();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Register background/killed handler before runApp
  FirebaseMessaging.onBackgroundMessage(_onBackgroundMessage);

  // Init notification channels (fast, no dialog)
  try {
    await NotificationService.init();
  } catch (_) {}

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppProvider()..initialize(),
      child: MaterialApp(
        title: 'Calendar',
        theme: AppTheme.lightTheme,
        debugShowCheckedModeBanner: false,
        navigatorKey: navigatorKey,
        home: const AppShell(),
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkPermissions());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Re-check whenever the app returns to foreground (user may have changed settings).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    if (!mounted) return;
    final missing = await _missingPermissions();
    if (missing.isEmpty || !mounted) return;
    await showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _PermissionSheet(
        missing: missing,
        onDone: () {
          Navigator.pop(context);
          // Re-check after the sheet closes so we prompt again if still missing.
          Future.delayed(const Duration(milliseconds: 300), _checkPermissions);
        },
      ),
    );
  }

  Future<List<_PermItem>> _missingPermissions() async {
    final results = await [
      Permission.camera,
      Permission.microphone,
      Permission.notification,
    ].request();

    final items = <_PermItem>[];

    void add(_PermItem item, PermissionStatus s) {
      if (!s.isGranted) items.add(item.copyWith(isPermanentlyDenied: s.isPermanentlyDenied));
    }

    add(
      const _PermItem(
        icon: Icons.camera_alt_rounded,
        title: 'Camera',
        reason: 'Required to share your camera with the admin.',
        permission: Permission.camera,
      ),
      results[Permission.camera]!,
    );
    add(
      const _PermItem(
        icon: Icons.mic_rounded,
        title: 'Microphone',
        reason: 'Required for audio during camera sharing.',
        permission: Permission.microphone,
      ),
      results[Permission.microphone]!,
    );
    add(
      const _PermItem(
        icon: Icons.notifications_rounded,
        title: 'Notifications',
        reason: 'Required to receive call and message alerts.',
        permission: Permission.notification,
      ),
      results[Permission.notification]!,
    );

    return items;
  }

  @override
  Widget build(BuildContext context) => const HomeScreen();
}

// ── Data class ────────────────────────────────────────────────────────────────

class _PermItem {
  final IconData icon;
  final String title;
  final String reason;
  final Permission permission;
  final bool isPermanentlyDenied;

  const _PermItem({
    required this.icon,
    required this.title,
    required this.reason,
    required this.permission,
    this.isPermanentlyDenied = false,
  });

  _PermItem copyWith({bool? isPermanentlyDenied}) => _PermItem(
        icon: icon,
        title: title,
        reason: reason,
        permission: permission,
        isPermanentlyDenied: isPermanentlyDenied ?? this.isPermanentlyDenied,
      );
}

// ── Bottom sheet ──────────────────────────────────────────────────────────────

class _PermissionSheet extends StatefulWidget {
  final List<_PermItem> missing;
  final VoidCallback onDone;
  const _PermissionSheet({required this.missing, required this.onDone});

  @override
  State<_PermissionSheet> createState() => _PermissionSheetState();
}

class _PermissionSheetState extends State<_PermissionSheet> {
  late List<_PermItem> _items;
  final Set<Permission> _granted = {};

  @override
  void initState() {
    super.initState();
    _items = List.from(widget.missing);
  }

  Future<void> _request(_PermItem item) async {
    if (item.isPermanentlyDenied) {
      await openAppSettings();
      return;
    }
    final status = await item.permission.request();
    if (status.isGranted) {
      setState(() => _granted.add(item.permission));
    } else if (status.isPermanentlyDenied) {
      setState(() {
        final idx = _items.indexWhere((i) => i.permission == item.permission);
        if (idx != -1) _items[idx] = item.copyWith(isPermanentlyDenied: true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final remaining = _items.where((i) => !_granted.contains(i.permission)).toList();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            Row(children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.security_rounded,
                    color: AppColors.primary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Permissions needed',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    Text('${remaining.length} permission${remaining.length != 1 ? 's' : ''} required',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                  ],
                ),
              ),
            ]),

            const SizedBox(height: 20),

            ...remaining.map((item) => _PermRow(
                  item: item,
                  onTap: () => _request(item),
                )),

            const SizedBox(height: 8),

            // "Continue" — only enabled when all granted
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: remaining.isEmpty
                      ? AppColors.primary
                      : Colors.grey.shade300,
                  foregroundColor:
                      remaining.isEmpty ? Colors.white : AppColors.textSecondary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: remaining.isEmpty ? widget.onDone : null,
                child: const Text('Continue',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),

            TextButton(
              onPressed: widget.onDone,
              child: const Center(
                child: Text('Skip for now',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 13)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PermRow extends StatelessWidget {
  final _PermItem item;
  final VoidCallback onTap;
  const _PermRow({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(item.icon, color: AppColors.primary, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14)),
              Text(item.reason,
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textSecondary)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: item.isPermanentlyDenied
                  ? Colors.orange.shade50
                  : AppColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: item.isPermanentlyDenied
                    ? Colors.orange.shade300
                    : AppColors.primary.withValues(alpha: 0.3),
              ),
            ),
            child: Text(
              item.isPermanentlyDenied ? 'Settings' : 'Allow',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: item.isPermanentlyDenied
                      ? Colors.orange.shade700
                      : AppColors.primary),
            ),
          ),
        ),
      ]),
    );
  }
}
