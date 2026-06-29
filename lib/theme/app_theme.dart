import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // ==================== Color Palette ====================
  static const Color primary       = Color(0xFF6C63FF);
  static const Color primaryDark   = Color(0xFF4B44CC);
  static const Color primaryLight  = Color(0xFF9D97FF);
  static const Color secondary     = Color(0xFFFF6584);
  static const Color accent        = Color(0xFF43D9AD);
  static const Color accentOrange  = Color(0xFFFF8C42);

  static const Color bgDark       = Color(0xFF0D0D1A);
  static const Color bgCard       = Color(0xFF16162A);
  static const Color bgCardLight  = Color(0xFF1E1E38);
  static const Color bgSurface    = Color(0xFF252545);

  static const Color textPrimary   = Colors.white;
  static const Color textSecondary = Color(0xFFB0AECF);
  static const Color textMuted     = Color(0xFF6B6A8E);
  static const Color divider       = Color(0xFF2A2A4A);

  // ==================== Gradients ====================
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [Color(0xFF6C63FF), Color(0xFF9D50FF)],
    begin: Alignment.topLeft, end: Alignment.bottomRight,
  );
  static const LinearGradient bgGradient = LinearGradient(
    colors: [Color(0xFF0D0D1A), Color(0xFF12122A), Color(0xFF0D1628)],
    begin: Alignment.topCenter, end: Alignment.bottomCenter,
  );
  static const LinearGradient splashGradient = LinearGradient(
    colors: [Color(0xFF0A0A1E), Color(0xFF1A1040), Color(0xFF0D1628)],
    begin: Alignment.topLeft, end: Alignment.bottomRight,
  );
  static const LinearGradient cardGradient = LinearGradient(
    colors: [Color(0xFF1E1E38), Color(0xFF16162A)],
    begin: Alignment.topLeft, end: Alignment.bottomRight,
  );

  // ==================== Light Theme ====================
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true, brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFF5F5FF),
      colorScheme: const ColorScheme.light(primary: primary, secondary: secondary, surface: Color(0xFFECECFF), onPrimary: Colors.white, onSecondary: Colors.white, onSurface: Color(0xFF1A1A2E)),
      textTheme: GoogleFonts.cairoTextTheme().copyWith(
        displayLarge: GoogleFonts.cairo(fontSize: 32, fontWeight: FontWeight.w800, color: const Color(0xFF1A1A2E)),
        titleLarge: GoogleFonts.cairo(fontSize: 20, fontWeight: FontWeight.w700, color: const Color(0xFF1A1A2E)),
        bodyLarge: GoogleFonts.cairo(fontSize: 16, color: const Color(0xFF4A4A6A)),
        bodyMedium: GoogleFonts.cairo(fontSize: 14, color: const Color(0xFF4A4A6A)),
      ),
      appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, elevation: 0, centerTitle: true),
      elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(backgroundColor: primary, foregroundColor: Colors.white, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(14))))),
    );
  }

  // ==================== Dark Theme ====================
  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true, brightness: Brightness.dark,
      scaffoldBackgroundColor: bgDark,
      colorScheme: const ColorScheme.dark(primary: primary, secondary: secondary, surface: bgCard, onPrimary: Colors.white, onSecondary: Colors.white, onSurface: textPrimary),
      textTheme: GoogleFonts.cairoTextTheme(ThemeData.dark().textTheme).copyWith(
        displayLarge: GoogleFonts.cairo(fontSize: 32, fontWeight: FontWeight.w800, color: textPrimary),
        titleLarge: GoogleFonts.cairo(fontSize: 20, fontWeight: FontWeight.w700, color: textPrimary),
        bodyLarge: GoogleFonts.cairo(fontSize: 16, color: textSecondary),
        bodyMedium: GoogleFonts.cairo(fontSize: 14, color: textSecondary),
      ),
      appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, elevation: 0, centerTitle: true, iconTheme: IconThemeData(color: textPrimary)),
      elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(backgroundColor: primary, foregroundColor: Colors.white, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(14))))),
     cardTheme: CardThemeData(
  color: bgCard,
  elevation: 0,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(16),
  ),
),
      inputDecorationTheme: InputDecorationTheme(filled: true, fillColor: bgCardLight, border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none), focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: primary, width: 1.5))),
    );
  }
}

// ==================== Tool Card Data Model ====================
class ToolItem {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final Color colorLight;
  final String route;
  final String category;

  const ToolItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.colorLight,
    required this.route,
    this.category = 'الكل',
  });
}
