import 'package:firebase_auth/firebase_auth.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  User? get currentUser => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<UserCredential> signInAnonymously() async {
    return await _auth.signInAnonymously();
  }

  Future<void> signOut() async {
    await _auth.signOut();
  }

  Future<String> ensureSignedIn() async {
    if (_auth.currentUser == null) {
      await signInAnonymously();
    }
    return _auth.currentUser!.uid;
  }

  // Converts a profile name to a safe fake email used as a Firebase Auth credential.
  static String _toEmail(String name) =>
      '${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')}@cal.local';

  // Called once when a profile is created — links the current anonymous Firebase
  // Auth account to email/password so the same UID can be restored after reinstall.
  // Requires Email/Password sign-in enabled in Firebase Console → Authentication.
  Future<void> linkProfileCredential(String name, String password) async {
    final user = _auth.currentUser;
    if (user == null || !user.isAnonymous) return;
    try {
      await user.linkWithCredential(
        EmailAuthProvider.credential(
          email: _toEmail(name),
          password: password,
        ),
      );
    } catch (_) {}
  }

  // Called when logging back in with an existing profile after reinstall.
  // Returns the restored original UID on success, null if not yet linked
  // (e.g. profile was created before this feature or Email/Password auth is disabled).
  Future<String?> signInWithProfile(String name, String password) async {
    try {
      final result = await _auth.signInWithEmailAndPassword(
        email: _toEmail(name),
        password: password,
      );
      return result.user!.uid;
    } catch (_) {
      return null;
    }
  }
}
