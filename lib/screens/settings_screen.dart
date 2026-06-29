import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/theme_provider.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  // ⚠️ تحسين حقيقي: رقم التواصل كان نصاً ثابتاً غير قابل لأي تفاعل (لا
  // نسخ، لا اتصال) — معلومة معروضة لكنها كود عملياً ميت من ناحية
  // الاستخدام الفعلي. الآن يُمكن نسخه بنقرة واحدة عبر Clipboard (بلا
  // حاجة لحزمة جديدة كـ url_launcher لمجرد هذا).
  static const String _developerPhone = '780436359';

  Future<void> _copyPhone(BuildContext context) async {
    await Clipboard.setData(const ClipboardData(text: _developerPhone));
    HapticFeedback.lightImpact();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('تم نسخ الرقم', style: GoogleFonts.cairo(fontSize: 13)),
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppTheme.primary,
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppTheme.bgDark : const Color(0xFFF5F5FF),
      body: Container(
        decoration: BoxDecoration(
          gradient: isDark
              ? AppTheme.bgGradient
              : const LinearGradient(
                  colors: [Color(0xFFF5F5FF), Color(0xFFEEEEFF)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter),
        ),
        child: SafeArea(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(children: [
                Semantics(
                  button: true,
                  label: 'رجوع',
                  child: GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: isDark ? AppTheme.bgCardLight : Colors.white,
                              border: Border.all(color: AppTheme.divider)),
                          child: const Icon(Icons.arrow_back_ios_new_rounded,
                              size: 18, color: AppTheme.textSecondary))),
                ),
                const SizedBox(width: 16),
                Text('الإعدادات',
                    style: GoogleFonts.cairo(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: isDark
                            ? AppTheme.textPrimary
                            : const Color(0xFF1A1A2E))),
              ])),
          Expanded(
              child: ListView(padding: const EdgeInsets.all(20), children: [
            _Section(title: 'المظهر', isDark: isDark, children: [
              _SettingsTile(
                isDark: isDark,
                icon:
                    isDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                iconColor:
                    isDark ? const Color(0xFF9F7AEA) : const Color(0xFFECC94B),
                title: 'الوضع الليلي',
                subtitle: isDark ? 'مفعّل' : 'غير مفعّل',
                trailing: Switch.adaptive(
                    value: isDark,
                    onChanged: (_) {
                      HapticFeedback.selectionClick();
                      // ⚠️ إصلاح: toggleTheme أصبحت async (تحفظ الاختيار في
                      // SharedPreferences الآن) — لا حاجة لـ await هنا فعلياً
                      // لأن واجهة المستخدم تتحدّث فوراً عبر notifyListeners()
                      // قبل اكتمال الحفظ على القرص، لكن نتجاهل الـ Future
                      // بوعي (لا حاجة لانتظار نتيجة الحفظ لتحديث الواجهة).
                      themeProvider.toggleTheme();
                    },
                    // ⚠️ إصلاح: activeColor مُهمَل (deprecated) منذ Flutter
                    // 3.31، واستُبدل بـ activeThumbColor/activeTrackColor.
                    // كان "// ignore: deprecated_member_use" يُخفي هذا بدل
                    // إصلاحه. هذا أيضاً يُصلح خللاً معروفاً في Flutter
                    // (Issue #164619) حيث activeColor لا يُطبَّق إطلاقاً
                    // على Switch.adaptive في بعض الإصدارات — activeThumbColor
                    // يعمل بشكل صحيح ومضمون.
                    activeThumbColor: AppTheme.primary),
              ),
            ]),
            const SizedBox(height: 16),
            _Section(title: 'التطبيق', isDark: isDark, children: [
              _SettingsTile(
                  isDark: isDark,
                  icon: Icons.info_outline_rounded,
                  iconColor: AppTheme.primary,
                  title: 'الإصدار',
                  subtitle: '2.0.0'),
              _SettingsTile(
                  isDark: isDark,
                  icon: Icons.person_rounded,
                  iconColor: AppTheme.accent,
                  title: 'المطوّر',
                  subtitle: 'ابوحسن المؤيدي',
                  // ⚠️ تحسين حقيقي: الرقم كان جزءاً من نص subtitle ثابت لا
                  // تفاعل معه إطلاقاً. الآن عنصر tappable مستقل بنسخ فعلي.
                  trailing: Semantics(
                    button: true,
                    label: 'نسخ رقم التواصل',
                    child: GestureDetector(
                      onTap: () => _copyPhone(context),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: AppTheme.accent.withValues(alpha: 0.1),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(_developerPhone, style: GoogleFonts.cairo(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.accent)),
                          const SizedBox(width: 6),
                          const Icon(Icons.copy_rounded, size: 14, color: AppTheme.accent),
                        ]),
                      ),
                    ),
                  )),
              _SettingsTile(
                  isDark: isDark,
                  icon: Icons.security_rounded,
                  iconColor: const Color(0xFFFC8181),
                  title: 'الخصوصية',
                  subtitle: 'جميع البيانات على جهازك فقط'),
            ]),
          ])),
        ])),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final bool isDark;
  final List<Widget> children;
  const _Section(
      {required this.title, required this.isDark, required this.children});

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
            padding: const EdgeInsets.only(bottom: 8, right: 4),
            child: Text(title,
                style: GoogleFonts.cairo(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primaryLight,
                    letterSpacing: 0.5))),
        Container(
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: isDark ? AppTheme.bgCardLight : Colors.white,
                border:
                    Border.all(color: AppTheme.divider.withValues(alpha: 0.5))),
            child: Column(children: children)),
      ]);
}

class _SettingsTile extends StatelessWidget {
  final bool isDark;
  final IconData icon;
  final Color iconColor;
  final String title, subtitle;
  final Widget? trailing;
  const _SettingsTile(
      {required this.isDark,
      required this.icon,
      required this.iconColor,
      required this.title,
      required this.subtitle,
      this.trailing});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(
                    color: AppTheme.divider.withValues(alpha: 0.3)))),
        child: Row(children: [
          Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: iconColor.withValues(alpha: 0.12)),
              child: Icon(icon, color: iconColor, size: 18)),
          const SizedBox(width: 14),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: GoogleFonts.cairo(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? AppTheme.textPrimary
                            : const Color(0xFF1A1A2E))),
                Text(subtitle,
                    style: GoogleFonts.cairo(
                        fontSize: 12, color: AppTheme.textSecondary)),
              ])),
          trailing ?? const SizedBox.shrink(),
        ]),
      );
}
