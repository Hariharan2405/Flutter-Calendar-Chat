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

  /// Starts the call foreground service. [isVideo] decides the foreground
  /// service type: a video call declares camera + microphone, an audio call
  /// declares microphone only. On Android 14+ declaring the camera type without
  /// the camera permission granted throws and the mic loses background access.
  static Future<void> startCallService(String otherUserName,
      {bool isVideo = false}) async {
    try {
      await _channel.invokeMethod('startCallService', {
        'name': otherUserName,
        'isVideo': isVideo,
      });
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

  /// Copies a local audio file into the public Music/Calendar folder so it is
  /// visible in the file manager and music apps. Returns the saved destination
  /// string, or null on failure.
  static Future<String?> saveAudioToMusic({
    required String path,
    required String name,
    required String mime,
  }) async {
    try {
      return await _channel.invokeMethod<String?>('saveAudioToMusic', {
        'path': path,
        'name': name,
        'mime': mime,
      });
    } catch (_) {
      return null;
    }
  }

  /// Copies a local file into the public MediaStore collection for [kind]
  /// ('image' → Pictures/Calendar, 'video' → Movies/Calendar,
  /// 'audio' → Music/Calendar). Returns the saved content URI string (used to
  /// later verify the file still exists), or null on failure.
  static Future<String?> saveMediaToStore({
    required String path,
    required String name,
    required String mime,
    required String kind,
  }) async {
    try {
      return await _channel.invokeMethod<String?>('saveMediaToStore', {
        'path': path,
        'name': name,
        'mime': mime,
        'kind': kind,
      });
    } catch (_) {
      return null;
    }
  }

  /// Launches the system installer for a downloaded APK at [path]. Returns true
  /// if the installer was launched.
  static Future<bool> installApk(String path) async {
    try {
      return await _channel.invokeMethod<bool>('installApk', path) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the device's text-to-speech settings, where voice data for a
  /// language (Tamil, for instance) can be downloaded. Returns false if no
  /// such screen exists on this device.
  static Future<bool> openTtsSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openTtsSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// True if a previously-saved media file (by content URI) still exists on the
  /// device — false if the user has deleted it.
  static Future<bool> mediaUriExists(String? uri) async {
    if (uri == null || uri.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('mediaUriExists', uri) ?? false;
    } catch (_) {
      return false;
    }
  }
}
