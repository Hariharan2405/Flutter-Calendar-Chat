import 'package:flutter/material.dart';
import '../constants/app_theme.dart';
import '../services/update_service.dart';

/// "Update available" dialog for sideloaded builds. Shows the changelog and a
/// download-progress bar, then hands off to the system installer. A forced
/// update ([UpdateInfo.force]) can't be dismissed.
class UpdateDialog extends StatefulWidget {
  final UpdateInfo info;
  const UpdateDialog({super.key, required this.info});

  static Future<void> show(BuildContext context, UpdateInfo info) {
    return showDialog(
      context: context,
      barrierDismissible: !info.force,
      builder: (_) => UpdateDialog(info: info),
    );
  }

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _downloading = false;
  double _progress = -1;
  String? _error;

  Future<void> _start() async {
    setState(() {
      _downloading = true;
      _error = null;
      _progress = -1;
    });
    try {
      await for (final p in UpdateService.downloadAndInstall(widget.info.apkUrl)) {
        if (mounted) setState(() => _progress = p);
      }
      // Installer launched — leave the dialog up (the OS install prompt is now
      // on top). Nothing else to do.
    } catch (_) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _error = 'Download failed. Check your connection and try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    return PopScope(
      canPop: !info.force,
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.system_update_rounded, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                info.force ? 'Update required' : 'Update available',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (info.version.isNotEmpty)
              Text('Version ${info.version}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary)),
            if (info.notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(info.notes,
                  style: const TextStyle(fontSize: 13, height: 1.4)),
            ],
            if (_downloading) ...[
              const SizedBox(height: 18),
              LinearProgressIndicator(
                value: _progress >= 0 ? _progress : null,
                backgroundColor: AppColors.divider,
                color: AppColors.primary,
              ),
              const SizedBox(height: 6),
              Text(
                _progress >= 0
                    ? 'Downloading… ${(_progress * 100).toStringAsFixed(0)}%'
                    : 'Downloading…',
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textSecondary),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12)),
            ],
          ],
        ),
        actions: _downloading
            ? null
            : [
                if (!info.force)
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Later'),
                  ),
                ElevatedButton(
                  onPressed: _start,
                  child: Text(_error != null ? 'Retry' : 'Update'),
                ),
              ],
      ),
    );
  }
}
