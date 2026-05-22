import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const _channelId = 'tn_calendar_chat';
  static const _channelName = 'Calendar';
  // v4 channel: fresh creation with system ringtone URI (falls back to default sound on failure)
  static const _callChannelId = 'tn_calendar_call_v4';
  static const _callChannelName = 'Incoming Calls';
  static const _ongoingChannelId = 'tn_calendar_ongoing';
  static const _ongoingChannelName = 'Active Call';
  static const _callNotificationId = 99;
  static const _ongoingCallNotificationId = 98;

  // AppProvider sets these to handle notification taps
  static void Function(Map<String, String> data)? onCallNotificationTap;
  static void Function()? onOngoingCallNotificationTap;

  static Future<void> init() async {
    const android = AndroidInitializationSettings('@drawable/ic_notification');
    await _plugin.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: _onNotificationTap,
    );

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        importance: Importance.high,
      ),
    );

    // Try system ringtone URI; fall back to default sound if the URI is unsupported.
    try {
      await androidPlugin?.createNotificationChannel(
        const AndroidNotificationChannel(
          _callChannelId,
          _callChannelName,
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
          sound: UriAndroidNotificationSound('content://settings/system/ringtone'),
        ),
      );
    } catch (_) {
      await androidPlugin?.createNotificationChannel(
        const AndroidNotificationChannel(
          _callChannelId,
          _callChannelName,
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        ),
      );
    }

    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _ongoingChannelId,
        _ongoingChannelName,
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
      ),
    );
  }

  static void _onNotificationTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null) return;
    try {
      final data = Map<String, String>.from(jsonDecode(payload) as Map);
      if (data['type'] == 'incoming_call') {
        onCallNotificationTap?.call(data);
      } else if (data['type'] == 'ongoing_call') {
        onOngoingCallNotificationTap?.call();
      }
    } catch (_) {}
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
    await _show('Calendar', ' ');
  }

  // Called by FCM handler (foreground / background / killed)
  static Future<void> showFcmNotification(RemoteMessage message) async {
    final title = message.notification?.title ?? 'Calendar';
    final body = message.notification?.body ?? ' ';
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

  // Shows a full-screen call notification (plays ringtone + wakes screen).
  // Payload is JSON so the tap handler can navigate to IncomingCallScreen.
  static Future<void> showIncomingCallNotification({
    required String callerName,
    required String callId,
    required String callerId,
    required bool isVideo,
  }) async {
    final payload = jsonEncode({
      'type': 'incoming_call',
      'callId': callId,
      'callerId': callerId,
      'callerName': callerName,
      'callType': isVideo ? 'video' : 'voice',
    });
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _callChannelId,
        _callChannelName,
        importance: Importance.max,
        priority: Priority.max,
        fullScreenIntent: true,
        playSound: true,
        enableVibration: true,
        category: AndroidNotificationCategory.call,
        ongoing: true,
        autoCancel: false,
      ),
    );
    await _plugin.show(
      _callNotificationId,
      'Calendar',
      'Calling from your calendar, track expenses wisely!',
      details,
      payload: payload,
    );
  }

  static Future<void> cancelCallNotification() async {
    await _plugin.cancel(_callNotificationId);
  }

  static Future<void> showOngoingCallNotification({
    required String otherUserName,
    required String callId,
  }) async {
    final payload = jsonEncode({'type': 'ongoing_call', 'callId': callId});
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _ongoingChannelId,
        _ongoingChannelName,
        importance: Importance.low,
        priority: Priority.low,
        playSound: false,
        enableVibration: false,
        ongoing: true,
        autoCancel: false,
        showWhen: false,
      ),
    );
    await _plugin.show(
      _ongoingCallNotificationId,
      'Calendar — Voice call in progress',
      'Tap to return to your call',
      details,
      payload: payload,
    );
  }

  static Future<void> cancelOngoingCallNotification() async {
    await _plugin.cancel(_ongoingCallNotificationId);
  }

  // Returns call data if the app was launched by tapping a call notification
  // (killed-state path). Null if app was opened normally.
  static Future<Map<String, String>?> getCallLaunchData() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    final payload = details!.notificationResponse?.payload;
    if (payload == null) return null;
    try {
      final data = Map<String, String>.from(jsonDecode(payload) as Map);
      return data['type'] == 'incoming_call' ? data : null;
    } catch (_) {
      return null;
    }
  }
}
