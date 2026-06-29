import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../../theme/app_theme.dart';
import '../../pdf_engine/pdf_thumbnail_service.dart';
import '../result_screen.dart';

// -----------------------------------------------------------------------------
// دالة مساعدة تعمل في مسار خلفي (Isolate) لدمج الملفات دون تجميد واجهة المستخدم
// تم تحسينها لمعالجة عدد لا محدود من الملفات بأمان عالٍ
// -----------------------------------------------------------------------------
Future<Uint8List> _mergePdfsInIsolate(List<String> filePaths) async {
  final merged = PdfDocument();
  // إزالة الهوامش الافتراضية نهائياً من المستند المدمج
  merged.pageSettings.margins.all = 0;
  // استخدام مستوى الضغط العادي بدلاً من best لتفادي تجمّد الـ CPU أثناء معالجة القوالب الثقيلة
  merged.compressionLevel = PdfCompressionLevel.normal;

  // قائمة حيوية للاحتفاظ بالمستندات المصدرية حية لمنع انهيار القوالب (Templates)
  final List<PdfDocument> sourceDocuments = [];

  try {
    for (final path in filePaths) {
      final file = File(path);
      final fileName = path.split(RegExp(r'[/\\]')).last;

      // التأكد من أن الملف لا يزال موجوداً فعلياً في مسار النظام ولم يتم حذفه
      if (!file.existsSync()) {
        throw Exception(
            'الملف "$fileName" غير موجود، قد يكون تم حذفه أو نقله بواسطة النظام.');
      }

      PdfDocument src;
      try {
        // قراءة الملف
        final bytes = await file.readAsBytes();
        src = PdfDocument(inputBytes: bytes);
        // [مهم جداً] إضافة المستند للقائمة للحفاظ على الموارد (الخطوط والصور) في الذاكرة
        sourceDocuments.add(src);
      } catch (_) {
        throw Exception(
            'تعذر فتح "$fileName" — قد يكون الملف تالفاً أو محمياً بكلمة مرور.');
      }

      try {
        for (int i = 0; i < src.pages.count; i++) {
          final srcPage = src.pages[i];

          // استنساخ خصائص الصفحة الأصلية بدقة (الحجم والدوران)
          merged.pageSettings.size = srcPage.size;
          merged.pageSettings.rotate = srcPage.rotation;

          final destPage = merged.pages.add();
          // تمرير الحجم صراحةً يضمن ملء الصفحة الهدف بالضبط دون انزياح
          destPage.graphics.drawPdfTemplate(
            srcPage.createTemplate(),
            const Offset(0, 0),
            Size(srcPage.size.width, srcPage.size.height),
          );
        }
      } catch (_) {
        throw Exception(
            'حدث خطأ أثناء معالجة صفحات الملف "$fileName". تأكد من سلامة محتواه.');
      }
      // تمت إزالة src.dispose() من هنا لأن القالب سيفشل في الحفظ إذا تم التخلص من المستند الآن.
    }

    if (merged.pages.count == 0) {
      throw Exception('الملفات المختارة لا تحتوي على أي صفحات.');
    }

    // الآن وبما أن المستندات المصدرية لا تزال حية في الذاكرة، سينجح الحفظ بدون تعليق.
    return Uint8List.fromList(merged.saveSync());
  } finally {
    // 1. التخلص من المستند النهائي من الذاكرة
    merged.dispose();
    // 2. التخلص من جميع المستندات المصدرية بأمان "بعد" انتهاء عملية حفظ الناتج
    for (final src in sourceDocuments) {
      try {
        src.dispose();
      } catch (_) {}
    }
  }
}

/// عنصر ملف مختار مع بياناته المخبأة (الاسم، الحجم، ومعرف فريد)
class _PdfItem {
  final String
      id; // معرف فريد للسماح بإضافة نفس الملف أكثر من مرة إذا رغب المستخدم
  final String path;
  final String name;
  final int size;

  /// صورة مصغّرة لأول صفحة من الملف — تبدأ null وتُحدَّث بعد اكتمال
  /// الترميز غير المتزامن (انظر _loadThumbnailFor في الشاشة). null تعني
  /// "لم يكتمل الترميز بعد أو فشل"، وتُعرَض أيقونة بديلة في كل الحالتين.
  Uint8List? thumbnail;

  _PdfItem(
      {required this.id,
      required this.path,
      required this.name,
      required this.size,
      // ignore: unused_element_parameter
      this.thumbnail});
}

