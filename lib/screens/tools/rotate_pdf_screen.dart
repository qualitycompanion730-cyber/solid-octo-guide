// ═══════════════════════════════════════════════════════════════════════════
//  تدوير PDF — إعادة بناء كاملة: شبكة مصغّرات + دوران فوري لكل صفحة
// ═══════════════════════════════════════════════════════════════════════════
//
//  الفرق الجوهري عن النسخة السابقة (معاينة SfPdfViewer واحدة + نموذج
//  "تطبيق على: الكل/فردي/زوجي/فردي/نطاق نصي" + زاوية واحدة مشتركة):
//
//  هنا كل صفحة عنصر مستقل في شبكة (GridView)، بزاويتها الخاصة، تُدار
//  بنقرة مباشرة على أيقونة ↺/↻ فوق مصغّرتها — تماماً كـ iLovePDF/Smallpdf.
//  الدوران المعروض فوري 100% (Transform.rotate على صورة مُرمَّزة مسبقاً)
//  بلا أي استدعاء لـ Syncfusion حتى لحظة الحفظ النهائي، حيث تُطبَّق كل
//  الزوايا الفردية المتراكمة دفعة واحدة.
//
//  التحديد المتعدد (Tap مطوّل أو زر "تحديد") يسمح بتطبيق دوران واحد على
//  مجموعة صفحات دفعة واحدة، بدل الاضطرار للنقر على كل صفحة منفردة عند
//  الحاجة لتدوير عدة صفحات بنفس الزاوية.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../../theme/app_theme.dart';
import '../../pdf_engine/pdf_thumbnail_service.dart';
import '../result_screen.dart';

/// حالة فردية لكل صفحة: مصغّرتها المُرمَّزة + زاوية الدوران الأصلية
/// المخزَّنة فعلاً في ملف PDF (قد تكون غير صفر لملفات ممسوحة بالسكانر) +
/// زاوية الدوران الحالية التي يتحكم بها المستخدم من واجهتنا.
///
/// ⚠️ تمييز حاسم بين originalAngle و currentAngle ضروري لتفادي خلل صامت:
/// لو افترضنا أن كل صفحة تبدأ من 0 دون قراءة دورانها الأصلي من الملف،
/// وكانت صفحة ممسوحة فعلياً مُدوَّرة 90° مسبقاً (تظهر مصغّرتها هنا بزاوية
/// 90° لأن pdfx/PDFium يحترم الدوران المخزَّن عند الترميز)، فإن المستخدم
/// الذي لا يلمس هذه الصفحة إطلاقاً سيحفظها بزاوية 0 عرضياً (لأن الكود
/// كان سيضبط rotation = rotateAngle0 دون علمه)، فيُلغي دوراناً مقصوداً
/// كان موجوداً أصلاً في الملف. الإصلاح: نقرأ originalAngle من الملف عبر
/// Syncfusion عند التحميل، ونستخدمه كنقطة انطلاق currentAngle، فلا نكتب
/// شيئاً للصفحة عند الحفظ إلا إذا changed فعلياً عن قيمتها الأصلية.
class _PageRotationState {
  final PdfThumbnail thumbnail;
  final int originalAngle; // الزاوية المخزَّنة فعلاً في الملف الأصلي
  int currentAngle; // الزاوية الحالية التي يتحكم بها المستخدم من الواجهة
  bool isSelected;

  _PageRotationState({
    required this.thumbnail,
    required this.originalAngle,
    int? currentAngle,
  }) : isSelected = false, currentAngle = currentAngle ?? originalAngle;

  bool get hasChanged => currentAngle != originalAngle;
}

class RotatePdfScreen extends StatefulWidget {
  const RotatePdfScreen({super.key});
  @override
  State<RotatePdfScreen> createState() => _RotatePdfScreenState();
}

class _RotatePdfScreenState extends State<RotatePdfScreen> {
  File? _file;
  bool _isProcessing = false;
  bool _isLoadingThumbnails = false;
  String? _loadError;

  final _thumbnailService = PdfThumbnailService();
  List<_PageRotationState> _pages = [];

  /// وضع التحديد المتعدد: عند تفعيله، النقر على صفحة يُبدّل تحديدها بدل
  /// تدويرها مباشرة، ليتسنى تطبيق دوران جماعي بعدها عبر شريط الإجراءات.
  bool _selectionMode = false;


