import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:provider/provider.dart';
import 'firebase_options.dart';
import 'providers/app_provider.dart';
import 'screens/home_screen.dart';
import 'constants/app_theme.dart';
import 'services/notification_service.dart';

// Must be top-level — runs in a separate isolate when app is killed/background
@pragma('vm:entry-point')
Future<void> _onBackgroundMessage(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await NotificationService.init();
  await NotificationService.showFcmNotification(message);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Register background/killed handler before runApp
  FirebaseMessaging.onBackgroundMessage(_onBackgroundMessage);

  await NotificationService.init();
  await NotificationService.requestPermission();

  // Foreground notifications are handled by the Firestore listener in AppProvider.
  // onMessage is intentionally not wired here to avoid duplicates.

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
