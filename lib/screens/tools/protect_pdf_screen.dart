// ═══════════════════════════════════════════════════════════════════════════
//  حماية PDF — إعادة بناء كاملة: دمج التشفير والصلاحيات، AES-256 بصمت
// ═══════════════════════════════════════════════════════════════════════════
//
//  الفرق الجوهري عن النسخة السابقة:
//
//  1. "إدارة الصلاحيات" لم تكن أداة منفصلة في أي تطبيق مرجعي (Adobe
//     Acrobat Protect, iLovePDF, Smallpdf) — الصلاحيات دوماً جزء من نفس
//     عملية "حماية الملف بكلمة مرور"، تُضبط من نفس الشاشة. هنا دُمجت في
//     قسم "صلاحيات متقدمة" قابل للطي (مُغلَق افتراضياً) ضمن شاشة الحماية
//     نفسها، بدل شاشة وأداة مستقلة بالكامل (كانت مكررة حرفياً 4 سويتشات
//     صلاحيات هوية مع شاشة التشفير).
//
//  2. خوارزمية التشفير (AES-256/128/RC4) لم تُعرَض كخيار للمستخدم —
//     لا تطبيق مرجعي واحد يسأل المستخدم العادي عن هذا. AES-256 تُستخدَم
//     دوماً وبصمت (نفس ما تفعله كل التطبيقات المرجعية فعلياً).
//
//  3. كلمة مرور "المالك" (ownerPassword) لم تُعرَض كحقل يطلبه المستخدم
//     يدوياً — هذا تفصيل تقني (الفرق بين "كلمة فتح" و"كلمة صلاحيات") لا
//     يفهمه مستخدم عادي ولا يُطلَب صراحة في أي تطبيق مرجعي. تُولَّد داخلياً
//     فقط عند تفعيل قسم الصلاحيات المتقدمة (مطلوبة تقنياً لتفعيل القيود،
//     لكنها ليست كلمة يحتاج المستخدم تذكّرها لاحقاً لفتح الملف — فتح الملف
//     يبقى بكلمة المرور الرئيسية وحدها).
//
//  4. ⚠️ إصلاح خلل وظيفي حقيقي من النسخة السابقة في عملية فك التشفير:
//     كان هناك كتلة try/catch داخلية كاملة تفتح نسخة محلية ثانية من
//     المستند بنفس الاسم (تُظلِّل المتغير الخارجي)، تُزيل كلمتي المرور،
//     تستدعي saveSync() **دون استخدام نتيجتها** (تُهدَر بالكامل)، ثم
//     dispose — كل هذه الكتلة كانت بلا أي تأثير فعلي على الملف النهائي
//     (الحفظ الحقيقي يحدث بعدها على المتغير الخارجي)، لكنها تقرأ الملف
//     من القرص وتفتح المستند بالكامل دون أي فائدة. أُزيلت بالكامل هنا.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../../theme/app_theme.dart';
import '../result_screen.dart';

// ─────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────
String _formatBytes(int bytes, int decimals) {
  if (bytes <= 0) return "0 B";
  const suffixes = ["B", "KB", "MB", "GB", "TB"];
  var i = (log(bytes) / log(1024)).floor();
  return '${(bytes / pow(1024, i)).toStringAsFixed(decimals)} ${suffixes[i]}';
}

Widget _header(BuildContext context, bool isDark, String title) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
    child: Row(children: [
      GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          Navigator.pop(context);
        },
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: isDark ? AppTheme.bgCardLight : Colors.white,
            border: Border.all(color: AppTheme.divider),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 10,
                  offset: const Offset(0, 4))
            ],
          ),
          child: const Icon(Icons.arrow_back_ios_new_rounded,
              size: 18, color: AppTheme.textSecondary),
        ),
      ),
      const SizedBox(width: 16),
      Text(title,
          style: GoogleFonts.cairo(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
    ]),
  );
}

void _showError(BuildContext context, String msg) {
  HapticFeedback.heavyImpact();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Row(children: [
      const Icon(Icons.error_outline_rounded, color: Colors.white),
      const SizedBox(width: 12),
      Expanded(
          child: Text(msg,
              style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.w600))),
    ]),
    backgroundColor: const Color(0xFFE53E3E),
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    margin: const EdgeInsets.all(16),
  ));
}

