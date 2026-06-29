// ═══════════════════════════════════════════════════════════════════════════
//  حذف صفحات PDF — إعادة بناء كاملة: شبكة مصغّرات حقيقية + نقرة للتحديد
// ═══════════════════════════════════════════════════════════════════════════
//
//  الفرق الجوهري عن النسخة السابقة (شبكة أرقام صفحات نصية 44×44 بلا صور +
//  "أوضاع تحديد" منفصلة فردي/زوجي/نطاق + معاينة المستند في شاشة مستقلة
//  يجب الانتقال إليها والعودة):
//
//  هنا كل خلية في الشبكة صورة حقيقية لمحتوى الصفحة (عبر PdfThumbnailService،
//  نفس الخدمة المستخدَمة في أداة التدوير — إعادة استخدام مباشرة بلا أي
//  تعديل). نقرة واحدة على أي صفحة تُحدِّدها للحذف فوراً (تظليل أحمر شفاف +
//  أيقونة X واضحة)، نقرة ثانية تُلغي التحديد — تماماً نمط iLovePDF/Smallpdf.
//  لا حاجة لمعاينة منفصلة: رؤية الصفحة نفسها في الشبكة هي المعاينة.
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

class DeletePagesScreen extends StatefulWidget {
  const DeletePagesScreen({super.key});
  @override
  State<DeletePagesScreen> createState() => _DeletePagesScreenState();
}

class _DeletePagesScreenState extends State<DeletePagesScreen> {
  File? _file;
  bool _isProcessing = false;
  bool _isLoadingThumbnails = false;
  String? _loadError;

  final _thumbnailService = PdfThumbnailService();
  List<PdfThumbnail> _thumbnails = [];

  /// أرقام الصفحات المحدَّدة للحذف (1-indexed، يطابق PdfThumbnail.pageNumber
  /// مباشرة بلا أي تحويل فهرسة وسيط بين طبقات الكود المختلفة).
  final Set<int> _markedForDeletion = {};

  int get _pageCount => _thumbnails.length;
  int get _remainingCount => _pageCount - _markedForDeletion.length;
  bool get _canDelete =>
      _file != null &&
      !_isProcessing &&
      _markedForDeletion.isNotEmpty &&
      _markedForDeletion.length < _pageCount;


