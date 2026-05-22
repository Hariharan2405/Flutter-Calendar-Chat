import 'package:flutter/material.dart';
import '../constants/app_theme.dart';

extension SnackUtil on BuildContext {
  void showSuccess(String message) {
    ScaffoldMessenger.of(this)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Row(children: [
          const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ]),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 3),
      ));
  }

  void showError(String message) {
    ScaffoldMessenger.of(this)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Row(children: [
          const Icon(Icons.error_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ]),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 4),
      ));
  }
}