class MergePdfScreen extends StatefulWidget {
  const MergePdfScreen({super.key});

  @override
  State<MergePdfScreen> createState() => _MergePdfScreenState();
}

class _MergePdfScreenState extends State<MergePdfScreen> {
  final List<_PdfItem> _files = [];
  bool _isProcessing = false;
  String _outputName = '';
  final _thumbnailService = PdfThumbnailService();

  // إجمالي الحجم محسوب من القيم المخبأة
  int get _totalSize => _files.fold(0, (sum, item) => sum + item.size);

  String _formatSize(int bytes) {
    if (bytes > 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  /// صياغة عربية سليمة لعدد الملفات: ملفين / 3 ملفات / 11 ملفاً
  String _filesCountLabel(int n) {
    if (n == 2) return 'ملفين';
    if (n >= 3 && n <= 10) return '$n ملفات';
    return '$n ملفاً';
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      allowMultiple: true,
    );

    if (result == null) return;
    final newItems = <_PdfItem>[];
    setState(() {
      for (final f in result.files) {
        if (f.path == null) continue;
        // إعطاء ID فريد يسمح للمستخدم بتكرار نفس الملف في القائمة (مثلاً لعمل غلاف متكرر)
        final uniqueId = '${DateTime.now().microsecondsSinceEpoch}_${f.name}';

        final item = _PdfItem(
          id: uniqueId,
          path: f.path!,
          name: f.name,
          size: f.size,
        );
        _files.add(item);
        newItems.add(item);
      }
    });
    // ⚠️ ترميز المصغّرات غير متزامن وخارج setState عمداً: الملفات تظهر في
    // القائمة فوراً (بأيقونة بديلة)، وتتحدّث كل بطاقة بصورتها الحقيقية
    // فور اكتمال ترميزها — بلا أي تجميد للواجهة أثناء انتظار كل الترميزات
    // معاً قبل عرض أي شيء.
    for (final item in newItems) {
      _loadThumbnailFor(item);
    }
  }

  Future<void> _loadThumbnailFor(_PdfItem item) async {
    try {
      final thumb = await _thumbnailService.renderFirstPageThumbnail(filePath: item.path);
      if (!mounted || thumb == null) return;
      // الملف قد يكون أُزيل من القائمة قبل اكتمال الترميز (المستخدم سريع)؛
      // نتحقق من وجوده فعلياً قبل استدعاء setState لتفادي إعادة بناء غير
      // ضرورية أو الإشارة لعنصر لم يعد جزءاً من القائمة المعروضة.
      if (!_files.any((f) => f.id == item.id)) return;
      setState(() => item.thumbnail = thumb.imageBytes);
    } catch (_) {
      // فشل ترميز مصغّرة واحدة لا يجب أن يُفسد تجربة الدمج بالكامل —
      // العنصر يبقى بأيقونة بديلة، والدمج الفعلي لاحقاً (عبر Syncfusion)
      // غير متأثر إطلاقاً بهذا الفشل لأنه مسار مستقل تماماً.
    }
  }

  void _removeFile(int index) {
    HapticFeedback.lightImpact();
    setState(() => _files.removeAt(index));
  }

  void _clearAllFiles() {
    HapticFeedback.mediumImpact();
    setState(() => _files.clear());
  }

  /// ⚠️ تحديث API: onReorderItem (الإصدار الحالي من Flutter) تُعدِّل معامل
  /// newIndex تلقائياً لحساب إزاحة العنصر المحذوف من oldIndex — بخلاف
  /// onReorder القديمة (المهجورة الآن) التي كانت تتطلب هذا التصحيح اليدوياً
  /// (if (newIndex > oldIndex) newIndex--;). تطبيق التصحيحين معاً (تصحيح
  /// يدوي + onReorderItem) يُطبِّق الإزاحة مرتين فيُنتج ترتيباً خاطئاً، لذا
  /// أُزيل التصحيح اليدوي القديم بالكامل عند الانتقال لـ onReorderItem.
  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final item = _files.removeAt(oldIndex);
      _files.insert(newIndex, item);
    });
    HapticFeedback.selectionClick();
  }

  /// تنظيف اسم الملف المدخل مع ضمان عدم خروج اسم فارغ
  String _sanitizedOutputName() {
    var name = _outputName.trim();
    // إبقاء الحروف العربية واللاتينية والأرقام والمسافات والشرطات فقط
    name = name
        .replaceAll(RegExp(r'[^\w\u0600-\u06FF\s\-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    if (name.isEmpty) {
      name = 'merged_${DateTime.now().millisecondsSinceEpoch}';
    }
    return name;
  }

  Future<void> _merge() async {
    if (_files.length < 2) return;

    // تم إزالة قيد الحجم تماماً للسماح بدمج لا محدود

    final mergedCount = _files.length;
    setState(() => _isProcessing = true);

    try {
      final filePaths = _files.map((e) => e.path).toList();

      // تنفيذ عملية الدمج الثقيلة في مسار خلفي للحفاظ على سلاسة الواجهة
      final Uint8List mergedBytes =
          await compute(_mergePdfsInIsolate, filePaths);

      final dir = await getTemporaryDirectory();
      final out = File('${dir.path}/${_sanitizedOutputName()}.pdf');
      await out.writeAsBytes(mergedBytes);

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ResultScreen(
            file: out,
            title: 'تم الدمج بنجاح! 🎉',
            subtitle:
                'تم دمج ${_filesCountLabel(mergedCount)} في ملف PDF واحد بشكل مثالي',
            toolId: 'merge_pdf',
            toolName: 'دمج PDF',
            settings: {'عدد الملفات المدموجة': '$mergedCount'},
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      // عرض رسالة الاستثناء العربية الواضحة من الـ Isolate إن وُجدت
      final msg = e.toString().replaceFirst('Exception: ', '');
      _showError(msg.startsWith('تعذر') ||
              msg.startsWith('الملف') ||
              msg.startsWith('حدث')
          ? msg
          : 'حدث خطأ غير متوقع أثناء الدمج: $msg');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline_rounded, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(child: Text(msg, style: GoogleFonts.cairo())),
          ],
        ),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
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
              : const LinearGradient(
                  colors: [Color(0xFFF5F5FF), Color(0xFFEEEEFF)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(isDark),
              if (_files.isNotEmpty) _buildStatsBar(isDark),
              Expanded(
                child: _files.isEmpty
                    ? _buildEmptyState(isDark)
                    : _buildFileList(isDark),
              ),
              _buildBottomBar(isDark),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
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
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'دمج PDF',
                style: GoogleFonts.cairo(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color:
                      isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E),
                ),
              ),
              Text(
                'اسحب لإعادة ترتيب الملفات',
                style:
                    GoogleFonts.cairo(fontSize: 12, color: AppTheme.textMuted),
              ),
            ],
          ),
          const Spacer(),
          if (_files.isNotEmpty)
            GestureDetector(
              onTap: _isProcessing ? null : _pickFiles,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: AppTheme.primaryGradient,
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.primary.withValues(alpha: 0.2),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    )
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.add_rounded,
                        color: Colors.white, size: 18),
                    const SizedBox(width: 4),
                    Text(
                      'إضافة',
                      style: GoogleFonts.cairo(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatsBar(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.sd_storage_rounded,
                  size: 16, color: AppTheme.textSecondary),
              const SizedBox(width: 6),
              Text(
                'الإجمالي: ${_formatSize(_totalSize)}',
                style: GoogleFonts.cairo(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
          GestureDetector(
            onTap: _isProcessing ? null : _clearAllFiles,
            child: Text(
              'حذف الكل',
              style: GoogleFonts.cairo(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Colors.red.shade400,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: GestureDetector(
        onTap: _pickFiles,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 130,
              height: 130,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isDark ? AppTheme.bgCardLight : Colors.white,
                border: Border.all(
                  color: AppTheme.primary.withValues(alpha: 0.3),
                  width: 2,
                  style: BorderStyle.solid,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primary.withValues(alpha: 0.1),
                    blurRadius: 30,
                  )
                ],
              ),
              child: Icon(Icons.merge_rounded,
                  size: 54, color: AppTheme.primary.withValues(alpha: 0.7)),
            ),
            const SizedBox(height: 24),
            Text(
              'اختر ملفات PDF للدمج',
              style: GoogleFonts.cairo(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'يمكنك دمج أي عدد من الملفات بدون حدود',
              style: GoogleFonts.cairo(
                  fontSize: 14, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 32),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: AppTheme.primaryGradient,
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primary.withValues(alpha: 0.35),
                    blurRadius: 20,
                  )
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.folder_open_rounded,
                      color: Colors.white, size: 22),
                  const SizedBox(width: 10),
                  Text(
                    'تصفح الملفات',
                    style: GoogleFonts.cairo(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileList(bool isDark) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      physics: const BouncingScrollPhysics(),
      itemCount: _files.length,
      onReorderItem: _reorder,
      proxyDecorator: (child, index, animation) => Material(
        color: Colors.transparent,
        elevation: 10,
        shadowColor: Colors.black26,
        borderRadius: BorderRadius.circular(16),
        child: child,
      ),
      itemBuilder: (context, index) {
        final item = _files[index];
        return Container(
          // استخدام ID فريد لضمان عمل ReorderableListView بسلاسة حتى لو تكرر الملف
          key: ValueKey(item.id),
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: isDark ? AppTheme.bgCardLight : Colors.white,
            border: Border.all(color: AppTheme.divider.withValues(alpha: 0.5)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.02),
                blurRadius: 5,
                offset: const Offset(0, 2),
              )
            ],
          ),
          child: Row(
            children: [
              // ⚠️ معاينة حقيقية لأول صفحة من الملف بدل أيقونة رقم ثابتة
              // — تساعد عند دمج ملفات بأسماء غير واضحة (مثل scan001.pdf).
              // رقم الترتيب لا يزال مرئياً كعلامة صغيرة فوق الصورة، فلا
              // نخسر إفادة "هذا هو الملف رقم N في الترتيب الحالي".
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 40,
                    height: 52,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: AppTheme.primary.withValues(alpha: 0.06),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: item.thumbnail != null
                          ? Image.memory(item.thumbnail!, fit: BoxFit.cover)
                          : Icon(Icons.picture_as_pdf_rounded,
                              color: AppTheme.primary.withValues(alpha: 0.4), size: 20),
                    ),
                  ),
                  Positioned(
                    top: -6,
                    right: -6,
                    child: Container(
                      width: 20,
                      height: 20,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppTheme.primary,
                        border: Border.all(
                            color: isDark ? AppTheme.bgCardLight : Colors.white, width: 1.5),
                      ),
                      child: Text(
                        '${index + 1}',
                        style: GoogleFonts.cairo(
                            fontSize: 10, color: Colors.white, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      style: GoogleFonts.cairo(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? AppTheme.textPrimary
                            : const Color(0xFF1A1A2E),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _formatSize(item.size),
                      style: GoogleFonts.cairo(
                          fontSize: 12, color: AppTheme.textMuted),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: _isProcessing ? null : () => _removeFile(index),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.red.withValues(alpha: 0.1),
                  ),
                  child: const Icon(Icons.close_rounded,
                      size: 16, color: Colors.red),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.drag_indicator_rounded,
                  color: AppTheme.textMuted),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBottomBar(bool isDark) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF131324) : Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 20,
            offset: const Offset(0, -5),
          )
        ],
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_files.isNotEmpty) ...[
            TextField(
              onChanged: (v) => _outputName = v,
              enabled: !_isProcessing,
              textInputAction: TextInputAction.done,
              style: GoogleFonts.cairo(
                color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E),
              ),
              decoration: InputDecoration(
                hintText: 'اسم الملف الناتج (اختياري)',
                hintStyle:
                    GoogleFonts.cairo(color: AppTheme.textMuted, fontSize: 13),
                filled: true,
                fillColor: isDark ? AppTheme.bgCard : const Color(0xFFF8F8FF),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                prefixIcon: const Icon(Icons.drive_file_rename_outline_rounded,
                    color: AppTheme.textMuted, size: 20),
              ),
            ),
            const SizedBox(height: 16),
          ],
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: (_files.length < 2 || _isProcessing) ? null : _merge,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                disabledBackgroundColor: AppTheme.bgCardLight,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: _files.length < 2 ? 0 : 5,
                shadowColor: AppTheme.primary.withValues(alpha: 0.4),
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _isProcessing
                    ? Row(
                        key: const ValueKey('processing'),
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.5,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'جارٍ دمج الملفات بدقة...',
                            style: GoogleFonts.cairo(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      )
                    : Row(
                        key: const ValueKey('idle'),
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.auto_awesome_rounded,
                              color: Colors.white),
                          const SizedBox(width: 10),
                          Text(
                            _files.length < 2
                                ? 'اختر ملفين على الأقل'
                                : 'دمج ${_filesCountLabel(_files.length)} الآن',
                            style: GoogleFonts.cairo(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