  Future<void> _pickFile() async {
    final r = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (r?.files.first.path == null) return;
    final f = File(r!.files.first.path!);
    setState(() {
      _file = f;
      _thumbnails = [];
      _markedForDeletion.clear();
      _loadError = null;
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
      final thumbnails =
          await _thumbnailService.renderAllThumbnails(filePath: _file!.path);
      if (!mounted) return;
      setState(() {
        _thumbnails = thumbnails;
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

  void _clearFile() {
    setState(() {
      _file = null;
      _thumbnails = [];
      _markedForDeletion.clear();
      _loadError = null;
    });
  }

  void _togglePage(int pageNumber) {
    final isCurrentlyMarked = _markedForDeletion.contains(pageNumber);
    // ⚠️ حماية: لا نسمح بتحديد كل الصفحات للحذف (يجب الإبقاء على صفحة
    // واحدة على الأقل) — نتحقق هنا أيضاً، لا فقط في زر الحذف النهائي،
    // حتى لا يصل المستخدم لحالة "محدَّد الكل" مطلقاً. الفحص والرسالة هنا
    // خارج setState عمداً: استدعاء ScaffoldMessenger من داخل callback
    // خاص بـ setState يخلط تغيير الحالة بأثر جانبي (عرض واجهة)، وهنا أيضاً
    // يضمن أن setState تُستدعى فقط عند تغيير فعلي في _markedForDeletion.
    if (!isCurrentlyMarked && _markedForDeletion.length >= _pageCount - 1) {
      _err('يجب الإبقاء على صفحة واحدة على الأقل في الملف');
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      if (isCurrentlyMarked) {
        _markedForDeletion.remove(pageNumber);
      } else {
        _markedForDeletion.add(pageNumber);
      }
    });
  }

  void _clearSelection() {
    HapticFeedback.lightImpact();
    setState(() => _markedForDeletion.clear());
  }

  Future<void> _deletePages() async {
    if (_file == null || _markedForDeletion.isEmpty) {
      _err('اختر صفحة واحدة على الأقل لحذفها');
      return;
    }
    if (_markedForDeletion.length >= _pageCount) {
      _err('لا يمكن حذف جميع الصفحات، يجب الإبقاء على صفحة واحدة على الأقل');
      return;
    }

    setState(() => _isProcessing = true);
    try {
      final bytes = await _file!.readAsBytes();
      final doc = PdfDocument(inputBytes: bytes);

      // فهرسة Syncfusion من الصفر، بينما _markedForDeletion مُخزَّنة
      // بترقيم 1-indexed (مطابقة لـ PdfThumbnail.pageNumber) — التحويل
      // (pageNumber - 1) هنا فقط، نقطة واحدة، بدل بعثرته بين عدة دوال.
      final zeroIndexed = _markedForDeletion.map((p) => p - 1).toList()
        ..sort((a, b) => b.compareTo(a)); // تنازلياً: الحذف من الأعلى
      // يحمي فهارس الصفحات السابقة من الانزياح أثناء الحذف المتتابع.
      for (final idx in zeroIndexed) {
        if (idx >= 0 && idx < doc.pages.count) {
          doc.pages.removeAt(idx);
        }
      }

      final outBytes = doc.saveSync();
      doc.dispose();

      final dir = await getTemporaryDirectory();
      final name = _file!.path.split('/').last.replaceAll('.pdf', '');
      final out = File('${dir.path}/${name}_بعد_الحذف.pdf');
      await out.writeAsBytes(outBytes);

      if (!mounted) return;
      final sortedAsc = _markedForDeletion.toList()..sort();
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ResultScreen(
                    file: out,
                    title: 'تم حذف الصفحات بنجاح!',
                    subtitle:
                        'تم حذف ${_markedForDeletion.length} صفحة من أصل $_pageCount\nالملف الجديد يحتوي على $_remainingCount صفحة',
                    toolId: 'delete_pages',
                    toolName: 'حذف الصفحات',
                    settings: {
                      'عدد الصفحات المحذوفة': '${_markedForDeletion.length}',
                      'أرقام الصفحات المحذوفة':
                          sortedAsc.map((i) => '$i').join('، '),
                      'الصفحات المتبقية': '$_remainingCount',
                    },
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const accent = Color(0xFFFC8181);
    const accentDark = Color(0xFFC53030);

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
            if (_file != null && _thumbnails.isNotEmpty)
              _buildSelectionBar(isDark, accentDark),
            Expanded(child: _buildBody(isDark, accent, accentDark)),
            if (_file != null && _thumbnails.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: _buildDeleteButton(accentDark),
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
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: isDark ? AppTheme.bgCardLight : Colors.white,
              border: Border.all(color: AppTheme.divider),
            ),
            child: const Icon(Icons.arrow_back_ios_new_rounded,
                size: 18, color: AppTheme.textSecondary),
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
          child: const Icon(Icons.auto_delete_rounded,
              color: Colors.white, size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text('حذف الصفحات',
              style: GoogleFonts.cairo(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
        ),
        if (_file != null && _thumbnails.isNotEmpty) ...[
          GestureDetector(
            onTap: _clearFile,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              margin: const EdgeInsets.only(left: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: isDark ? AppTheme.bgCardLight : Colors.white,
                border: Border.all(color: AppTheme.divider),
              ),
              child: const Icon(Icons.close_rounded,
                  size: 18, color: AppTheme.textSecondary),
            ),
          ),
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
        ],
      ]),
    );
  }

  /// شريط يوضّح بإيجاز عدد الصفحات المحدَّدة للحذف والمتبقية، مع زر مسح
  /// التحديد — يبقى المستخدم مطّلعاً على الأثر الكامل لقراراته دون الحاجة
  /// لعدّ العلامات الحمراء يدوياً عبر شبكة طويلة.
  Widget _buildSelectionBar(bool isDark, Color accentDark) {
    final hasSelection = _markedForDeletion.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Row(children: [
        Expanded(
          child: Text(
            hasSelection
                ? '${_markedForDeletion.length} صفحة محدَّدة للحذف • سيتبقى $_remainingCount'
                : 'انقر على أي صفحة لتحديدها للحذف',
            style: GoogleFonts.cairo(
                fontSize: 12.5,
                fontWeight: hasSelection ? FontWeight.w700 : FontWeight.w500,
                color: hasSelection ? accentDark : AppTheme.textMuted),
          ),
        ),
        if (hasSelection)
          GestureDetector(
            onTap: _clearSelection,
            child: Text('إلغاء التحديد',
                style: GoogleFonts.cairo(
                    fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textMuted)),
          ),
      ]),
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
              Text('ستظهر كل صفحاته كشبكة، انقر لتحديد ما تريد حذفه',
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
      itemCount: _thumbnails.length,
      itemBuilder: (context, index) {
        final thumb = _thumbnails[index];
        final isMarked = _markedForDeletion.contains(thumb.pageNumber);
        return _DeletableThumbnailCell(
          thumbnail: thumb,
          isMarked: isMarked,
          accentDark: accentDark,
          onTap: () => _togglePage(thumb.pageNumber),
        );
      },
    );
  }

  Widget _buildDeleteButton(Color accentDark) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _canDelete ? _deletePages : null,
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
                Text('جارٍ الحذف...',
                    style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.w700)),
              ])
            : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.delete_forever_rounded, color: Colors.white),
                const SizedBox(width: 10),
                Text(
                    _markedForDeletion.isEmpty
                        ? 'حدّد صفحات لحذفها'
                        : 'حذف ${_markedForDeletion.length} صفحة',
                    style: GoogleFonts.cairo(
                        color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
              ]),
      ),
    );
  }
}

