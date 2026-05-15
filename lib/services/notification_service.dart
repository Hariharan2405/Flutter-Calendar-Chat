import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const _channelId = 'tn_calendar_chat';
  static const _channelName = 'TN Calendar';

  static Future<void> init() async {
    const android = AndroidInitializationSettings('@drawable/ic_launcher');
    await _plugin.initialize(const InitializationSettings(android: android));

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            importance: Importance.high,
          ),
        );
  }

  static Future<void> requestPermission() async {
    await Permission.notification.request();
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  static Future<String?> getToken() async {
    return FirebaseMessaging.instance.getToken();
  }

  // Called by Firestore listener when app is in foreground
  static Future<void> showNewMessage() async {
    await _show('TN Calendar', 'You have a new message');
  }

  // Called by FCM handler (foreground / background / killed)
  static Future<void> showFcmNotification(RemoteMessage message) async {
    final title = message.notification?.title ?? 'TN Calendar';
    final body = message.notification?.body ?? 'You have a new message';
    await _show(title, body);
  }

  static Future<void> _show(String title, String body) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
      ),
    );
    await _plugin.show(1, title, body, details);
  }
}
