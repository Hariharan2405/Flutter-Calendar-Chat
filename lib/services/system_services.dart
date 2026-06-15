import 'package:flutter/services.dart';

class SystemServices {
  static const _channel = MethodChannel('com.calendar_app/system');

  // Set by CallScreen to know when the OS enters/exits PiP mode
  static void Function(bool isInPip)? onPipModeChanged;

  // Set by AppProvider to navigate back to an active call
  static void Function()? onReturnToCall;

  // Call once at app start so the channel can receive native → Flutter messages
  static void initialize() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPipModeChanged') {
        onPipModeChanged?.call(call.arguments as bool);
      } else if (call.method == 'returnToCall') {
        onReturnToCall?.call();
      }
    });
  }

  static Future<void> startRingtone() async {
    try {
      await _channel.invokeMethod('startRingtone');
    } catch (_) {}
  }

  static Future<void> stopRingtone() async {
    try {
      await _channel.invokeMethod('stopRingtone');
    } catch (_) {}
  }

  static Future<void> setPipEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod('setPipEnabled', enabled);
    } catch (_) {}
  }

  static Future<void> enterPip() async {
    try {
      await _channel.invokeMethod('enterPip');
    } catch (_) {}
  }

  static Future<void> startCallService(String otherUserName) async {
    try {
      await _channel.invokeMethod('startCallService', otherUserName);
    } catch (_) {}
  }

  /// Starts the foreground service with a silent (invisible) notification.
  /// Use this for camera sharing — the service keeps the process alive and
  /// grants camera/mic access in background without showing a status-bar icon.
  static Future<void> startCameraShareService() async {
    try {
      await _channel.invokeMethod('startCameraShareService');
    } catch (_) {}
  }

  static Future<void> stopCallService() async {
    try {
      await _channel.invokeMethod('stopCallService');
    } catch (_) {}
  }

  /// Dismisses the system PiP window by sending the task to the background.
  /// Call this when the call ends while the app is in system PiP mode.
  static Future<void> closePip() async {
    try {
      await _channel.invokeMethod('closePip');
    } catch (_) {}
  }

  /// Opens Android's ringtone picker filtered to notification sounds.
  /// Returns the selected URI string, null for "Silent", or throws on cancel/error.
  static Future<String?> pickNotificationSound({String? currentUri}) async {
    return _channel.invokeMethod<String?>('pickNotifSound', currentUri);
  }

  /// Plays a notification sound by content URI via RingtoneManager.
  /// Pass null or empty string to play the system default notification sound.
  static Future<void> playNotificationSound(String? uri) async {
    try {
      await _channel.invokeMethod('playNotifSound', uri ?? '');
    } catch (_) {}
  }

  static Future<void> stopNotificationSound() async {
    try {
      await _channel.invokeMethod('stopNotifSound');
    } catch (_) {}
  }
}
