import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
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

  // Request permissions after first frame — avoids blocking startup in release
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await NotificationService.requestPermission();
  });
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

class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    return const HomeScreen();
  }
}
