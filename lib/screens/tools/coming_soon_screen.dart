import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/app_theme.dart';

class ComingSoonScreen extends StatefulWidget {
  final dynamic tool; // ToolItem
  const ComingSoonScreen({super.key, required this.tool});

  @override
  State<ComingSoonScreen> createState() => _ComingSoonScreenState();
}

class _ComingSoonScreenState extends State<ComingSoonScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulse = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tool = widget.tool;

    return Scaffold(
      backgroundColor: isDark ? AppTheme.bgDark : const Color(0xFFF5F5FF),
      body: Container(
        decoration: BoxDecoration(
          gradient: isDark
              ? AppTheme.bgGradient
              : const LinearGradient(
                  colors: [Color(0xFFF5F5FF), Color(0xFFEEEEFF)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        width: 42, height: 42,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: isDark ? AppTheme.bgCardLight : Colors.white,
                          border: Border.all(color: AppTheme.divider),
                        ),
                        child: const Icon(Icons.arrow_back_ios_new_rounded,
                            size: 18, color: AppTheme.textSecondary),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      tool.title,
                      style: GoogleFonts.cairo(
                        fontSize: 20, fontWeight: FontWeight.w800,
                        color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedBuilder(
                          animation: _pulse,
                          builder: (_, child) => Transform.scale(
                            scale: 1.0 + (_pulse.value * 0.06),
                            child: child,
                          ),
                          child: Container(
                            width: 120, height: 120,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                colors: [tool.color, tool.colorLight],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: tool.color.withValues(alpha: 0.4),
                                  blurRadius: 40, spreadRadius: 5,
                                ),
                              ],
                            ),
                            child: Icon(tool.icon, color: Colors.white, size: 52),
                          ),
                        ),
                        const SizedBox(height: 32),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(50),
                            gradient: AppTheme.primaryGradient,
                          ),
                          child: Text(
                            'قريباً جداً 🚀',
                            style: GoogleFonts.cairo(
                              fontSize: 13, fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          tool.title,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.cairo(
                            fontSize: 26, fontWeight: FontWeight.w900,
                            color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'نعمل بجهد لإتاحة هذه الميزة الرائعة.\nستحصل على إشعار فور إطلاقها!',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.cairo(
                            fontSize: 15, color: AppTheme.textSecondary,
                            height: 1.7,
                          ),
                        ),
                        const SizedBox(height: 40),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () {
                              HapticFeedback.lightImpact();
                              Navigator.pop(context);
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.primary,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16)),
                            ),
                            child: Text('العودة للرئيسية',
                                style: GoogleFonts.cairo(
                                    fontSize: 16, fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
