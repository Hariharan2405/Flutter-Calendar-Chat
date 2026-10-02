import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps this device's FCM token registered against the signed-in profile.
///
/// An FCM token identifies an app install, not a person. The profile document
/// used to hold a single `fcmToken` field, so signing in on a second phone
/// overwrote the first one's token and only the most recent device could ever
/// receive a notification. Tokens now live one-per-document under
/// `user_profiles/{uid}/devices`, so every device a profile is signed in on is
/// reachable at once.
class DeviceTokenService {
  DeviceTokenService._();

  static const _collection = 'devices';

  /// The token this device last registered, remembered across launches so a
  /// refreshed token can delete the document it replaces.
  static const _lastTokenKey = 'fcm_last_registered_token';

  /// The profile the token above was registered under, so switching profiles
  /// deregisters this device from the previous one.
  static const _lastProfileKey = 'fcm_last_registered_profile';

  static StreamSubscription<String>? _refreshSub;

  static CollectionReference<Map<String, dynamic>> _devices(String profileUid) =>
      FirebaseFirestore.instance
          .collection('user_profiles')
          .doc(profileUid)
          .collection(_collection);

  /// Firestore document ids may not contain '/'. FCM tokens normally don't,
  /// but the id is derived defensively so a malformed token cannot throw.
  static String _docId(String token) => token.replaceAll('/', '_');

  /// Registers this device for [profileUid] and keeps it registered when the
  /// token rotates. Safe to call repeatedly.
  static Future<void> register(String profileUid) async {
    if (profileUid.isEmpty) return;
    String? token;
    try {
      token = await FirebaseMessaging.instance.getToken();
    } catch (_) {
      return;
    }
    if (token == null || token.isEmpty) return;

    await _write(profileUid, token);

    // A rotated token leaves the old document behind, which would make the
    // server fan out to a dead address on every message until FCM rejects it.
    _refreshSub?.cancel();
    _refreshSub = FirebaseMessaging.instance.onTokenRefresh.listen((fresh) {
      _write(profileUid, fresh);
    });
  }

  static Future<void> _write(String profileUid, String token) async {
    final prefs = await SharedPreferences.getInstance();
    final previousToken = prefs.getString(_lastTokenKey);
    final previousProfile = prefs.getString(_lastProfileKey);

    try {
      await _devices(profileUid).doc(_docId(token)).set({
        'token': token,
        'platform': Platform.isAndroid ? 'android' : 'ios',
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      return; // Offline or rules not deployed — retried on next launch.
    }

    // Drop the previous registration for this device, whether it was the same
    // profile with an older token or a different profile entirely.
    if (previousToken != null &&
        previousProfile != null &&
        !(previousProfile == profileUid && previousToken == token)) {
      try {
        await _devices(previousProfile).doc(_docId(previousToken)).delete();
      } catch (_) {}
    }

    await prefs.setString(_lastTokenKey, token);
    await prefs.setString(_lastProfileKey, profileUid);
  }

  /// Removes this device from [profileUid]. Call on sign-out so a phone that
  /// is no longer signed in stops receiving that profile's notifications.
  static Future<void> unregister(String profileUid) async {
    _refreshSub?.cancel();
    _refreshSub = null;

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_lastTokenKey);
    if (token != null) {
      try {
        await _devices(profileUid).doc(_docId(token)).delete();
      } catch (_) {}
    }
    await prefs.remove(_lastTokenKey);
    await prefs.remove(_lastProfileKey);
  }
}