  int get _selectedCount => _pages.where((p) => p.isSelected).length;
  bool get _hasAnyRotation => _pages.any((p) => p.hasChanged);

  Future<void> _pickFile() async {
    final r = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (r?.files.first.path == null) return;
    final f = File(r!.files.first.path!);
    setState(() {
      _file = f;
      _pages = [];
      _loadError = null;
      _selectionMode = false;
    });
    await _loadThumbnails();
  }

  Future<void> _loadThumbnails() async {
    if (_file == null) return;
    setState(() {
      _isLoadingThumbnails = true;
      _loadError = null;
    });
    try {
      final thumbnails = await _thumbnailService.renderAllThumbnails(
        filePath: _file!.path,
      );
      // نقرأ زاوية الدوران المخزَّنة فعلياً في كل صفحة من الملف الأصلي
      // (عبر Syncfusion، لا pdfx) لنستخدمها كنقطة انطلاق صحيحة — التفصيل
      // الكامل لسبب أهمية هذا موجود في توثيق _PageRotationState أعلى.
      final originalAngles = <int, int>{};
      try {
        final bytes = await _file!.readAsBytes();
        final doc = PdfDocument(inputBytes: bytes);
        for (int i = 0; i < doc.pages.count; i++) {
          originalAngles[i + 1] = _fromSyncfusionAngle(doc.pages[i].rotation);
        }
        doc.dispose();
      } catch (_) {
        // إن فشلت قراءة الزوايا الأصلية لأي سبب، نفترض صفراً للجميع كحل
        // بديل آمن (نفس السلوك القديم) بدل فشل تحميل الصفحات بالكامل.
      }
      if (!mounted) return;
      setState(() {
        _pages = thumbnails
            .map((t) => _PageRotationState(
                  thumbnail: t,
                  originalAngle: originalAngles[t.pageNumber] ?? 0,
                ))
            .toList();
        _isLoadingThumbnails = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingThumbnails = false;
        _loadError = 'تعذّر تحميل صفحات الملف: $e';
      });
    }
  }


  // ─────────────────────────────────────────────────────────────────────
  // التفاعل الفوري: دوران/تحديد صفحة واحدة، ودوران جماعي للمحدَّد
  // ─────────────────────────────────────────────────────────────────────

  void _rotatePage(int index, {int by = 90}) {
    HapticFeedback.selectionClick();
    setState(() {
      final page = _pages[index];
      page.currentAngle = (page.currentAngle + by) % 360;
    });
  }

  void _onThumbnailTap(int index) {
    if (_selectionMode) {
      setState(() => _pages[index].isSelected = !_pages[index].isSelected);
    } else {
      _rotatePage(index);
    }
  }

  void _onThumbnailLongPress(int index) {
    HapticFeedback.mediumImpact();
    setState(() {
      _selectionMode = true;
      _pages[index].isSelected = true;
    });
  }

  void _toggleSelectAll() {
    HapticFeedback.selectionClick();
    final allSelected = _selectedCount == _pages.length;
    setState(() {
      for (final p in _pages) {
        p.isSelected = !allSelected;
      }
    });
  }

  void _rotateSelected({int by = 90}) {
    HapticFeedback.mediumImpact();
    setState(() {
      for (final p in _pages.where((p) => p.isSelected)) {
        p.currentAngle = (p.currentAngle + by) % 360;
      }
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      for (final p in _pages) {
        p.isSelected = false;
      }
    });
  }

  void _resetAllRotations() {
    HapticFeedback.lightImpact();
    setState(() {
      for (final p in _pages) {
        // نُرجع لزاويتها الأصلية المخزَّنة في الملف، لا لصفر مطلق —
        // "إعادة تعيين" تعني التراجع عن تعديلات المستخدم في هذه الجلسة،
        // لا فرض دوران صفر على صفحات كانت أصلاً مُدوَّرة في الملف المصدر.
        p.currentAngle = p.originalAngle;
      }
    });
  }

  int _fromSyncfusionAngle(PdfPageRotateAngle a) {
    switch (a) {
      case PdfPageRotateAngle.rotateAngle90:
        return 90;
      case PdfPageRotateAngle.rotateAngle180:
        return 180;
      case PdfPageRotateAngle.rotateAngle270:
        return 270;
      default:
        return 0;
    }
  }

