import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../services/history_service.dart';
import '../theme/app_theme.dart';

/// أنواع الملفات الناتجة المدعومة — يحدد الأيقونة/المعاينة/اسم المجلد
/// الفرعي المناسب تلقائياً. لا حاجة لتمريره يدوياً عادة (يُستنتَج من
/// امتداد الملف)، لكنه متاح للتمرير الصريح في حالات نادرة.
enum ResultFileType { pdf, image, unknown }

/// ⚠️ تعميم حقيقي: كانت هذه الشاشة خاصة بملفات PDF فقط (أيقونة PDF ثابتة
/// بصرف النظر عن نوع الملف الفعلي، واسم مجلد حفظ ثابت "PDF Master" لا
/// يلائم أداتي ضغط/تحسين الصور الجديدتين اللتين تُخرجان صوراً لا ملفات
/// PDF). الآن تكتشف نوع الملف تلقائياً من امتداده وتُكيّف العرض/الحفظ
/// تبعاً لذلك، فتصلح لكل أدوات التطبيق (PDF أو صورة) دون أي تمييز خاص
/// من الشاشة المستدعية.
class ResultScreen extends StatefulWidget {
  final File file;
  final String title;
  final String subtitle;
  final String toolId;
  final String toolName;
  final Map<String, dynamic> settings;
  final ResultFileType? fileType;

  const ResultScreen({
    super.key,
    required this.file,
    required this.title,
    required this.subtitle,
    this.toolId = 'unknown',
    this.toolName = 'PDF Master',
    this.settings = const {},
    this.fileType,
  });

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;
  late Animation<double> _fade;
  bool _saved = false;
  bool _saving = false;
  String? _savedPath;

  // ⚠️ إصلاح خلل حقيقي محتمل: كان الملف يُعتبَر "ناجحاً" فوراً بعد محاولة
  // إنشائه عند بدء الشاشة (widget.file)، بدون أي فحص لوجوده فعلياً أو
  // حجمه. إن وصل المستخدم لهذه الشاشة بملف فاشل (حجم صفري أو غير موجود
  // أصلاً)، كانت كل عناصر الواجهة (الحجم، الفتح، المشاركة) تتصرّف كما لو
  // نجح التحويل. الآن نفحص هذا فوراً ونُظهر حالة خطأ واضحة عند الفشل.
  bool get _fileIsValid => widget.file.existsSync() && widget.file.lengthSync() > 0;

  static const _imageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'};

  ResultFileType get _resolvedFileType {
    if (widget.fileType != null) return widget.fileType!;
    final ext = widget.file.path.split('.').last.toLowerCase();
    if (ext == 'pdf') return ResultFileType.pdf;
    if (_imageExtensions.contains(ext)) return ResultFileType.image;
    return ResultFileType.unknown;
  }

  bool get _isImage => _resolvedFileType == ResultFileType.image;