// ─────────────────────────────────────────────────────
//  الشاشة الرئيسية: بطاقتان فقط (حماية / إزالة حماية)
// ─────────────────────────────────────────────────────
class ProtectPdfScreen extends StatelessWidget {
  const ProtectPdfScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
          child: Column(children: [
            _header(context, isDark, 'أمان PDF'),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: 20),
                    Hero(
                      tag: 'security_icon',
                      child: Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                              colors: [Color(0xFF702459), Color(0xFFFF6584)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight),
                          boxShadow: [
                            BoxShadow(
                                color: const Color(0xFFFF6584).withValues(alpha: 0.3),
                                blurRadius: 30,
                                offset: const Offset(0, 10))
                          ],
                        ),
                        child: const Icon(Icons.security_rounded, color: Colors.white, size: 48),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text('أمان ملفاتك أولويتنا',
                        style: GoogleFonts.cairo(
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
                    const SizedBox(height: 8),
                    Text('اختر العملية المطلوبة للتحكم الكامل في مستنداتك',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.cairo(
                            fontSize: 14, color: AppTheme.textSecondary, height: 1.5)),
                    const SizedBox(height: 40),
                    _ActionCard(
                      isDark: isDark,
                      icon: Icons.lock_outline_rounded,
                      gradient: const LinearGradient(
                          colors: [Color(0xFF702459), Color(0xFFFF6584)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight),
                      title: 'حماية الملف',
                      subtitle: 'كلمة مرور وصلاحيات اختيارية (طباعة، نسخ، تعديل)',
                      badge: 'AES-256',
                      badgeColor: const Color(0xFFFF6584),
                      onTap: () => Navigator.push(
                          context, MaterialPageRoute(builder: (_) => const _ProtectScreen())),
                    ),
                    const SizedBox(height: 16),
                    _ActionCard(
                      isDark: isDark,
                      icon: Icons.lock_open_rounded,
                      gradient: const LinearGradient(
                          colors: [Color(0xFF1D4044), Color(0xFF4FD1C5)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight),
                      title: 'إزالة الحماية',
                      subtitle: 'أدخل كلمة المرور لفك تشفير ملف محمي مسبقاً',
                      badge: 'فك تشفير',
                      badgeColor: AppTheme.accent,
                      onTap: () => Navigator.push(
                          context, MaterialPageRoute(builder: (_) => const _DecryptScreen())),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final bool isDark;
  final IconData icon;
  final LinearGradient gradient;
  final String title, subtitle, badge;
  final Color badgeColor;
  final VoidCallback onTap;

  const _ActionCard({
    required this.isDark,
    required this.icon,
    required this.gradient,
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.badgeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: isDark ? AppTheme.bgCardLight : Colors.white,
          border: Border.all(color: badgeColor.withValues(alpha: 0.15), width: 1.5),
          boxShadow: [
            BoxShadow(color: badgeColor.withValues(alpha: 0.08), blurRadius: 20, offset: const Offset(0, 8))
          ],
        ),
        child: Row(children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: gradient,
              boxShadow: [BoxShadow(color: badgeColor.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 4))],
            ),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    child: Text(title,
                        style: GoogleFonts.cairo(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: badgeColor.withValues(alpha: 0.12)),
                  child: Text(badge,
                      style: GoogleFonts.cairo(fontSize: 10, fontWeight: FontWeight.w800, color: badgeColor)),
                ),
              ]),
              const SizedBox(height: 6),
              Text(subtitle, style: GoogleFonts.cairo(fontSize: 12, color: AppTheme.textSecondary, height: 1.5)),
            ]),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.arrow_forward_ios_rounded, size: 16, color: AppTheme.textMuted),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────
//  شاشة الحماية المُدمَجة: كلمة مرور + صلاحيات متقدمة قابلة للطي
// ─────────────────────────────────────────────────────
class _ProtectScreen extends StatefulWidget {
  const _ProtectScreen();
  @override
  State<_ProtectScreen> createState() => _ProtectScreenState();
}

class _ProtectScreenState extends State<_ProtectScreen> {
  File? _file;
  int _fileSize = 0;
  bool _processing = false;
  bool _showPw = false, _showCpw = false;
  final _pwCtrl = TextEditingController();
  final _cpwCtrl = TextEditingController();

  /// قسم الصلاحيات المتقدمة مغلق افتراضياً — يطابق التوقّع: المستخدم
  /// العادي يريد "كلمة مرور" فقط، ولا يحتاج رؤية تفاصيل الصلاحيات إلا إذا
  /// طلبها صراحة بفتح القسم.
  bool _advancedExpanded = false;
  bool _allowPrint = true, _allowCopy = false, _allowEdit = false, _allowAnnotate = false;

  @override
  void dispose() {
    _pwCtrl.dispose();
    _cpwCtrl.dispose();
    super.dispose();
  }

  int get _strength {
    final p = _pwCtrl.text;
    if (p.isEmpty) return 0;
    int s = 0;
    if (p.length >= 8) s++;
    if (p.contains(RegExp(r'[A-Z]'))) s++;
    if (p.contains(RegExp(r'[0-9]'))) s++;
    if (p.contains(RegExp(r'[!@#\$%^&*]'))) s++;
    return s;
  }

  Color get _strengthColor => [
        Colors.transparent,
        const Color(0xFFFC8181),
        const Color(0xFFECC94B),
        const Color(0xFF4FD1C5),
        const Color(0xFF48BB78),
      ][_strength.clamp(0, 4)];

  String get _strengthLabel => ['', 'ضعيفة', 'مقبولة', 'جيدة', 'قوية جدًا'][_strength.clamp(0, 4)];

  Future<void> _pickFile() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (r?.files.first.path != null) {
      final file = File(r!.files.first.path!);
      final size = await file.length();
      setState(() {
        _file = file;
        _fileSize = size;
      });
    }
  }

  /// كلمة مرور المالك (صلاحيات) تُولَّد داخلياً وعشوائياً، لا يطلبها
  /// المستخدم ولا يحتاج تذكّرها — فتح الملف يبقى دوماً بكلمة المرور
  /// الرئيسية وحدها (userPassword). هذا يحل أيضاً ثغرة كانت موجودة في
  /// النسخة السابقة (توليد كلمة مالك بنمط '${password}_owner' قابل
  /// للتنبؤ به بسهولة من كلمة المرور الأصلية نفسها).
  String _generateOwnerPassword() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random.secure();
    return List.generate(24, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  Future<void> _protect() async {
    if (_file == null) {
      _showError(context, 'الرجاء اختيار ملف PDF أولاً');
      return;
    }
    if (_pwCtrl.text.length < 4) {
      _showError(context, 'يجب أن تتكون كلمة المرور من 4 أحرف على الأقل');
      return;
    }
    if (_pwCtrl.text != _cpwCtrl.text) {
      _showError(context, 'كلمتا المرور غير متطابقتين');
      return;
    }
    setState(() => _processing = true);
    try {
      final bytes = await _file!.readAsBytes();
      final doc = PdfDocument(inputBytes: bytes);

      // AES-256 دوماً وبصمت — لا تطبيق مرجعي يعرض خيار الخوارزمية
      // للمستخدم العادي، وAES-256 هو المعيار الأقوى المتاح فعلياً.
      doc.security.algorithm = PdfEncryptionAlgorithm.aesx256Bit;
      doc.security.userPassword = _pwCtrl.text;

      // الصلاحيات تُطبَّق فقط إن فتح المستخدم القسم المتقدم صراحة؛ تركه
      // مغلقاً يعني "صلاحيات كاملة بلا قيود" (السلوك الافتراضي المتوقَّع
      // عند طلب "حماية بكلمة مرور" بسيطة بلا تخصيص إضافي).
      if (_advancedExpanded) {
        doc.security.ownerPassword = _generateOwnerPassword();
        doc.security.permissions.clear();
        final perms = <PdfPermissionsFlags>[];
        if (_allowPrint) perms.add(PdfPermissionsFlags.print);
        if (_allowCopy) perms.add(PdfPermissionsFlags.copyContent);
        if (_allowEdit) perms.add(PdfPermissionsFlags.editContent);
        if (_allowAnnotate) perms.add(PdfPermissionsFlags.editAnnotations);
        doc.security.permissions.addAll(perms);
      }

      final outBytes = doc.saveSync();
      doc.dispose();

      final dir = await getTemporaryDirectory();
      final name = _file!.path.split(Platform.pathSeparator).last.replaceAll('.pdf', '');
      final out = File('${dir.path}/${name}_محمي.pdf');
      await out.writeAsBytes(outBytes);

      if (!mounted) return;
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ResultScreen(
                    file: out,
                    title: 'تم حماية الملف بنجاح!',
                    subtitle: 'تم تأمين الملف بتشفير AES-256',
                    toolId: 'protect_pdf',
                    toolName: 'حماية PDF',
                    settings: {
                      if (_advancedExpanded) 'الطباعة': _allowPrint ? 'مسموح' : 'محظور',
                      if (_advancedExpanded) 'النسخ': _allowCopy ? 'مسموح' : 'محظور',
                    },
                  )));
    } catch (e) {
      if (mounted) _showError(context, 'حدث خطأ أثناء الحماية: $e');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppTheme.bgDark : const Color(0xFFF5F5FF),
      body: Container(
        decoration: BoxDecoration(
          gradient: isDark
              ? AppTheme.bgGradient
              : const LinearGradient(colors: [Color(0xFFF5F5FF), Color(0xFFEEEEFF)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
        ),
        child: SafeArea(
          child: Column(children: [
            _header(context, isDark, 'حماية الملف'),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.all(24),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _filePicker(isDark, const Color(0xFFFF6584)),
                  const SizedBox(height: 28),
                  _sectionTitle('كلمة المرور', isDark, Icons.password_rounded),
                  const SizedBox(height: 12),
                  _pwField(_pwCtrl, 'أدخل كلمة المرور (مطلوبة)', _showPw, () => setState(() => _showPw = !_showPw), isDark),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    child: _pwCtrl.text.isNotEmpty
                        ? Padding(
                            padding: const EdgeInsets.only(top: 8, bottom: 4),
                            child: Row(children: [
                              ...List.generate(
                                  4,
                                  (i) => Expanded(
                                        child: AnimatedContainer(
                                          duration: const Duration(milliseconds: 300),
                                          margin: const EdgeInsets.only(right: 6),
                                          height: 6,
                                          decoration: BoxDecoration(
                                              borderRadius: BorderRadius.circular(3),
                                              color: i < _strength ? _strengthColor : AppTheme.divider),
                                        ),
                                      )),
                              const SizedBox(width: 10),
                              SizedBox(
                                  width: 60,
                                  child: Text(_strengthLabel,
                                      textAlign: TextAlign.center,
                                      style: GoogleFonts.cairo(fontSize: 12, color: _strengthColor, fontWeight: FontWeight.bold))),
                            ]),
                          )
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 14),
                  _pwField(_cpwCtrl, 'تأكيد كلمة المرور', _showCpw, () => setState(() => _showCpw = !_showCpw), isDark),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    child: (_cpwCtrl.text.isNotEmpty && _pwCtrl.text != _cpwCtrl.text)
                        ? Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text('كلمتا المرور غير متطابقتين',
                                style: GoogleFonts.cairo(fontSize: 12, color: Colors.redAccent, fontWeight: FontWeight.bold)))
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 24),
                  _buildAdvancedSection(isDark),
                  const SizedBox(height: 36),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: (_file == null || _processing) ? null : _protect,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF702459),
                        disabledBackgroundColor: AppTheme.bgCardLight,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: (_file == null || _processing) ? 0 : 8,
                        shadowColor: const Color(0xFF702459).withValues(alpha: 0.4),
                      ),
                      child: _processing
                          ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                              const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5)),
                              const SizedBox(width: 14),
                              Text('جارٍ الحماية...', style: GoogleFonts.cairo(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                            ])
                          : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                              const Icon(Icons.lock_rounded, color: Colors.white, size: 22),
                              const SizedBox(width: 10),
                              Text('حماية الملف', style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17)),
                            ]),
                    ),
                  ),
                  const SizedBox(height: 20),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// قسم الصلاحيات المتقدمة القابل للطي — هذا هو الدمج الجوهري الذي
  /// يستبدل شاشة "إدارة الصلاحيات" المستقلة بالكامل من النسخة السابقة.
  Widget _buildAdvancedSection(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: isDark ? AppTheme.bgCardLight : Colors.white,
        border: Border.all(color: AppTheme.divider.withValues(alpha: 0.5)),
      ),
      child: Column(children: [
        GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            setState(() => _advancedExpanded = !_advancedExpanded);
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Icon(Icons.admin_panel_settings_outlined,
                  color: _advancedExpanded ? const Color(0xFF9F7AEA) : AppTheme.textMuted, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('صلاحيات متقدمة (اختياري)',
                      style: GoogleFonts.cairo(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
                  Text('تقييد الطباعة، النسخ، أو التعديل بعد فتح الملف',
                      style: GoogleFonts.cairo(fontSize: 11.5, color: AppTheme.textMuted)),
                ]),
              ),
              AnimatedRotation(
                turns: _advancedExpanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(Icons.keyboard_arrow_down_rounded, color: AppTheme.textMuted),
              ),
            ]),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          child: _advancedExpanded
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(children: [
                    const Divider(height: 1),
                    const SizedBox(height: 12),
                    _permToggle(isDark, Icons.print_rounded, 'السماح بالطباعة', _allowPrint,
                        (v) => setState(() => _allowPrint = v), const Color(0xFF4FD1C5)),
                    _permToggle(isDark, Icons.content_copy_rounded, 'السماح بنسخ النصوص', _allowCopy,
                        (v) => setState(() => _allowCopy = v), const Color(0xFFECC94B)),
                    _permToggle(isDark, Icons.edit_rounded, 'السماح بتعديل المحتوى', _allowEdit,
                        (v) => setState(() => _allowEdit = v), const Color(0xFF9F7AEA)),
                    _permToggle(isDark, Icons.comment_rounded, 'السماح بإضافة التعليقات', _allowAnnotate,
                        (v) => setState(() => _allowAnnotate = v), const Color(0xFFFC8181)),
                  ]),
                )
              : const SizedBox.shrink(),
        ),
      ]),
    );
  }

  Widget _filePicker(bool isDark, Color accent) {
    return GestureDetector(
      onTap: _pickFile,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: isDark ? AppTheme.bgCardLight : Colors.white,
          border: Border.all(color: _file != null ? accent.withValues(alpha: 0.6) : AppTheme.divider, width: _file != null ? 2 : 1),
          boxShadow: _file != null ? [BoxShadow(color: accent.withValues(alpha: 0.1), blurRadius: 15, offset: const Offset(0, 5))] : [],
        ),
        child: _file == null
            ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: const BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [Color(0xFF702459), Color(0xFFFF6584)])),
                  child: const Icon(Icons.upload_file_rounded, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 16),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('اختر ملف PDF',
                      style: GoogleFonts.cairo(fontSize: 17, fontWeight: FontWeight.bold, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
                  Text('اضغط هنا لاستعراض الملفات', style: GoogleFonts.cairo(fontSize: 12, color: AppTheme.textMuted)),
                ]),
              ])
            : Row(children: [
                const Icon(Icons.picture_as_pdf_rounded, color: Color(0xFFFC8181), size: 40),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_file!.path.split(Platform.pathSeparator).last,
                        style: GoogleFonts.cairo(fontSize: 15, fontWeight: FontWeight.bold, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Text(_formatBytes(_fileSize, 2), style: GoogleFonts.cairo(fontSize: 12, color: AppTheme.textSecondary)),
                  ]),
                ),
                GestureDetector(
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    setState(() {
                      _file = null;
                      _fileSize = 0;
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.1), shape: BoxShape.circle),
                    child: const Icon(Icons.close_rounded, color: Colors.redAccent, size: 20),
                  ),
                ),
              ]),
      ),
    );
  }

  Widget _pwField(TextEditingController ctrl, String hint, bool show, VoidCallback? toggle, bool isDark) {
    return TextField(
      controller: ctrl,
      obscureText: !show,
      onChanged: (_) => setState(() {}),
      style: GoogleFonts.cairo(color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E)),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.cairo(color: AppTheme.textMuted, fontSize: 14),
        filled: true,
        fillColor: isDark ? AppTheme.bgCardLight : Colors.white,
        prefixIcon: const Icon(Icons.key_rounded, color: AppTheme.textMuted, size: 22),
        suffixIcon: toggle != null
            ? IconButton(
                icon: Icon(show ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: AppTheme.textMuted, size: 22),
                onPressed: toggle,
                splashRadius: 20,
              )
            : null,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFFF6584), width: 1.5)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }

  Widget _permToggle(bool isDark, IconData icon, String label, bool val, ValueChanged<bool> onChanged, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: isDark ? AppTheme.bgDark : const Color(0xFFF5F5FF),
        border: Border.all(color: val ? color.withValues(alpha: 0.4) : AppTheme.divider.withValues(alpha: 0.4)),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: val ? color.withValues(alpha: 0.15) : AppTheme.divider.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: val ? color : AppTheme.textMuted, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
            child: Text(label,
                style: GoogleFonts.cairo(fontSize: 15, fontWeight: FontWeight.w600, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E)))),
        Switch.adaptive(
          value: val,
          onChanged: (newValue) {
            HapticFeedback.lightImpact();
            onChanged(newValue);
          },
          activeThumbColor: color,
          activeTrackColor: color.withValues(alpha: 0.4),
        ),
      ]),
    );
  }

  Widget _sectionTitle(String t, bool isDark, IconData icon) {
    return Row(children: [
      Icon(icon, size: 18, color: AppTheme.textSecondary),
      const SizedBox(width: 8),
      Text(t,
          style: GoogleFonts.cairo(
              fontSize: 14, fontWeight: FontWeight.w800, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
    ]);
  }
}

// ─────────────────────────────────────────────────────
//  شاشة إزالة الحماية — نفس المنطق، لكن مُصحَّحاً من الخلل الوظيفي
// ─────────────────────────────────────────────────────
class _DecryptScreen extends StatefulWidget {
  const _DecryptScreen();
  @override
  State<_DecryptScreen> createState() => _DecryptScreenState();
}

class _DecryptScreenState extends State<_DecryptScreen> {
  File? _file;
  int _fileSize = 0;
  bool _processing = false, _showPw = false;
  final _pwCtrl = TextEditingController();

  @override
  void dispose() {
    _pwCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (r?.files.first.path != null) {
      final file = File(r!.files.first.path!);
      final size = await file.length();
      setState(() {
        _file = file;
        _fileSize = size;
      });
    }
  }

  /// ⚠️ مُصحَّحة: فتح المستند مرة واحدة فقط بكلمة المرور المُدخلة، إزالة
  /// كلمتي المرور والصلاحيات، حفظ، تخلّص. لا قراءة مكررة للملف من القرص
  /// ولا فتح مستند إضافي يُهدَر ناتجه — الخلل الذي كان في النسخة السابقة
  /// (انظر الشرح الكامل أعلى الملف) أُزيل بالكامل.
  Future<void> _decrypt() async {
    if (_file == null) {
      _showError(context, 'الرجاء اختيار ملف PDF محمي أولاً');
      return;
    }
    if (_pwCtrl.text.isEmpty) {
      _showError(context, 'يرجى إدخال كلمة المرور لفك تشفير الملف');
      return;
    }
    setState(() => _processing = true);

    try {
      final bytes = await _file!.readAsBytes();
      PdfDocument doc;
      try {
        doc = PdfDocument(inputBytes: bytes, password: _pwCtrl.text);
      } catch (_) {
        if (mounted) {
          _showError(context, 'كلمة المرور غير صحيحة، أو أن الملف تالف');
          setState(() => _processing = false);
        }
        return;
      }

      doc.security.userPassword = '';
      doc.security.ownerPassword = '';
      doc.security.permissions.clear();

      final outBytes = doc.saveSync();
      doc.dispose();

      final dir = await getTemporaryDirectory();
      final name = _file!.path.split(Platform.pathSeparator).last.replaceAll('.pdf', '');
      final out = File('${dir.path}/${name}_مفتوح.pdf');
      await out.writeAsBytes(outBytes);

      if (!mounted) return;
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ResultScreen(
                    file: out,
                    title: 'تم فك الحماية!',
                    subtitle: 'تمت إزالة كلمة المرور والتشفير بنجاح',
                    toolId: 'protect_pdf',
                    toolName: 'إزالة الحماية',
                    settings: const {'العملية': 'إزالة كلمة المرور'},
                  )));
    } catch (e) {
      if (mounted) _showError(context, 'حدث خطأ غير متوقع: $e');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppTheme.bgDark : const Color(0xFFF5F5FF),
      body: Container(
        decoration: BoxDecoration(
          gradient: isDark
              ? AppTheme.bgGradient
              : const LinearGradient(colors: [Color(0xFFF5F5FF), Color(0xFFEEEEFF)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
        ),
        child: SafeArea(
          child: Column(children: [
            _header(context, isDark, 'إزالة الحماية'),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.all(24),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  GestureDetector(
                    onTap: _pickFile,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: isDark ? AppTheme.bgCardLight : Colors.white,
                        border: Border.all(
                            color: _file != null ? AppTheme.accent.withValues(alpha: 0.6) : AppTheme.divider,
                            width: _file != null ? 2 : 1),
                      ),
                      child: _file == null
                          ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                              Container(
                                width: 56,
                                height: 56,
                                decoration: const BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [Color(0xFF1D4044), Color(0xFF4FD1C5)])),
                                child: const Icon(Icons.upload_file_rounded, color: Colors.white, size: 28),
                              ),
                              const SizedBox(width: 16),
                              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('اختر ملف PDF محمي',
                                    style: GoogleFonts.cairo(fontSize: 17, fontWeight: FontWeight.bold, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
                                Text('اضغط هنا لاستعراض الملفات', style: GoogleFonts.cairo(fontSize: 12, color: AppTheme.textMuted)),
                              ]),
                            ])
                          : Row(children: [
                              const Icon(Icons.picture_as_pdf_rounded, color: AppTheme.accent, size: 40),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(_file!.path.split(Platform.pathSeparator).last,
                                      style: GoogleFonts.cairo(fontSize: 15, fontWeight: FontWeight.bold, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E)),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  const SizedBox(height: 4),
                                  Text(_formatBytes(_fileSize, 2), style: GoogleFonts.cairo(fontSize: 12, color: AppTheme.textSecondary)),
                                ]),
                              ),
                              GestureDetector(
                                onTap: () {
                                  HapticFeedback.mediumImpact();
                                  setState(() {
                                    _file = null;
                                    _fileSize = 0;
                                  });
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.1), shape: BoxShape.circle),
                                  child: const Icon(Icons.close_rounded, color: Colors.redAccent, size: 20),
                                ),
                              ),
                            ]),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Row(children: [
                    const Icon(Icons.password_rounded, size: 18, color: AppTheme.textSecondary),
                    const SizedBox(width: 8),
                    Text('كلمة المرور الحالية',
                        style: GoogleFonts.cairo(fontSize: 14, fontWeight: FontWeight.w800, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
                  ]),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pwCtrl,
                    obscureText: !_showPw,
                    style: GoogleFonts.cairo(color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E)),
                    decoration: InputDecoration(
                      hintText: 'أدخل كلمة المرور الحالية للملف',
                      hintStyle: GoogleFonts.cairo(color: AppTheme.textMuted, fontSize: 14),
                      filled: true,
                      fillColor: isDark ? AppTheme.bgCardLight : Colors.white,
                      prefixIcon: const Icon(Icons.key_rounded, color: AppTheme.textMuted, size: 22),
                      suffixIcon: IconButton(
                        icon: Icon(_showPw ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: AppTheme.textMuted, size: 22),
                        onPressed: () => setState(() => _showPw = !_showPw),
                      ),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF4FD1C5), width: 1.5)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                    ),
                  ),
                  const SizedBox(height: 36),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: (_file == null || _processing) ? null : _decrypt,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1D4044),
                        disabledBackgroundColor: AppTheme.bgCardLight,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: (_file == null || _processing) ? 0 : 8,
                        shadowColor: const Color(0xFF1D4044).withValues(alpha: 0.4),
                      ),
                      child: _processing
                          ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                              const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5)),
                              const SizedBox(width: 14),
                              Text('جارٍ إزالة الحماية...', style: GoogleFonts.cairo(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                            ])
                          : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                              const Icon(Icons.lock_open_rounded, color: Colors.white, size: 22),
                              const SizedBox(width: 10),
                              Text('إزالة الحماية', style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17)),
                            ]),
                    ),
                  ),
                  const SizedBox(height: 20),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