  PdfPageRotateAngle _toSyncfusionAngle(int deg) {
    switch (deg % 360) {
      case 90:
        return PdfPageRotateAngle.rotateAngle90;
      case 180:
        return PdfPageRotateAngle.rotateAngle180;
      case 270:
        return PdfPageRotateAngle.rotateAngle270;
      default:
        return PdfPageRotateAngle.rotateAngle0;
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // الحفظ النهائي: يطبّق زاوية كل صفحة الفردية دفعة واحدة عبر Syncfusion.
  // ⚠️ مهم: PdfPageRotateAngle في Syncfusion تضبط زاوية الصفحة بشكل مطلق
  // (لا تراكمي إضافي فوق دوران PDF الأصلي المخزَّن في الملف). لهذا بالضبط
  // currentAngle هنا ليست "صفر دائماً كنقطة انطلاق" بل تبدأ من originalAngle
  // المقروءة فعلياً من الملف عند التحميل (انظر _PageRotationState وتعليقها
  // الكامل) — صفحة لم يلمسها المستخدم تُكتب بزاويتها الأصلية الصحيحة، لا
  // بصفر قد يُلغي دورانها الحقيقي المخزَّن مسبقاً (شائع في الملفات الممسوحة).
  // ─────────────────────────────────────────────────────────────────────

  Future<void> _saveRotated() async {
    if (_file == null) {
      _err('اختر ملف PDF أولاً');
      return;
    }
    if (!_hasAnyRotation) {
      _err('لم تُدوِّر أي صفحة بعد');
      return;
    }
    setState(() => _isProcessing = true);
    try {
      final bytes = await _file!.readAsBytes();
      final doc = PdfDocument(inputBytes: bytes);

      int rotatedCount = 0;
      for (final p in _pages) {
        // نكتب فقط للصفحات المتغيّرة فعلياً عن زاويتها الأصلية — لا حاجة
        // لإعادة كتابة rotation لصفحة لم يلمسها المستخدم (حتى لو كانت
        // زاويتها الأصلية غير صفر)، وهذا أيضاً يحمي من أي إعادة ضبط غير
        // مقصودة لصفحة لم تتغيّر فعلياً.
        if (!p.hasChanged) continue;
        final pageIndex = p.thumbnail.pageNumber - 1;
        if (pageIndex < doc.pages.count) {
          doc.pages[pageIndex].rotation = _toSyncfusionAngle(p.currentAngle);
          rotatedCount++;
        }
      }

      final outBytes = doc.saveSync();
      doc.dispose();

      final dir = await getTemporaryDirectory();
      final name = _file!.path.split('/').last.replaceAll('.pdf', '');
      final out = File('${dir.path}/${name}_مدوّر.pdf');
      await out.writeAsBytes(outBytes);

      if (!mounted) return;
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ResultScreen(
                    file: out,
                    title: 'تم التدوير!',
                    subtitle: 'تم تدوير $rotatedCount صفحة بنجاح',
                    toolId: 'rotate_pdf',
                    toolName: 'تدوير PDF',
                    settings: {'عدد الصفحات المدوَّرة': '$rotatedCount'},
                  )));
    } catch (e) {
      _err('خطأ: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _err(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.cairo()),
      backgroundColor: Colors.red.shade700,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ─────────────────────────────────────────────────────────────────────
  // البناء
  // ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const accent = Color(0xFF4FD1C5);
    const accentDark = Color(0xFF1D4044);

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
            _buildHeader(isDark, accent, accentDark),
            if (_file != null && _pages.isNotEmpty)
              _buildActionBar(isDark, accent, accentDark),
            Expanded(child: _buildBody(isDark, accent, accentDark)),
            if (_file != null && _pages.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: _buildSaveButton(accentDark),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _buildHeader(bool isDark, Color accent, Color accentDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(children: [
        GestureDetector(
          onTap: () {
            if (_selectionMode) {
              _exitSelectionMode();
              return;
            }
            Navigator.pop(context);
          },
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: isDark ? AppTheme.bgCardLight : Colors.white,
              border: Border.all(color: AppTheme.divider),
            ),
            child: Icon(
                _selectionMode
                    ? Icons.close_rounded
                    : Icons.arrow_back_ios_new_rounded,
                size: 18,
                color: AppTheme.textSecondary),
          ),
        ),
        const SizedBox(width: 14),
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient: LinearGradient(colors: [accentDark, accent]),
          ),
          child: const Icon(Icons.rotate_right_rounded,
              color: Colors.white, size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
              _selectionMode ? 'تم تحديد $_selectedCount صفحة' : 'تدوير PDF',
              style: GoogleFonts.cairo(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
        ),
        if (_file != null && _pages.isNotEmpty && !_selectionMode)
          GestureDetector(
            onTap: _pickFile,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: isDark ? AppTheme.bgCardLight : Colors.white,
                border: Border.all(color: AppTheme.divider),
              ),
              child: const Icon(Icons.swap_horiz_rounded,
                  size: 18, color: AppTheme.textSecondary),
            ),
          ),
      ]),
    );
  }

  /// شريط إجراءات يظهر فقط عند وجود ملف محمَّل: تحديد الكل/دوران جماعي
  /// في وضع التحديد، أو زر "إعادة تعيين الكل" + "تحديد" في الوضع العادي.
  Widget _buildActionBar(bool isDark, Color accent, Color accentDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: _selectionMode
          ? Row(children: [
              GestureDetector(
                onTap: _toggleSelectAll,
                child: Text(
                    _selectedCount == _pages.length ? 'إلغاء تحديد الكل' : 'تحديد الكل',
                    style: GoogleFonts.cairo(
                        fontSize: 12.5, fontWeight: FontWeight.w700, color: accentDark)),
              ),
              const Spacer(),
              _iconChip(Icons.rotate_left_rounded, accentDark, isDark,
                  enabled: _selectedCount > 0,
                  onTap: () => _rotateSelected(by: -90)),
              const SizedBox(width: 8),
              _iconChip(Icons.rotate_right_rounded, accentDark, isDark,
                  enabled: _selectedCount > 0,
                  onTap: () => _rotateSelected(by: 90)),
            ])
          : Row(children: [
              Text('${_pages.length} صفحة • انقر لتدوير، اضغط مطوّلاً للتحديد المتعدد',
                  style: GoogleFonts.cairo(fontSize: 11.5, color: AppTheme.textMuted)),
              const Spacer(),
              if (_hasAnyRotation)
                GestureDetector(
                  onTap: _resetAllRotations,
                  child: Text('إعادة تعيين',
                      style: GoogleFonts.cairo(
                          fontSize: 12, fontWeight: FontWeight.w700, color: Colors.red.shade400)),
                ),
            ]),
    );
  }

  Widget _iconChip(IconData icon, Color accentDark, bool isDark,
      {required bool enabled, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: enabled
              ? accentDark.withValues(alpha: 0.12)
              : AppTheme.bgCardLight,
        ),
        child: Icon(icon,
            size: 18, color: enabled ? accentDark : AppTheme.textMuted),
      ),
    );
  }

  Widget _buildBody(bool isDark, Color accent, Color accentDark) {
    if (_file == null) {
      return _buildPickFilePrompt(isDark, accent, accentDark);
    }
    if (_isLoadingThumbnails) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 14),
          Text('جارِ تحميل صفحات الملف...',
              style: GoogleFonts.cairo(fontSize: 12.5, color: AppTheme.textMuted)),
        ]),
      );
    }
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.error_outline_rounded, color: Colors.red.shade400, size: 36),
            const SizedBox(height: 10),
            Text(_loadError!,
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(fontSize: 13, color: Colors.red.shade400)),
            const SizedBox(height: 14),
            TextButton(onPressed: _loadThumbnails, child: const Text('إعادة المحاولة')),
          ]),
        ),
      );
    }
    return _buildThumbnailGrid(isDark, accent, accentDark);
  }

  Widget _buildPickFilePrompt(bool isDark, Color accent, Color accentDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GestureDetector(
          onTap: _pickFile,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: isDark ? AppTheme.bgCardLight : Colors.white,
              border: Border.all(color: AppTheme.divider),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [accentDark, accent]),
                ),
                child: const Icon(Icons.upload_file_rounded, color: Colors.white, size: 26),
              ),
              const SizedBox(height: 14),
              Text('اختر ملف PDF',
                  style: GoogleFonts.cairo(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
              const SizedBox(height: 4),
              Text('ستظهر كل صفحاته كشبكة قابلة للتدوير',
                  style: GoogleFonts.cairo(fontSize: 12, color: AppTheme.textMuted)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnailGrid(bool isDark, Color accent, Color accentDark) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
        childAspectRatio: 0.68,
      ),
      itemCount: _pages.length,
      itemBuilder: (context, index) {
        final page = _pages[index];
        return _ThumbnailCell(
          page: page,
          pageNumber: page.thumbnail.pageNumber,
          isDark: isDark,
          accentDark: accentDark,
          selectionMode: _selectionMode,
          onTap: () => _onThumbnailTap(index),
          onLongPress: () => _onThumbnailLongPress(index),
          onRotateLeft: () => _rotatePage(index, by: -90),
          onRotateRight: () => _rotatePage(index, by: 90),
        );
      },
    );
  }

  Widget _buildSaveButton(Color accentDark) {
    final enabled = !_isProcessing && _hasAnyRotation;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: enabled ? _saveRotated : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: accentDark,
          disabledBackgroundColor: AppTheme.bgCardLight,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        child: _isProcessing
            ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
                const SizedBox(width: 12),
                Text('جارٍ الحفظ...',
                    style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.w700)),
              ])
            : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white),
                const SizedBox(width: 10),
                Text('حفظ الملف المدوَّر',
                    style: GoogleFonts.cairo(
                        color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
              ]),
      ),
    );
  }
}

