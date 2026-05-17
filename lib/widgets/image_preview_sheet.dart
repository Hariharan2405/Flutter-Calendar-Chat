import 'dart:io';
import 'package:flutter/material.dart';
import '../constants/app_theme.dart';

class ImagePreviewSheet extends StatelessWidget {
  final File imageFile;
  final Future<void> Function() onSend;

  const ImagePreviewSheet({
    super.key,
    required this.imageFile,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white38,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Text(
            'Preview',
            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              imageFile,
              width: MediaQuery.of(context).size.width - 48,
              fit: BoxFit.contain,
              height: MediaQuery.of(context).size.height * 0.48,
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: EdgeInsets.fromLTRB(
              24, 0, 24, MediaQuery.of(context).padding.bottom + 24,
            ),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white38),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(child: _SendButton(onSend: onSend)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SendButton extends StatefulWidget {
  final Future<void> Function() onSend;
  const _SendButton({required this.onSend});

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _sending = false;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: _sending
          ? null
          : () async {
              setState(() => _sending = true);
              try {
                await widget.onSend();
                if (context.mounted) Navigator.pop(context);
              } finally {
                if (mounted) setState(() => _sending = false);
              }
            },
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: _sending
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.send_rounded, color: Colors.white, size: 18),
                SizedBox(width: 8),
                Text('Send',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              ],
            ),
    );
  }
}
