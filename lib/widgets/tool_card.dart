import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

class ToolCard extends StatelessWidget {
  final ToolItem tool;
  final VoidCallback onTap;

  const ToolCard({super.key, required this.tool, required this.onTap});

  bool get _isComingSoon => tool.category == 'قريباً';

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: isDark ? AppTheme.bgCardLight : Colors.white,
          border: Border.all(color: _isComingSoon ? AppTheme.divider.withValues(alpha: 0.3) : tool.color.withValues(alpha: 0.2)),
          boxShadow: [BoxShadow(color: tool.color.withValues(alpha: 0.1), blurRadius: 16, offset: const Offset(0, 6))],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 50, height: 50,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: _isComingSoon
                      ? const LinearGradient(colors: [AppTheme.bgCard, AppTheme.bgSurface])
                      : LinearGradient(colors: [tool.color, tool.colorLight], begin: Alignment.topLeft, end: Alignment.bottomRight),
                  boxShadow: _isComingSoon ? [] : [BoxShadow(color: tool.color.withValues(alpha: 0.3), blurRadius: 8)],
                ),
                child: Icon(tool.icon, color: _isComingSoon ? AppTheme.textMuted : Colors.white, size: 24),
              ),
              const Spacer(),
              if (_isComingSoon)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), color: AppTheme.bgSurface),
                  child: Text('قريباً', style: GoogleFonts.cairo(fontSize: 9, fontWeight: FontWeight.w700, color: AppTheme.textMuted)),
                )
              else
                Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: tool.color.withValues(alpha: 0.1)),
                  child: Icon(Icons.arrow_forward_ios_rounded, size: 12, color: tool.color),
                ),
            ]),
            const SizedBox(height: 12),
            Text(tool.title, style: GoogleFonts.cairo(fontSize: 14, fontWeight: FontWeight.w800, color: _isComingSoon ? AppTheme.textMuted : isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E)), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 3),
            Text(tool.subtitle, style: GoogleFonts.cairo(fontSize: 11, color: AppTheme.textMuted, height: 1.4), maxLines: 2, overflow: TextOverflow.ellipsis),
          ]),
        ),
      ),
    );
  }
}
