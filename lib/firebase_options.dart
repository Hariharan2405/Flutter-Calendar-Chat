import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Web platform is not configured yet.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError(
          'Firebase is only configured for Android. '
          'Run flutterfire configure to add other platforms.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyBcPS9ShVeczBoRbT6infaJsV2HSGEPKl8',
    appId: '1:953075447228:android:887bd1f688e139be49a7b9',
    messagingSenderId: '953075447228',
    projectId: 'calendar-bc279',
    storageBucket: 'calendar-bc279.firebasestorage.app',
  );
}
