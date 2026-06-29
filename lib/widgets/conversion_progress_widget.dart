// ═══════════════════════════════════════════════════════════════════════════
//  conversion_progress_widget.dart
//  ───────────────────────────────────────────────────────────────────────────
//  Widget مشترك لعرض حالة التحويل (تقدّم + مرحلة + إلغاء) يُستخدم في:
//    • word_to_pdf_screen   • excel_to_pdf_screen  • ppt_to_pdf_screen
//    • html_to_pdf_screen   • txt_to_pdf_screen
//
//  يقبل:
//    [progress]   نسبة التقدم من 0.0 إلى 1.0
//    [stage]      نص المرحلة الحالية (يتحرّك بـ AnimatedSwitcher)
//    [accentColor] لون مميّز لكل أداة (أحمر/أخضر/برتقالي/أزرق...)
//    [icon]       أيقونة مركز الحلقة
//    [title]      عنوان الكرت (مثل "جارٍ تحويل ملفك...")
//    [onCancel]   callback زر الإلغاء (null يخفي الزر)
//    [controller] AnimationController للنبض (يُمرَّر من الشاشة الأم)
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  الـ Widget الرئيسي
// ─────────────────────────────────────────────────────────────────────────────

class ConversionProgressWidget extends StatelessWidget {
  const ConversionProgressWidget({
    super.key,
    required this.progress,
    required this.stage,
    required this.accentColor,
    required this.icon,
    required this.title,
    required this.controller,
    this.onCancel,
    this.fileName,
  });

  final double progress;
  final String stage;
  final Color accentColor;
  final IconData icon;
  final String title;
  final AnimationController controller;
  final VoidCallback? onCancel;

  /// اسم الملف اختياري يظهر تحت العنوان بلون خافت
  final String? fileName;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey('converting'),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 28),
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            color: AppTheme.bgCard,
            border: Border.all(
              color: accentColor.withValues(alpha: 0.25),
            ),
            boxShadow: [
              BoxShadow(
                color: accentColor.withValues(alpha: 0.12),
                blurRadius: 40,
                spreadRadius: 2,
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 40,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── حلقة التقدم ──────────────────────────────────────────────
              SizedBox(
                width: 130,
                height: 130,
                child: AnimatedBuilder(
                  animation: controller,
                  builder: (context, _) {
                    return CustomPaint(
                      painter: _ProgressRingPainter(
                        progress: progress,
                        pulse: controller.value,
                        accentColor: accentColor,
                      ),
                      child: Center(
                        child: Container(
                          width: 70,
                          height: 70,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            color: accentColor.withValues(alpha: 0.15),
                            border: Border.all(
                              color: accentColor.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Icon(icon, color: accentColor, size: 34),
                        ),
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 24),

              // ── العنوان ──────────────────────────────────────────────────
              Text(
                title,
                textDirection: TextDirection.rtl,
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textPrimary,
                ),
              ),

              // ── اسم الملف (اختياري) ───────────────────────────────────
              if (fileName != null && fileName!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  fileName!,
                  textDirection: TextDirection.rtl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.cairo(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: accentColor,
                  ),
                ),
              ],

              const SizedBox(height: 10),

              // ── المرحلة الحالية (متحرّك) ──────────────────────────────
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  stage,
                  key: ValueKey(stage),
                  textDirection: TextDirection.rtl,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ),

              const SizedBox(height: 22),

              // ── النسبة + نقاط النبض ──────────────────────────────────
              Row(
                textDirection: TextDirection.rtl,
                children: [
                  _PulsingDots(controller: controller, color: accentColor),
                  const Spacer(),
                  Text(
                    '${(progress * 100).toInt()}%',
                    style: GoogleFonts.cairo(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: accentColor,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 8),

              // ── شريط التقدم ──────────────────────────────────────────
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: progress),
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeOut,
                  builder: (context, value, _) => LinearProgressIndicator(
                    value: value == 0 ? null : value,
                    minHeight: 8,
                    backgroundColor: AppTheme.bgCardLight,
                    valueColor: AlwaysStoppedAnimation(accentColor),
                  ),
                ),
              ),

              // ── زر الإلغاء ───────────────────────────────────────────
              if (onCancel != null) ...[
                const SizedBox(height: 20),
                GestureDetector(
                  onTap: onCancel,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      textDirection: TextDirection.rtl,
                      children: [
                        const Icon(Icons.close_rounded,
                            color: AppTheme.textMuted, size: 18),
                        const SizedBox(width: 6),
                        Text(
                          'إلغاء',
                          style: GoogleFonts.cairo(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  حلقة التقدم الدائرية (CustomPainter)
// ─────────────────────────────────────────────────────────────────────────────

class _ProgressRingPainter extends CustomPainter {
  final double progress;
  final double pulse;
  final Color accentColor;

  _ProgressRingPainter({
    required this.progress,
    required this.pulse,
    required this.accentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 6;

    // حلقة الخلفية
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = AppTheme.bgCardLight
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8,
    );

    // حلقة التقدم مع توهّج
    final glow = 0.5 + 0.3 * math.sin(pulse * 2 * math.pi);
    final accentDeep = Color.lerp(accentColor, Colors.white, 0.25)!;

    final arcPaint = Paint()
      ..shader = SweepGradient(
        colors: [accentColor, accentDeep, accentColor],
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
  bool shouldRepaint(covariant _ProgressRingPainter old) =>
      old.progress != progress ||
      old.pulse != pulse ||
      old.accentColor != accentColor;
}

// ─────────────────────────────────────────────────────────────────────────────
//  نقاط النبض (PulsingDots)
// ─────────────────────────────────────────────────────────────────────────────

class _PulsingDots extends StatelessWidget {
  final AnimationController controller;
  final Color color;

  const _PulsingDots({required this.controller, required this.color});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Row(
          children: List.generate(3, (i) {
            final t = (controller.value + i * 0.25) % 1.0;
            final opacity = 0.3 + 0.7 * (1 - (t - 0.5).abs() * 2).clamp(0.0, 1.0);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: opacity),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