  /// اسم المجلد الفرعي المناسب لنوع الملف — يطابق نفس الاسم الذي تستخدمه
  /// أدوات ضغط/تحسين الصور فعلاً (`PDF Master/Images`) بدل افتراض
  /// "PDF Master" دوماً بصرف النظر عن نوع الملف.
  String get _subFolder => _isImage ? 'PDF Master/Images' : 'PDF Master';

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _scale = CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut);
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();
    if (_fileIsValid) _addToHistory();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _addToHistory() async {
    await HistoryService.add(HistoryItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      toolId: widget.toolId,
      toolName: widget.toolName,
      toolIcon: '0xe3ae',
      fileName: widget.file.path.split('/').last,
      filePath: widget.file.path,
      fileSizeBytes: widget.file.existsSync() ? widget.file.lengthSync() : 0,
      createdAt: DateTime.now(),
      settings: widget.settings,
    ));
  }

  String get _fileSize {
    if (!widget.file.existsSync()) return '-- KB';
    final bytes = widget.file.lengthSync();
    if (bytes > 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  String get _fileName => widget.file.path.split('/').last;
  String get _fileExtension => widget.file.path.split('.').last;

  /// ⚠️ إعادة بناء كاملة لمنطق الحفظ — الإصدار السابق كان:
  /// 1) يحاول الوصول مباشرة لمسارات نظام ملفات مطلقة قديمة
  ///    (`/storage/emulated/0/Download`) بلا أي طلب صلاحية، وهذا تحديداً
  ///    ما لا يعمل بشكل موثوق على أندرويد 11+ (Scoped Storage) — قد ينجح
  ///    `existsSync()`/`createSync()` ظاهرياً بينما الكتابة الفعلية تفشل
  ///    أو تُرفَض بصمت حسب إصدار النظام وصلاحياته الممنوحة فعلياً.
  /// 2) كان يُحدِّث `_saved = true` فوراً بعد `copy()` دون أي تأكّد لاحق
  ///    أن الملف الناتج موجود وبالحجم الصحيح — نسخ "ناجح" شكلياً (لا
  ///    استثناء) لا يعني بالضرورة أن البيانات وصلت فعلاً.
  /// 3) (إصلاح جديد ضمن التعميم) كان منطق تجنّب تكرار اسم الملف يفترض
  ///    امتداد ".pdf" دوماً عند بناء الاسم البديل — فملف صورة موجود مسبقاً
  ///    بنفس الاسم (مثلاً "photo.jpg") كان يُعاد حفظه باسم خاطئ تماماً
  ///    ("photo (1).pdf" بدل "photo (1).jpg"). الآن نستخدم الامتداد
  ///    الفعلي للملف الناتج لا امتداداً ثابتاً.
  /// الإصلاح: نُفضِّل دوماً المسارات المضمونة بلا أي صلاحية (داخل صندوق
  /// التطبيق عبر path_provider)، نتحقّق فعلياً من الملف الناتج بعد كل نسخ
  /// (لا نفترض النجاح من غياب استثناء فقط)، ولا نطلب صلاحية
  /// MANAGE_EXTERNAL_STORAGE الواسعة (تتطلّب تبريراً صريحاً من Google
  /// Play وقد تُرفَض التطبيق بدونه) — هذا قرار تصميمي مقصود، لا قيداً
  /// سهواً.
  Future<void> _saveToStorage(String type) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      Directory targetDir;
      bool isBestEffortLegacyPath = false;

      switch (type) {
        case 'downloads':
          // محاولة أفضل-جهد للمسار التقليدي العام (يعمل غالباً على
          // أندرويد 10 وأقدم، وقد يعمل على إصدارات أحدث حسب الصلاحيات
          // الممنوحة فعلياً من المستخدم) — مع تحقّق فعلي بعد الكتابة، لا
          // افتراض نجاح مسبق.
          final legacy = Directory('/storage/emulated/0/Download');
          isBestEffortLegacyPath = true;
          targetDir = legacy.existsSync()
              ? legacy
              : (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
          break;
        case 'documents':
          final legacy = Directory('/storage/emulated/0/Documents');
          isBestEffortLegacyPath = true;
          targetDir = legacy.existsSync()
              ? legacy
              : (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
          break;
        case 'external':
          targetDir = (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
          break;
        default: // 'internal'
          targetDir = await getApplicationDocumentsDirectory();
      }

      final pdfMasterDir = Directory('${targetDir.path}/$_subFolder');
      if (!pdfMasterDir.existsSync()) pdfMasterDir.createSync(recursive: true);

      var dest = File('${pdfMasterDir.path}/$_fileName');
      // تجنّب الكتابة فوق ملف موجود بنفس الاسم بصمت — نُضيف رقماً متزايداً،
      // بالامتداد الفعلي للملف لا امتداداً ثابتاً.
      int suffix = 1;
      final baseName = _fileName.replaceAll(
          RegExp('\\.$_fileExtension\$', caseSensitive: false), '');
      while (dest.existsSync()) {
        dest = File('${pdfMasterDir.path}/$baseName ($suffix).$_fileExtension');
        suffix++;
      }

      await widget.file.copy(dest.path);

      // ── تحقّق فعلي، لا افتراض ──────────────────────────────────────
      final actuallySaved = dest.existsSync() && dest.lengthSync() > 0;
      if (!actuallySaved) {
        throw Exception('لم يصل الملف فعلياً إلى المسار المطلوب');
      }

      if (!mounted) return;
      setState(() { _saved = true; _savedPath = dest.path; _saving = false; });

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          isBestEffortLegacyPath
              ? 'تم الحفظ في: ${dest.path}'
              : 'تم الحفظ في مساحة التطبيق: ${dest.path}',
          style: GoogleFonts.cairo(fontSize: 12),
        ),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(label: 'فتح', textColor: Colors.white, onPressed: () => OpenFilex.open(dest.path)),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('فشل الحفظ: $e', style: GoogleFonts.cairo()),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _shareFile(Rect originRect) async {
    // ⚠️ إصلاح: Share.shareXFiles مُهمَل (deprecated) في share_plus
    // 12.0.0 — نفس الإصلاح المُطبَّق في history_screen.dart.
    await SharePlus.instance.share(
      ShareParams(files: [XFile(widget.file.path)], sharePositionOrigin: originRect),
    );
  }

  void _showSaveDialog() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), color: isDark ? AppTheme.bgCardLight : Colors.white),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 12),
          Container(width: 40, height: 4, decoration: BoxDecoration(borderRadius: BorderRadius.circular(2), color: AppTheme.textMuted)),
          const SizedBox(height: 16),
          Text('اختر مكان الحفظ', style: GoogleFonts.cairo(fontSize: 18, fontWeight: FontWeight.w800, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
          const SizedBox(height: 4),
          Text('سيُحفظ الملف في مجلد $_subFolder', style: GoogleFonts.cairo(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          _SaveOption(isDark: isDark, icon: Icons.download_rounded, title: 'مجلد التنزيلات', subtitle: '/Download/$_subFolder', color: AppTheme.primary, onTap: () { Navigator.pop(context); _saveToStorage('downloads'); }),
          _SaveOption(isDark: isDark, icon: Icons.folder_rounded, title: 'مجلد المستندات', subtitle: '/Documents/$_subFolder', color: AppTheme.accent, onTap: () { Navigator.pop(context); _saveToStorage('documents'); }),
          _SaveOption(isDark: isDark, icon: Icons.storage_rounded, title: 'التخزين الخارجي', subtitle: 'بطاقة SD / وحدة تخزين خارجية', color: AppTheme.accentOrange, onTap: () { Navigator.pop(context); _saveToStorage('external'); }),
          _SaveOption(isDark: isDark, icon: Icons.phone_android_rounded, title: 'التخزين الداخلي', subtitle: '/data/$_subFolder (خاص بالتطبيق، مضمون دوماً)', color: const Color(0xFF9F7AEA), onTap: () { Navigator.pop(context); _saveToStorage('internal'); }),
          const SizedBox(height: 20),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppTheme.bgDark : const Color(0xFFF5F5FF),
      body: Container(
        decoration: BoxDecoration(gradient: isDark ? AppTheme.bgGradient : const LinearGradient(colors: [Color(0xFFF5F5FF), Color(0xFFEEEEFF)], begin: Alignment.topCenter, end: Alignment.bottomCenter)),
        child: SafeArea(
          child: FadeTransition(
            opacity: _fade,
            child: Column(children: [
              Align(alignment: Alignment.topRight, child: Padding(
                padding: const EdgeInsets.all(20),
                child: Semantics(
                  button: true,
                  label: 'إغلاق',
                  child: GestureDetector(
                    onTap: () => Navigator.of(context).popUntil((r) => r.isFirst),
                    child: Container(width: 42, height: 42, decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: isDark ? AppTheme.bgCardLight : Colors.white, border: Border.all(color: AppTheme.divider)), child: const Icon(Icons.close_rounded, size: 20, color: AppTheme.textSecondary)),
                  ),
                ),
              )),
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: _fileIsValid ? _buildSuccessContent(isDark) : _buildFailureContent(isDark),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildSuccessContent(bool isDark) {
    return Builder(builder: (btnContext) {
      final shareKey = GlobalKey();
      return Column(children: [
        ScaleTransition(
          scale: _scale,
          child: Container(
            width: 110, height: 110,
            decoration: BoxDecoration(shape: BoxShape.circle, gradient: const LinearGradient(colors: [Color(0xFF43D9AD), Color(0xFF38B2AC)]), boxShadow: [BoxShadow(color: AppTheme.accent.withValues(alpha: 0.4), blurRadius: 40, spreadRadius: 5)]),
            child: const Icon(Icons.check_rounded, color: Colors.white, size: 52),
          ),
        ),
        const SizedBox(height: 24),
        Text(widget.title, textAlign: TextAlign.center, style: GoogleFonts.cairo(fontSize: 24, fontWeight: FontWeight.w900, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
        const SizedBox(height: 8),
        Text(widget.subtitle, textAlign: TextAlign.center, style: GoogleFonts.cairo(fontSize: 14, color: AppTheme.textSecondary, height: 1.6)),
        const SizedBox(height: 28),
        // File card
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), color: isDark ? AppTheme.bgCardLight : Colors.white, border: Border.all(color: _saved ? AppTheme.accent.withValues(alpha: 0.4) : AppTheme.divider.withValues(alpha: 0.5))),
          child: Row(children: [
            Container(
              width: 50, height: 50,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: _isImage ? null : const LinearGradient(colors: [Color(0xFF9B2C2C), Color(0xFFFC8181)], begin: Alignment.topLeft, end: Alignment.bottomRight),
              ),
              child: _isImage
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      // ⚠️ معاينة حقيقية لمحتوى الصورة الناتجة بدل أيقونة
                      // PDF عامة كانت تُعرَض بصرف النظر عن نوع الملف
                      // الفعلي — هذا ما كان يجعل الشاشة تبدو "غير متوافقة"
                      // مع أدوات الصور الجديدة (ضغط/تحسين الصور).
                      child: Image.file(widget.file, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(Icons.image_rounded, color: Colors.white, size: 26)),
                    )
                  : const Icon(Icons.picture_as_pdf_rounded, color: Colors.white, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_fileName, style: GoogleFonts.cairo(fontSize: 14, fontWeight: FontWeight.w700, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E)), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(_fileSize, style: GoogleFonts.cairo(fontSize: 12, color: AppTheme.textMuted)),
              if (_saved && _savedPath != null)
                Text('محفوظ ✓', style: GoogleFonts.cairo(fontSize: 11, color: AppTheme.accent, fontWeight: FontWeight.w700)),
            ])),
          ]),
        ),
        const SizedBox(height: 20),
        // Primary actions
        _ResultBtn(label: _saving ? 'جارٍ الحفظ...' : 'حفظ في الجهاز', icon: Icons.save_alt_rounded, gradient: const LinearGradient(colors: [Color(0xFF6C63FF), Color(0xFF9D50FF)]), onTap: _saving ? null : _showSaveDialog, loading: _saving),
        const SizedBox(height: 10),
        _ResultBtn(label: 'فتح الملف', icon: Icons.open_in_new_rounded, gradient: AppTheme.primaryGradient.scale(0.7), onTap: () => OpenFilex.open(widget.file.path)),
        const SizedBox(height: 10),
        _ResultBtn(
          key: shareKey,
          label: 'مشاركة الملف',
          icon: Icons.share_rounded,
          gradient: const LinearGradient(colors: [Color(0xFF43D9AD), Color(0xFF38B2AC)]),
          onTap: () {
            final box = shareKey.currentContext?.findRenderObject() as RenderBox?;
            final origin = box != null ? box.localToGlobal(Offset.zero) & box.size : const Rect.fromLTWH(0, 0, 1, 1);
            _shareFile(origin);
          },
        ),
        const SizedBox(height: 12),
        Semantics(
          button: true,
          label: 'العودة للرئيسية',
          child: GestureDetector(
            onTap: () => Navigator.of(context).popUntil((r) => r.isFirst),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), color: isDark ? AppTheme.bgCardLight : Colors.white, border: Border.all(color: AppTheme.divider)),
              child: Center(child: Text('العودة للرئيسية', style: GoogleFonts.cairo(color: AppTheme.textSecondary, fontWeight: FontWeight.w700, fontSize: 15))),
            ),
          ),
        ),
        const SizedBox(height: 32),
      ]);
    });
  }

  /// ⚠️ حالة جديدة كانت غائبة تماماً: لم تكن هناك أي معالجة لحالة وصول
  /// المستخدم لهذه الشاشة بملف فاشل (فشل التحويل في الأداة السابقة لكن
  /// تم استدعاء ResultScreen رغم ذلك بطريق الخطأ، أو حُذف الملف من نظام
  /// التشغيل بين إنشائه وفتح هذه الشاشة). كانت كل عناصر "النجاح" تُعرَض
  /// كأن التحويل تم بأمان.
  Widget _buildFailureContent(bool isDark) {
    return Column(children: [
      const SizedBox(height: 40),
      Container(
        width: 110, height: 110,
        decoration: const BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [Color(0xFFFC8181), Color(0xFF9B2C2C)])),
        child: const Icon(Icons.error_outline_rounded, color: Colors.white, size: 52),
      ),
      const SizedBox(height: 24),
      Text('تعذّر إنشاء الملف', textAlign: TextAlign.center, style: GoogleFonts.cairo(fontSize: 22, fontWeight: FontWeight.w900, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
      const SizedBox(height: 8),
      Text('لم يُعثَر على الملف الناتج أو كان فارغاً. حاول تنفيذ العملية مرة أخرى.', textAlign: TextAlign.center, style: GoogleFonts.cairo(fontSize: 14, color: AppTheme.textSecondary, height: 1.6)),
      const SizedBox(height: 28),
      Semantics(
        button: true,
        label: 'العودة للرئيسية',
        child: GestureDetector(
          onTap: () => Navigator.of(context).popUntil((r) => r.isFirst),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), color: isDark ? AppTheme.bgCardLight : Colors.white, border: Border.all(color: AppTheme.divider)),
            child: Center(child: Text('العودة للرئيسية', style: GoogleFonts.cairo(color: AppTheme.textSecondary, fontWeight: FontWeight.w700, fontSize: 15))),
          ),
        ),
      ),
      const SizedBox(height: 32),
    ]);
  }
}

