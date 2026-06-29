import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';

// استخدام الـ Aliases لمنع التعارض في الأسماء
import 'package:syncfusion_flutter_pdf/pdf.dart' as sync_pdf;
import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:flutter_image_compress/flutter_image_compress.dart';

import '../../theme/app_theme.dart';
import '../result_screen.dart';

class CompressPdfScreen extends StatefulWidget {
  const CompressPdfScreen({super.key});
  @override
  State<CompressPdfScreen> createState() => _CompressPdfScreenState();
}

class _CompressPdfScreenState extends State<CompressPdfScreen> with SingleTickerProviderStateMixin {
  File? _selectedFile;
  bool _isProcessing = false;
  int _selectedLevel = 1;
  int? _originalSize;
  int? _pageCount;
  String _processingStep = '';
  double _processingProgress = 0;

  final _levels = [
    const _Level('ضغط أقصى', 'أصغر حجم ممكن - مناسب للمشاركة السريعة', Icons.compress_rounded, Color(0xFFFC8181), 30, 'ضغط عالي'),
    const _Level('متوازن', 'توازن مثالي - جودة جيدة مع حجم معقول جداً', Icons.balance_rounded, Color(0xFFECC94B), 50, 'ضغط متوسط'),
    const _Level('جودة عالية', 'أفضل وضوح - مناسب للطباعة والأرشيف الرسمي', Icons.hd_rounded, AppTheme.accent, 80, 'ضغط خفيف'),
    const _Level('بدون ضغط', 'حفظ الملف بجودته الأصلية الكاملة بدون تعديل', Icons.verified_outlined, Color(0xFF9F7AEA), 100, 'بدون تغيير'),
  ];

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.05).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
      if (result?.files.first.path != null) {
        final file = File(result!.files.first.path!);
        
        // جلب عدد الصفحات باستخدام pdfx
        final doc = await pdfx.PdfDocument.openFile(file.path);
        final pages = doc.pagesCount;
        await doc.close();

        setState(() {
          _selectedFile = file;
          _originalSize = file.lengthSync();
          _pageCount = pages;
        });
        HapticFeedback.lightImpact();
      }
    } catch (e) {
      _showError('عذراً، لا يمكن قراءة هذا الملف. تأكد من أنه ملف PDF صالح وغير محمي.');
    }
  }

  Future<void> _compress() async {
    if (_selectedFile == null) return;
    setState(() {
      _isProcessing = true;
      _processingStep = 'جاري التهيئة للضغط...';
      _processingProgress = 0;
    });

    try {
      final tempDir = await getTemporaryDirectory();
      final targetQuality = _levels[_selectedLevel].imageQuality;

      if (targetQuality == 100) {
        _passOriginalFile();
        return;
      }

      // ⚠️ قيد تقني مهم يجب أن يعرفه أي مطوّر يعدّل هذا الملف لاحقاً:
      // هذه الطريقة تُحوِّل كل صفحة بالكامل إلى صورة (raster) ثم تضغط تلك
      // الصورة كـ JPEG — بما في ذلك صفحات تحتوي نصاً قابلاً للنسخ أصلاً.
      // النتيجة: أي PDF نصي يفقد نصه القابل للبحث/التحديد/النسخ بالكامل
      // بعد "الضغط"، ويصبح صورة بحتة حتى عند مستوى "جودة عالية". التطبيقات
      // المرجعية (iLovePDF/Smallpdf) تضغط الصور المُضمَّنة داخل PDF فقط
      // وتحافظ على النص كنص حقيقي — وهذا فارق جوهري في الناتج، لا في
      // الواجهة. أُبقي هذا المنطق كما هو بناءً على تأكيد المستخدم أن نطاق
      // هذا التعديل هو الواجهة فقط، ووضعت ملاحظة مرئية صغيرة في الواجهة
      // أدناه (_buildTextWarningNote) لتنبيه المستخدم النهائي لهذا القيد.
      final pdfDocument = await pdfx.PdfDocument.openFile(_selectedFile!.path);
      final totalPages = pdfDocument.pagesCount;

      final newDoc = sync_pdf.PdfDocument();

      for (int i = 1; i <= totalPages; i++) {
        setState(() {
          _processingStep = 'جاري معالجة وضغط الصفحة ($i من $totalPages)...';
          _processingProgress = totalPages > 0 ? i / totalPages : 0;
        });

        final page = await pdfDocument.getPage(i);
        
        // تحويل الصفحة إلى صورة (مضاعفة الأبعاد للحفاظ على الدقة قبل الضغط)
        final pageImage = await page.render(
          width: page.width * 2,
          height: page.height * 2,
          format: pdfx.PdfPageImageFormat.jpeg,
        );

        if (pageImage != null) {
          // 3. ضغط الصورة الفعلية لتقليل الحجم بشكل حقيقي
          final compressedImageBytes = await FlutterImageCompress.compressWithList(
            pageImage.bytes,
            quality: targetQuality,
            format: CompressFormat.jpeg,
          );

          // ضبط أبعاد الصفحة الجديدة لتطابق أبعاد الصفحة الأصلية
          newDoc.pageSettings.size = Size(page.width, page.height);
          newDoc.pageSettings.margins.all = 0;
          
          // 4. إضافة الصفحة الجديدة ورسم الصورة المضغوطة بداخلها
          final newPage = newDoc.pages.add();
          final compressedPdfBitmap = sync_pdf.PdfBitmap(compressedImageBytes);
          
          newPage.graphics.drawImage(
            compressedPdfBitmap,
            Rect.fromLTWH(0, 0, page.width, page.height),
          );
        }
        await page.close(); // إغلاق الصفحة لتحرير الذاكرة
      }

      await pdfDocument.close();

      setState(() => _processingStep = 'جاري كتابة وتصدير ملف الـ PDF الجديد...');
      final outBytes = newDoc.saveSync();
      newDoc.dispose();

      final name = _selectedFile!.path.split('/').last.replaceAll('.pdf', '');
      final out = File('${tempDir.path}/${name}_مضغوط.pdf');
      await out.writeAsBytes(outBytes);

      final newSize = out.lengthSync();
      final saved = _originalSize != null && _originalSize! > 0
          ? (((_originalSize! - newSize) / _originalSize!) * 100).clamp(0, 100).toStringAsFixed(1)
          : '0';

      if (!mounted) return;
      HapticFeedback.heavyImpact();
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ResultScreen(
        file: out, 
        title: 'تم الضغط الفعلي بنجاح!',
        subtitle: 'تم توفير $saved% من الحجم الأصلي للملف\n${_formatSize(_originalSize ?? 0)} ← ${_formatSize(newSize)}',
        toolId: 'compress_pdf', 
        toolName: 'ضغط PDF',
        settings: {
          'مستوى الضغط': _levels[_selectedLevel].label, 
          'عدد الصفحات': '$totalPages صفحات',
          'الحجم الأصلي': _formatSize(_originalSize ?? 0), 
          'الحجم الجديد': _formatSize(newSize), 
          'نسبة التوفير الحقيقية': '$saved%'
        },
      )));
    } catch (e) {
      _showError('حدث خطأ غير متوقع أثناء معالجة المستند وضغط الصور.');
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _processingStep = '';
          _processingProgress = 0;
        });
      }
    }
  }

  void _passOriginalFile() async {
    final tempDir = await getTemporaryDirectory();
    final name = _selectedFile!.path.split('/').last.replaceAll('.pdf', '');
    final out = File('${tempDir.path}/${name}_نسخة.pdf');
    await _selectedFile!.copy(out.path);

    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ResultScreen(
      file: out,
      title: 'اكتملت العملية',
      subtitle: 'تم حفظ الملف بالجودة الأصلية الكاملة دون تغيير في الحجم.',
      toolId: 'compress_pdf',
      toolName: 'ضغط PDF',
      settings: {
        'مستوى الضغط': 'بدون تغيير',
        'الحجم الحالي': _formatSize(_originalSize ?? 0),
      },
    )));
  }

  void _showError(String message) {
    if (!mounted) return;
    HapticFeedback.vibrate();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.error_outline_rounded, color: Colors.white),
        const SizedBox(width: 12),
        Expanded(child: Text(message, style: GoogleFonts.cairo(color: Colors.white))),
      ]),
      backgroundColor: const Color(0xFFE53E3E),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(20),
    ));
  }

  String _formatSize(int bytes) {
    if (bytes > 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    if (bytes > 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      backgroundColor: isDark ? AppTheme.bgDark : const Color(0xFFF8F9FE),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: isDark ? Colors.white : const Color(0xFF1A1A2E), size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('ضغط PDF حقيقي', style: GoogleFonts.cairo(fontSize: 22, fontWeight: FontWeight.bold, color: isDark ? Colors.white : const Color(0xFF1A1A2E))),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                children: [
                  GestureDetector(
                    onTap: _isProcessing ? null : _pickFile,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                      width: double.infinity,
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        color: isDark ? AppTheme.bgCardLight : Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: _selectedFile != null 
                                ? const Color(0xFFECC94B).withValues(alpha: 0.15) 
                                : Colors.black.withValues(alpha: 0.03),
                            blurRadius: 20,
                            offset: const Offset(0, 8),
                          )
                        ],
                        border: Border.all(
                          color: _selectedFile != null 
                              ? const Color(0xFFECC94B).withValues(alpha: 0.8) 
                              : (isDark ? AppTheme.divider : Colors.grey.shade200),
                          width: _selectedFile != null ? 2 : 1.5,
                        ),
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 400),
                        child: _selectedFile == null
                            ? Column(
                                key: const ValueKey('empty'),
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(18),
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: const Color(0xFFECC94B).withValues(alpha: 0.1),
                                    ),
                                    child: const Icon(Icons.cloud_upload_rounded, color: Color(0xFFD69E2E), size: 42),
                                  ),
                                  const SizedBox(height: 20),
                                  Text('اختر ملف PDF للضغط', style: GoogleFonts.cairo(fontSize: 18, fontWeight: FontWeight.bold, color: isDark ? Colors.white : const Color(0xFF1A1A2E))),
                                  const SizedBox(height: 6),
                                  Text('سيتم إعادة بناء وضغط محتوى الملف الفعلي', style: GoogleFonts.cairo(fontSize: 14, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600)),
                                ],
                              )
                            : Row(
                                key: const ValueKey('file'),
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(16),
                                      color: const Color(0xFFE53E3E).withValues(alpha: 0.1),
                                    ),
                                    child: const Icon(Icons.picture_as_pdf_rounded, color: Color(0xFFE53E3E), size: 32),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _selectedFile!.path.split('/').last,
                                          style: GoogleFonts.cairo(fontSize: 15, fontWeight: FontWeight.bold, color: isDark ? Colors.white : const Color(0xFF1A1A2E)),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            Text(_formatSize(_originalSize ?? 0), style: GoogleFonts.cairo(fontSize: 13, color: const Color(0xFFD69E2E), fontWeight: FontWeight.w600)),
                                            if (_pageCount != null) ...[
                                              Container(margin: const EdgeInsets.symmetric(horizontal: 8), width: 4, height: 4, decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.grey)),
                                              Text('$_pageCount صفحة', style: GoogleFonts.cairo(fontSize: 13, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600)),
                                            ]
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (!_isProcessing)
                                    IconButton(
                                      onPressed: () => setState(() { _selectedFile = null; _originalSize = null; _pageCount = null; }),
                                      icon: const Icon(Icons.close_rounded),
                                      color: Colors.grey.shade500,
                                      style: IconButton.styleFrom(backgroundColor: isDark ? Colors.grey.shade800 : Colors.grey.shade100),
                                    ),
                                ],
                              ),
                      ),
                    ),
                  ),
                  
                  AnimatedOpacity(
                    opacity: _selectedFile != null ? 1.0 : 0.4,
                    duration: const Duration(milliseconds: 300),
                    child: IgnorePointer(
                      ignoring: _selectedFile == null || _isProcessing,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 32),
                          Text('إعدادات مستوى الضغط', style: GoogleFonts.cairo(fontSize: 18, fontWeight: FontWeight.bold, color: isDark ? Colors.white : const Color(0xFF1A1A2E))),
                          const SizedBox(height: 16),
                          
                          ...List.generate(_levels.length, (i) {
                            final level = _levels[i];
                            final isSelected = _selectedLevel == i;
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: GestureDetector(
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  setState(() => _selectedLevel = i);
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 250),
                                  padding: const EdgeInsets.all(18),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(20),
                                    color: isSelected ? level.color.withValues(alpha: 0.08) : (isDark ? AppTheme.bgCardLight : Colors.white),
                                    border: Border.all(
                                      color: isSelected ? level.color : (isDark ? AppTheme.divider : Colors.grey.shade200),
                                      width: isSelected ? 2 : 1.5,
                                    ),
                                    boxShadow: isSelected ? [
                                      BoxShadow(color: level.color.withValues(alpha: 0.1), blurRadius: 12, offset: const Offset(0, 4))
                                    ] : [],
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 48,
                                        height: 48,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: isSelected ? level.color : level.color.withValues(alpha: 0.1),
                                        ),
                                        child: Icon(level.icon, color: isSelected ? Colors.white : level.color, size: 24),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                              children: [
                                                Text(level.label, style: GoogleFonts.cairo(fontSize: 16, fontWeight: FontWeight.bold, color: isDark ? Colors.white : const Color(0xFF1A1A2E))),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                                  decoration: BoxDecoration(
                                                    color: level.color.withValues(alpha: 0.15),
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                  child: Text(level.tag, style: GoogleFonts.cairo(fontSize: 12, fontWeight: FontWeight.bold, color: level.color)),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            Text(level.subtitle, style: GoogleFonts.cairo(fontSize: 12, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600, height: 1.5)),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }),

                          // ⚠️ ملاحظة مرئية للمستخدم: تظهر فقط عند اختيار
                          // مستوى ضغط فعلي (ليس "بدون ضغط")، لأن طريقة
                          // الضغط الحالية تحوّل كل صفحة لصورة — فيفقد أي
                          // نص قابل للنسخ/البحث في الملف الأصلي هذه الخاصية
                          // بعد الضغط. هذا تنبيه صادق بدل ترك المستخدم
                          // يكتشف هذا القيد بعد إنتاج الملف.
                          if (_selectedLevel != _levels.length - 1)
                            Container(
                              margin: const EdgeInsets.only(top: 4),
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.04),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(Icons.info_outline_rounded,
                                      size: 18, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'يحوّل الضغط كل صفحة إلى صورة، لذا لن يكون النص بعده قابلاً للنسخ أو البحث.',
                                      style: GoogleFonts.cairo(
                                          fontSize: 11.5,
                                          color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                                          height: 1.5),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 30),
                ],
              ),
            ),
            
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: isDark ? AppTheme.bgCardLight : Colors.white,
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 20, offset: const Offset(0, -5))],
                borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
              ),
              child: SafeArea(
                top: false,
                child: SizedBox(
                  width: double.infinity,
                  height: 60,
                  child: _isProcessing 
                    ? Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFD69E2E).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // ⚠️ مؤشر بقيمة فعلية محسوبة (value:) بدل
                            // المؤشر غير المحدَّد السابق — يعطي إفادة
                            // بصرية حقيقية لمدى الاكتمال، مهم خاصة
                            // للملفات الكبيرة التي تستغرق وقتاً طويلاً.
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                value: _processingProgress > 0 ? _processingProgress : null,
                                color: const Color(0xFFD69E2E),
                                strokeWidth: 2.5,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(child: Text(_processingStep, style: GoogleFonts.cairo(color: const Color(0xFFD69E2E), fontWeight: FontWeight.bold, fontSize: 14), overflow: TextOverflow.ellipsis)),
                            if (_processingProgress > 0)
                              Text('${(_processingProgress * 100).toInt()}%',
                                  style: GoogleFonts.cairo(color: const Color(0xFFD69E2E), fontWeight: FontWeight.w800, fontSize: 13)),
                          ],
                        ),
                      )
                    : ScaleTransition(
                        scale: _selectedFile != null ? _pulseAnimation : const AlwaysStoppedAnimation(1.0),
                        child: ElevatedButton(
                          onPressed: _selectedFile == null ? null : _compress,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFD69E2E),
                            disabledBackgroundColor: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
                            elevation: _selectedFile != null ? 8 : 0,
                            shadowColor: const Color(0xFFD69E2E).withValues(alpha: 0.5),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.auto_awesome_rounded, color: _selectedFile != null ? Colors.white : Colors.grey.shade500),
                              const SizedBox(width: 12),
                              Text('بدء الضغط الذكي', style: GoogleFonts.cairo(color: _selectedFile != null ? Colors.white : Colors.grey.shade500, fontWeight: FontWeight.bold, fontSize: 17)),
                            ],
                          ),
                        ),
                      ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Level {
  final String label, subtitle, tag;
  final IconData icon;
  final Color color;
  final int imageQuality;
  const _Level(this.label, this.subtitle, this.icon, this.color, this.imageQuality, this.tag);
}
