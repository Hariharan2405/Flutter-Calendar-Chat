import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  static const Color primary = Color(0xFF5C35D1);
  static const Color primaryLight = Color(0xFF7B57E0);
  static const Color primaryDark = Color(0xFF3D1FA8);
  static const Color accent = Color(0xFFFF6B35);
  static const Color accentLight = Color(0xFFFF8A5B);
  static const Color background = Color(0xFFF4F2FF);
  static const Color surface = Colors.white;
  static const Color holiday = Color(0xFFE53935);
  static const Color holidayBg = Color(0xFFFFEBEE);
  static const Color noteIndicator = Color(0xFF1E88E5);
  static const Color expenseIndicator = Color(0xFF43A047);
  static const Color textPrimary = Color(0xFF1A1A2E);
  static const Color textSecondary = Color(0xFF6B6B8A);
  static const Color divider = Color(0xFFE0DCFF);
  static const Color cardShadow = Color(0x1A5C35D1);

  static const List<Color> categoryColors = [
    Color(0xFFE53935),
    Color(0xFF8E24AA),
    Color(0xFF1E88E5),
    Color(0xFF00ACC1),
    Color(0xFF43A047),
    Color(0xFFFFB300),
    Color(0xFFFF6B35),
    Color(0xFF6D4C41),
    Color(0xFF546E7A),
    Color(0xFF00897B),
  ];
}

class AppTheme {
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        brightness: Brightness.light,
      ).copyWith(
        primary: AppColors.primary,
        secondary: AppColors.accent,
        surface: AppColors.surface,
        surfaceContainerHighest: AppColors.background,
      ),
      textTheme: GoogleFonts.poppinsTextTheme(),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: GoogleFonts.poppins(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.background,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primary, width: 2),
        ),
        labelStyle: const TextStyle(color: AppColors.textSecondary),
      ),
    );
  }
}
