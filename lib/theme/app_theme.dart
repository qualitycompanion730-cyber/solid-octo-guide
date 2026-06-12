import 'package:flutter/material.dart';

class AppTheme {
  static const Color bgDark = Color(0xFF0D0D1A);
  static const Color bgCardLight = Color(0xFF1A1A2E);
  static const Color textPrimary = Color(0xFFF0F0F8);
  static const Color textSecondary = Color(0xFFB0B0C8);
  static const Color textMuted = Color(0xFF6B6B8A);
  static const Color divider = Color(0xFF2A2A40);

  static const LinearGradient bgGradient = LinearGradient(
    colors: [Color(0xFF0D0D1A), Color(0xFF141428)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}