/// خلية مصغّرة واحدة في الشبكة: صورة الصفحة مُدوَّرة فورياً بصرياً، مع
/// مؤشر رقم الصفحة وأيقونتي دوران تظهران دوماً تحت كل خلية (نمط iLovePDF:
/// كل صفحة تحمل عناصر التحكم بها مباشرة، لا قائمة إعدادات منفصلة).
class _ThumbnailCell extends StatelessWidget {
  final _PageRotationState page;
  final int pageNumber;
  final bool isDark;
  final Color accentDark;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onRotateLeft;
  final VoidCallback onRotateRight;

  const _ThumbnailCell({
    required this.page,
    required this.pageNumber,
    required this.isDark,
    required this.accentDark,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
    required this.onRotateLeft,
    required this.onRotateRight,
  });

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: GestureDetector(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: page.isSelected
                    ? accentDark
                    : (page.hasChanged
                        ? accentDark.withValues(alpha: 0.5)
                        : AppTheme.divider.withValues(alpha: 0.5)),
                width: page.isSelected ? 2.5 : 1,
              ),
              color: Colors.white,
            ),
            child: Stack(children: [
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: Center(
                    // ⚠️ الصورة المصغّرة (مُرمَّزة عبر pdfx/PDFium) تُعرَض
                    // من البداية بزاويتها الأصلية originalAngle (PDFium
                    // يحترم الدوران المخزَّن في الملف عند الترميز). لذا
                    // الدوران البصري الإضافي المطلوب هنا فوقها هو **الفرق**
                    // (currentAngle - originalAngle) فقط، لا currentAngle
                    // المطلقة — استخدام المطلقة كان سيُدوِّر الصورة مرتين
                    // (مرة من PDFium نفسه، ومرة أخرى من AnimatedRotation).
                    //
                    // AnimatedRotation (لا Transform.rotate ثابت) يعطي
                    // انتقالاً بصرياً سلساً عند كل نقرة دوران، بدل قفزة
                    // فورية مفاجئة — يطابق الإحساس الحركي في التطبيقات
                    // المرجعية عند تدوير صفحة.
                    child: AnimatedRotation(
                      turns: (page.currentAngle - page.originalAngle) / 360,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      child: Image.memory(page.thumbnail.imageBytes,
                          fit: BoxFit.contain),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('$pageNumber',
                      style: GoogleFonts.cairo(
                          fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700)),
                ),
              ),
              if (selectionMode)
                Positioned(
                  top: 4,
                  left: 4,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: page.isSelected ? accentDark : Colors.white,
                      border: Border.all(
                          color: page.isSelected ? accentDark : Colors.black26),
                    ),
                    child: page.isSelected
                        ? const Icon(Icons.check_rounded, size: 13, color: Colors.white)
                        : null,
                  ),
                ),
            ]),
          ),
        ),
      ),
      const SizedBox(height: 4),
      if (!selectionMode)
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: onRotateLeft,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.rotate_left_rounded,
                    size: 16, color: AppTheme.textMuted),
              ),
            ),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: onRotateRight,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.rotate_right_rounded,
                    size: 16, color: AppTheme.textMuted),
              ),
            ),
          ],
        ),
    ]);
  }
}