class _SaveOption extends StatelessWidget {
  final bool isDark;
  final IconData icon;
  final String title, subtitle;
  final Color color;
  final VoidCallback onTap;
  const _SaveOption({required this.isDark, required this.icon, required this.title, required this.subtitle, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: title,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: isDark ? AppTheme.bgCard : const Color(0xFFF8F8FF), border: Border.all(color: color.withValues(alpha: 0.2))),
        child: Row(children: [
          Container(width: 44, height: 44, decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: color.withValues(alpha: 0.12)), child: Icon(icon, color: color, size: 22)),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: GoogleFonts.cairo(fontSize: 14, fontWeight: FontWeight.w700, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
            Text(subtitle, style: GoogleFonts.cairo(fontSize: 11, color: AppTheme.textMuted)),
          ])),
          const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppTheme.textMuted),
        ]),
      ),
    ),
  );
}

class _ResultBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final LinearGradient gradient;
  final VoidCallback? onTap;
  final bool loading;
  const _ResultBtn({super.key, required this.label, required this.icon, required this.gradient, required this.onTap, this.loading = false});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    enabled: onTap != null,
    child: GestureDetector(
      onTap: onTap == null ? null : () { HapticFeedback.lightImpact(); onTap!(); },
      child: Opacity(
        opacity: onTap == null && !loading ? 0.6 : 1,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 15),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), gradient: gradient, boxShadow: [BoxShadow(color: gradient.colors.first.withValues(alpha: 0.3), blurRadius: 16, offset: const Offset(0, 6))]),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (loading)
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
            else
              Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Text(label, style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
          ]),
        ),
      ),
    ),
  );
}
