import 'package:flutter/material.dart';

/// ═══════════════════════════════════════════════════════════════════════
///  PulsingDotsIndicator
///  ───────────────────────────────────────────────────────────────────────
///  مؤشر "3 نقاط نابضة" يُستخدم في شاشات تحويل الملفات أثناء التقدّم.
///
///  هذا الويدجت كان مكرراً (نسخة طبق الأصل تقريباً) داخل private classes
///  بأسماء `_PulsingDots` في 5 ملفات مختلفة تحت lib/screens/tools/:
///  excel_to_pdf_screen.dart, html_to_pdf_screen.dart, ppt_to_pdf_screen.dart,
///  txt_to_pdf_screen.dart, word_to_pdf_screen.dart — مع اختلاف اللون فقط
///  بين نسخة وأخرى. تم توحيدها هنا في widget عام واحد بمعامل [color]
///  ليُستخدم من أي شاشة بأي لون مناسب لها.
/// ═══════════════════════════════════════════════════════════════════════
class PulsingDotsIndicator extends StatelessWidget {
  final AnimationController controller;
  final Color color;

  const PulsingDotsIndicator({
    super.key,
    required this.controller,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = (controller.value + i * 0.25) % 1.0;
            final opacity =
                (0.3 + 0.7 * (1 - (t - 0.5).abs() * 2)).clamp(0.0, 1.0);
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
