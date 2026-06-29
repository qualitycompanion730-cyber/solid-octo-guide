import 'dart:math' as math;

import 'package:flutter/material.dart';

/// ═══════════════════════════════════════════════════════════════════════
///  ProgressRingPainter
///  ───────────────────────────────────────────────────────────────────────
///  رسامة حلقة تقدّم متوهّجة (Sweep Gradient) تُستخدم في شاشات تحويل
///  الملفات أثناء التقدّم.
///
///  كانت مكررة (private class بالاسم `_ProgressRingPainter`) في 4 ملفات
///  تحت lib/screens/tools/: html_to_pdf_screen.dart, ppt_to_pdf_screen.dart,
///  txt_to_pdf_screen.dart, word_to_pdf_screen.dart. نسخة ppt كانت الوحيدة
///  المُفعَّلة فعلياً (مُستخدَمة في الشاشة)، والباقي كود ميت غير مُستخدَم.
///  تم توحيدها هنا في class عام واحد بمعاملات [accent]/[accentDeep]
///  ليُستخدم من أي شاشة بألوانها الخاصة.
/// ═══════════════════════════════════════════════════════════════════════
class ProgressRingPainter extends CustomPainter {
  final double progress;
  final double pulse;
  final Color accent;
  final Color accentDeep;
  final Color trackColor;

  ProgressRingPainter({
    required this.progress,
    required this.pulse,
    required this.accent,
    required this.accentDeep,
    this.trackColor = const Color(0xFF222A45),
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 6;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8,
    );

    final glow = 0.5 + 0.3 * math.sin(pulse * 2 * math.pi);
    final arcPaint = Paint()
      ..shader = SweepGradient(
        colors: [accent, Color.lerp(accent, accentDeep, 0.5)!, accent],
        startAngle: -math.pi / 2,
        endAngle: 3 * math.pi / 2,
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..maskFilter = MaskFilter.blur(BlurStyle.solid, 2 + glow * 2);

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.02, 1.0),
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(covariant ProgressRingPainter old) =>
      old.progress != progress || old.pulse != pulse;
}
