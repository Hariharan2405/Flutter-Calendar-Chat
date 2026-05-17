import 'package:flutter/services.dart';

class SystemServices {
  static const _channel = MethodChannel('com.calendar_app/system');

  // Set by CallScreen to know when the OS enters/exits PiP mode
  static void Function(bool isInPip)? onPipModeChanged;

  // Call once at app start so the channel can receive native → Flutter messages
  static void initialize() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPipModeChanged') {
        onPipModeChanged?.call(call.arguments as bool);
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
}