/// خلية واحدة في شبكة الحذف: صورة حقيقية للصفحة، وعند التحديد للحذف تظليل
/// أحمر شفاف + أيقونة X واضحة فوقها مباشرة — هذا التمييز البصري الفوري
/// (لا انتظار حفظ نهائي لرؤية الأثر) هو جوهر نمط iLovePDF لحذف الصفحات.
class _DeletableThumbnailCell extends StatelessWidget {
  final PdfThumbnail thumbnail;
  final bool isMarked;
  final Color accentDark;
  final VoidCallback onTap;

  const _DeletableThumbnailCell({
    required this.thumbnail,
    required this.isMarked,
    required this.accentDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isMarked ? accentDark : AppTheme.divider.withValues(alpha: 0.5),
            width: isMarked ? 2.5 : 1,
          ),
          color: Colors.white,
        ),
        child: Stack(children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                // الصفحات المحدَّدة للحذف تُعتَّم بصرياً (لا تُحذَف من
                // الشبكة فورياً) — هذا يطابق توقّع المستخدم بإمكانية
                // التراجع بنقرة ثانية، ويُبقي ترقيم الصفحات المرئي ثابتاً
                // طوال جلسة التحديد (حذف فوري من الشبكة كان سيُحرّك كل
                // الصفحات اللاحقة، فيُربك عدّ "أي صفحة هذه أصلاً").
                opacity: isMarked ? 0.35 : 1.0,
                child: Image.memory(thumbnail.imageBytes, fit: BoxFit.contain),
              ),
            ),
          ),
          if (isMarked)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  color: accentDark.withValues(alpha: 0.12),
                ),
                child: Center(
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: accentDark,
                      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
                    ),
                    child: const Icon(Icons.close_rounded, color: Colors.white, size: 20),
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
              child: Text('${thumbnail.pageNumber}',
                  style: GoogleFonts.cairo(
                      fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
      ),
    );
  }
}
