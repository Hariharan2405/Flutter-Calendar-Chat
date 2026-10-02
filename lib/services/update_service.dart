import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'system_services.dart';

/// Details of an available in-app update.
class UpdateInfo {
  final String version; // display name, e.g. "1.1.0"
  final int build; // versionCode / build number
  final String apkUrl; // direct download URL (Firebase Storage)
  final String notes; // changelog shown to the user
  final bool force; // true when the current build is below minSupportedBuild

  const UpdateInfo({
    required this.version,
    required this.build,
    required this.apkUrl,
    required this.notes,
    required this.force,
  });
}

/// Checks Firestore for a newer APK and downloads + installs it (sideloaded
/// distribution — no Play Store). The "latest" metadata lives in
/// `version_info/latest`; the APK itself is hosted on Firebase Storage.
class UpdateService {
  /// Returns update details when a newer build is available, else null.
  /// Android only (iOS can't sideload-install an APK).
  static Future<UpdateInfo?> checkForUpdate() async {
    if (!Platform.isAndroid) return null;
    try {
      // The version doc requires auth (Firestore rules). On a fresh launch the
      // update check can race the anonymous sign-in, so wait for it first.
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuth.instance
            .authStateChanges()
            .firstWhere((u) => u != null)
            .timeout(const Duration(seconds: 15));
      }

      final info = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(info.buildNumber) ?? 0;

      final doc = await FirebaseFirestore.instance
          .collection('version_info')
          .doc('latest')
          .get();
      final data = doc.data();
      if (data == null) return null;

      final latestBuild = (data['latestBuild'] as num?)?.toInt() ?? 0;
      final apkUrl = (data['apkUrl'] as String?) ?? '';
      if (latestBuild <= currentBuild || apkUrl.isEmpty) return null;

      final minSupported = (data['minSupportedBuild'] as num?)?.toInt() ?? 0;
      return UpdateInfo(
        version: (data['latestVersion'] as String?) ?? '',
        build: latestBuild,
        apkUrl: apkUrl,
        notes: (data['notes'] as String?) ?? '',
        force: currentBuild < minSupported,
      );
    } catch (_) {
      return null;
    }
  }

  /// Human-readable diagnostic of the update check — used by the manual
  /// "check for updates" action to reveal exactly what the app sees.
  static Future<String> diagnose() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(info.buildNumber) ?? -1;
      final signedIn = FirebaseAuth.instance.currentUser != null;
      final doc = await FirebaseFirestore.instance
          .collection('version_info')
          .doc('latest')
          .get();
      if (!doc.exists) {
        return 'Signed in: $signedIn\nCurrent build: ${info.buildNumber}\n'
            'version_info/latest: NOT FOUND';
      }
      final d = doc.data()!;
      final latestBuild = (d['latestBuild'] as num?)?.toInt();
      final apkUrl = (d['apkUrl'] as String?) ?? '';
      return 'Signed in: $signedIn\n'
          'Current build: $currentBuild (raw "${info.buildNumber}")\n'
          'latestBuild: $latestBuild\n'
          'apkUrl set: ${apkUrl.isNotEmpty}\n'
          'Update should show: ${latestBuild != null && latestBuild > currentBuild && apkUrl.isNotEmpty}';
    } catch (e) {
      return 'ERROR reading update info:\n$e';
    }
  }

  /// Downloads the APK to the cache dir, reporting progress as a 0..1 fraction
  /// (or -1 when the total size is unknown), then launches the installer.
  /// Throws on failure so the UI can show an error.
  static Stream<double> downloadAndInstall(String url) async* {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url));
      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        throw Exception('Download failed (${resp.statusCode})');
      }

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/update.apk');
      final sink = file.openWrite();
      final total = resp.contentLength ?? -1;
      int received = 0;

      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        yield total > 0 ? received / total : -1.0;
      }
      await sink.flush();
      await sink.close();

      final launched = await SystemServices.installApk(file.path);
      if (!launched) throw Exception('Could not launch installer');
      yield 1.0;
    } finally {
      client.close();
    }
  }
}
