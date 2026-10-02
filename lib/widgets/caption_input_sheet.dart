import 'dart:io';
import 'package:flutter/material.dart';
import '../constants/app_theme.dart';

/// Bottom sheet that lets the user add an optional caption before sending a
/// video. Returns the caption (possibly empty) when the user taps send, or
/// null if they dismissed the sheet without sending.
Future<String?> showCaptionSheet(
  BuildContext context, {
  String? thumbnailPath,
}) {
  final ctrl = TextEditingController();
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
        left: 14,
        right: 10,
        top: 14,
        bottom: MediaQuery.of(ctx).viewInsets.bottom + 14,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.black12,
              borderRadius: BorderRadius.circular(8),
              image: thumbnailPath != null
                  ? DecorationImage(
                      image: FileImage(File(thumbnailPath)), fit: BoxFit.cover)
                  : null,
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.videocam_rounded,
                color: Colors.white, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: ctrl,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'Add a caption…',
                border: InputBorder.none,
              ),
            ),
          ),
          const SizedBox(width: 6),
          CircleAvatar(
            backgroundColor: AppColors.primary,
            child: IconButton(
              icon: const Icon(Icons.send_rounded, color: Colors.white),
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            ),
          ),
        ],
      ),
    ),
  );
}
