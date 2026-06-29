// ═══════════════════════════════════════════════════════════════════════════
//  تقسيم PDF — إعادة بناء كاملة: فواصل تقسيم بين صفحات شبكة مصغّرات حقيقية
// ═══════════════════════════════════════════════════════════════════════════
//
//  الفرق الجوهري عن النسخة السابقة (بطاقات "من صفحة X إلى صفحة Y" نصية
//  قابلة للإضافة/الحذف، بلا أي رؤية لمحتوى الصفحات):
//
//  هنا تُعرَض كل صفحات المستند كشبكة صور حقيقية (عبر PdfThumbnailService،
//  نفس الخدمة المستخدَمة في أدوات التدوير/الحذف)، وبين كل صفحتين متتاليتين
//  يوجد مقبض فاصل صغير قابل للنقر — تفعيله يعني "ابدأ ملفاً جديداً هنا".
//  هذا تطابق مباشر مع أداة iLovePDF "Split PDF" الرسمية، وأدق بكثير من
//  إدخال أرقام صفحات يدوياً (المستخدم يرى الصفحة نفسها، لا رقمها فقط).
//
//  ⚠️ ملاحظة تقنية مهمة: منطق التقسيم الفعلي (PdfSplitService و
//  _splitPdfIsolate في الأسفل) لم يُلمَس بأي حرف — تصميمه سليم تماماً
//  (يعمل عبر compute() في Isolate منفصل لتفادي تجميد الواجهة على ملفات
//  كبيرة، ويُمرِّر مسار الملف لا بايتاته لتوفير الذاكرة). التغيير الوحيد
//  هو الواجهة وكيف تُحسَب نطاقات PdfRangeData من مواضع الفواصل التي
//  يختارها المستخدم بصرياً، بدل إدخالها يدوياً.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../../pdf_engine/pdf_thumbnail_service.dart';

// ============================================================================
// 1. نماذج البيانات (Models)
// ============================================================================

class PdfRangeData {
  final int from;
  final int to;
  PdfRangeData({required this.from, required this.to});
}

// ============================================================================
// 2. خدمة معالجة وتقسيم الـ PDF (Business Logic) — بلا أي تعديل
// ============================================================================

class PdfSplitService {
  Future<List<File>> split({
    required String sourcePath,
    required String prefix,
    required List<PdfRangeData> ranges,
    required int totalPages,
  }) async {
    for (var i = 0; i < ranges.length; i++) {
      final r = ranges[i];
      if (r.from <= 0 || r.to <= 0) {
        throw Exception("النطاق ${i + 1} يحتوي على قيم سالبة أو صفرية.");
      }
      if (r.from > totalPages || r.to > totalPages) {
        throw Exception("النطاق ${i + 1} يتجاوز العدد الكلي لصفحات الملف ($totalPages).");
      }
    }

    List<bool> used = List.filled(totalPages, false);
    for (var range in ranges) {
      int start = range.from < range.to ? range.from : range.to;
      int end = range.from > range.to ? range.from : range.to;
      for (int i = start; i <= end; i++) {
        if (used[i - 1]) {
          throw Exception("هناك تداخل بين النطاقات عند الصفحة $i.");
        }
        used[i - 1] = true;
      }
    }

    final dir = await getTemporaryDirectory();
    final outPaths = await compute(_splitPdfIsolate, {
      'path': sourcePath,
      'dirPath': dir.path,
      'prefix': prefix,
      'ranges': ranges.map((r) => {'from': r.from, 'to': r.to}).toList(),
      'maxPages': totalPages,
    });

    return outPaths.map((p) => File(p)).toList();
  }
}

Future<List<String>> _splitPdfIsolate(Map<String, dynamic> args) async {
  final String path = args['path'];
  final String dirPath = args['dirPath'];
  final String prefix = args['prefix'];
  final List<Map<String, int>> ranges = args['ranges'];
  final int maxPages = args['maxPages'];

  final file = File(path);
  final bytes = file.readAsBytesSync();
  final srcDoc = PdfDocument(inputBytes: bytes);

  final List<String> outPaths = [];
  int fileIndex = 1;

  for (var range in ranges) {
    int start = (range['from']! - 1).clamp(0, maxPages - 1);
    int end = (range['to']! - 1).clamp(0, maxPages - 1);
    if (start > end) {
      int temp = start;
      start = end;
      end = temp;
    }

    final outDoc = PdfDocument();
    outDoc.pageSettings.margins.all = 0;

    for (int i = start; i <= end; i++) {
      final sourcePage = srcDoc.pages[i];
      outDoc.pageSettings.size = sourcePage.size;
      outDoc.pageSettings.rotate = sourcePage.rotation;
      final page = outDoc.pages.add();
      page.graphics.drawPdfTemplate(sourcePage.createTemplate(), const Offset(0, 0));
    }

    final outPath = '$dirPath/${prefix}_جزء$fileIndex.pdf';
    await File(outPath).writeAsBytes(outDoc.saveSync());
    outPaths.add(outPath);
    fileIndex++;
    outDoc.dispose();
  }

  srcDoc.dispose();
  return outPaths;
}

// ============================================================================
// 3. الشاشة الرئيسية: شبكة مصغّرات + فواصل تقسيم قابلة للتبديل
// ============================================================================

class SplitPdfScreen extends StatefulWidget {
  const SplitPdfScreen({super.key});
  @override
  State<SplitPdfScreen> createState() => _SplitPdfScreenState();
}

class _SplitPdfScreenState extends State<SplitPdfScreen> {
  File? _file;
  bool _isProcessing = false;
  bool _isLoadingThumbnails = false;
  String? _loadError;

  final _thumbnailService = PdfThumbnailService();
  List<PdfThumbnail> _thumbnails = [];

  /// مواضع الفواصل: قيمة n في هذه المجموعة تعني "يوجد فاصل بعد الصفحة n"
  /// (1-indexed، مطابق لـ PdfThumbnail.pageNumber). فاصل بعد آخر صفحة غير
  /// منطقي ولا يُعرَض أصلاً (لا توجد صفحة بعدها لتبدأ ملفاً جديداً منها).
  final Set<int> _splitAfter = {};

  int get _pageCount => _thumbnails.length;

  /// عدد الملفات الناتجة = عدد الفواصل المفعَّلة + 1 (قطعة واحدة دوماً
  /// حتى بلا أي فاصل، تساوي المستند كاملاً غير مُقسَّم).
  int get _resultingFileCount => _splitAfter.length + 1;

  Future<void> _pickFile() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (r?.files.first.path == null) return;
    final f = File(r!.files.first.path!);
    setState(() {
      _file = f;
      _thumbnails = [];
      _splitAfter.clear();
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
      final thumbnails = await _thumbnailService.renderAllThumbnails(filePath: _file!.path);
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

  void _toggleSplitAfter(int pageNumber) {
    if (pageNumber >= _pageCount) return;
    HapticFeedback.selectionClick();
    setState(() {
      if (_splitAfter.contains(pageNumber)) {
        _splitAfter.remove(pageNumber);
      } else {
        _splitAfter.add(pageNumber);
      }
    });
  }

  void _clearAllSplits() {
    HapticFeedback.lightImpact();
    setState(() => _splitAfter.clear());
  }

  void _splitEveryPage() {
    HapticFeedback.mediumImpact();
    setState(() {
      _splitAfter
        ..clear()
        ..addAll(List.generate(_pageCount - 1, (i) => i + 1));
    });
  }

  List<PdfRangeData> _computeRangesFromSplits() {
    final sortedSplits = _splitAfter.toList()..sort();
    final ranges = <PdfRangeData>[];
    int rangeStart = 1;
    for (final splitPoint in sortedSplits) {
      ranges.add(PdfRangeData(from: rangeStart, to: splitPoint));
      rangeStart = splitPoint + 1;
    }
    ranges.add(PdfRangeData(from: rangeStart, to: _pageCount));
    return ranges;
  }

  Future<void> _processSplit() async {
    if (_file == null) {
      _err('اختر ملف PDF أولاً');
      return;
    }
    final ranges = _computeRangesFromSplits();
    setState(() => _isProcessing = true);
    try {
      final service = PdfSplitService();
      final name = _file!.path.split('/').last.replaceAll('.pdf', '');
      final outFiles = await service.split(
        sourcePath: _file!.path,
        prefix: name.isNotEmpty ? name : 'مستند',
        ranges: ranges,
        totalPages: _pageCount,
      );
      if (!mounted) return;
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => SplitSuccessScreen(files: outFiles)));
    } catch (e) {
      if (!mounted) return;
      _err(e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _err(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.cairo(fontWeight: FontWeight.w600)),
      backgroundColor: Colors.redAccent,
      behavior: SnackBarBehavior.floating,
    ));
  }

  static const _bgColor = Color(0xFF171721);
  static const _cardColor = Color(0xFF252535);
  static const _accent = Color(0xFF8B5CF6);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      body: SafeArea(
        child: Column(children: [
          _buildHeader(),
          if (_file != null && _thumbnails.isNotEmpty) _buildToolbar(),
          Expanded(child: _buildBody()),
          if (_file != null && _thumbnails.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              child: _buildSplitButton(),
            ),
        ]),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.arrow_back, color: Colors.white70, size: 20),
          ),
        ),
        const SizedBox(width: 14),
        Text('تقسيم PDF',
            style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20)),
        const Spacer(),
        if (_file != null && _thumbnails.isNotEmpty)
          GestureDetector(
            onTap: _pickFile,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.swap_horiz_rounded, color: Colors.white70, size: 18),
            ),
          ),
      ]),
    );
  }

  Widget _buildToolbar() {
    final hasSplits = _splitAfter.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Row(children: [
        Expanded(
          child: Text(
            hasSplits
                ? 'سينتج $_resultingFileCount ملف • انقر على المقبض بين الصفحات للتبديل'
                : '$_pageCount صفحة • انقر على المقبض بين أي صفحتين لتقسيمهما',
            style: GoogleFonts.cairo(
                fontSize: 12, color: hasSplits ? _accent : Colors.white54, fontWeight: hasSplits ? FontWeight.w700 : FontWeight.w500),
          ),
        ),
        if (_pageCount > 1)
          GestureDetector(
            onTap: _splitAfter.length == _pageCount - 1 ? _clearAllSplits : _splitEveryPage,
            child: Text(
              _splitAfter.length == _pageCount - 1 ? 'إلغاء الكل' : 'فصل كل صفحة',
              style: GoogleFonts.cairo(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white54),
            ),
          ),
      ]),
    );
  }

  Widget _buildBody() {
    if (_file == null) return _buildPickPrompt();
    if (_isLoadingThumbnails) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(color: _accent),
          const SizedBox(height: 14),
          Text('جارِ تحميل صفحات الملف...', style: GoogleFonts.cairo(fontSize: 12.5, color: Colors.white54)),
        ]),
      );
    }
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 36),
            const SizedBox(height: 10),
            Text(_loadError!, textAlign: TextAlign.center, style: GoogleFonts.cairo(fontSize: 13, color: Colors.redAccent)),
            const SizedBox(height: 14),
            TextButton(onPressed: _loadThumbnails, child: const Text('إعادة المحاولة')),
          ]),
        ),
      );
    }
    if (_pageCount <= 1) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('هذا الملف يحتوي صفحة واحدة فقط، لا يمكن تقسيمه',
              textAlign: TextAlign.center, style: GoogleFonts.cairo(fontSize: 13, color: Colors.white54)),
        ),
      );
    }
    return _buildThumbnailGridWithSplits();
  }

  Widget _buildPickPrompt() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GestureDetector(
          onTap: _pickFile,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), color: _cardColor),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: _accent),
                child: const Icon(Icons.upload_file_rounded, color: Colors.white, size: 26),
              ),
              const SizedBox(height: 14),
              Text('اختر ملف PDF', style: GoogleFonts.cairo(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
              const SizedBox(height: 4),
              Text('ستظهر كل صفحاته، انقر بينها لتحديد نقاط التقسيم',
                  style: GoogleFonts.cairo(fontSize: 12, color: Colors.white54)),
            ]),
          ),
        ),
      ),
    );
  }

  /// الشبكة الأساسية: نعرض الصفحات في عمود واحد بعرض كامل (لا شبكة
  /// متعددة الأعمدة)، حتى يكون مقبض الفاصل بين كل صفحتين متتاليتين
  /// واضحاً بصرياً ومباشراً (أفقياً بين كل صفحة والتي تليها في تسلسل
  /// القراءة) — أوضح من فواصل قطرية داخل شبكة متعددة الأعمدة قد تُربك
  /// العين حول "أي جانب من الصفحة" يقع الفاصل.
  Widget _buildThumbnailGridWithSplits() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      itemCount: _pageCount * 2 - 1, // صفحة، فاصل، صفحة، فاصل، ...، صفحة
      itemBuilder: (context, i) {
        if (i.isEven) {
          final pageIndex = i ~/ 2;
          return _PageRow(thumbnail: _thumbnails[pageIndex]);
        }
        final afterPage = (i - 1) ~/ 2 + 1; // رقم الصفحة التي قبل هذا الفاصل
        final isActive = _splitAfter.contains(afterPage);
        return _SplitHandle(
          isActive: isActive,
          onTap: () => _toggleSplitAfter(afterPage),
        );
      },
    );
  }

  Widget _buildSplitButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _isProcessing ? null : _processSplit,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          disabledBackgroundColor: Colors.white54,
          padding: const EdgeInsets.symmetric(vertical: 16),
          minimumSize: const Size(double.infinity, 56),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: _isProcessing
            ? const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2.5))
            : Text(
                _splitAfter.isEmpty ? 'تصدير الملف كما هو' : 'تقسيم إلى $_resultingFileCount ملفات',
                style: GoogleFonts.cairo(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 17),
              ),
      ),
    );
  }
}

/// صف صفحة واحدة في القائمة: صورة الصفحة + رقمها — بعرض كامل، لا شبكة
/// متعددة الأعمدة (انظر تعليق _buildThumbnailGridWithSplits للسبب).
class _PageRow extends StatelessWidget {
  final PdfThumbnail thumbnail;
  const _PageRow({required this.thumbnail});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: const Color(0xFF252535),
      ),
      padding: const EdgeInsets.all(10),
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.06)),
          child: Text('${thumbnail.pageNumber}',
              style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
        ),
        const SizedBox(width: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            // ⚠️ إصلاح: AspectRatio كانت هنا سابقاً، لكنها بداخل Row بلا
            // ارتفاع محدد من الأعلى تنهار لحجم صفري فعلياً (Row يمرر
            // ارتفاعاً غير محدود لعناصره على المحور المتعامد ما لم يُقيَّد
            // صريحاً)، فيختفي كل محتوى الصفحة بصرياً دون أي خطأ ظاهر في
            // الواجهة. الحل: نحسب العرض مباشرة من الارتفاع الثابت (90)
            // ونسبة الصفحة الحقيقية، بدل ترك AspectRatio يتفاوض حول حجم
            // غير موجود أصلاً.
            height: 90,
            width: 90 * thumbnail.aspectRatio,
            child: Image.memory(thumbnail.imageBytes, fit: BoxFit.contain),
          ),
        ),
      ]),
    );
  }
}

/// مقبض الفاصل بين صفحتين متتاليتين: خط رفيع، يتحوّل لخط بنفسجي واضح +
/// أيقونة مقص عند التفعيل. هذا التمييز البصري الفوري بين "متصل" و"مفصول"
/// هو جوهر نمط iLovePDF لتقسيم الصفحات.
class _SplitHandle extends StatelessWidget {
  final bool isActive;
  final VoidCallback onTap;
  const _SplitHandle({required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF8B5CF6);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 36,
        alignment: Alignment.center,
        child: Row(children: [
          Expanded(
            child: Container(
              height: isActive ? 2 : 1,
              decoration: BoxDecoration(color: isActive ? accent : Colors.white.withValues(alpha: 0.12)),
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: isActive ? accent : Colors.white.withValues(alpha: 0.06),
              border: Border.all(color: isActive ? accent : Colors.white.withValues(alpha: 0.15)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(isActive ? Icons.content_cut_rounded : Icons.add_rounded,
                  size: 14, color: isActive ? Colors.white : Colors.white54),
              if (isActive) ...[
                const SizedBox(width: 4),
                Text('تقسيم هنا', style: GoogleFonts.cairo(fontSize: 10.5, fontWeight: FontWeight.w700, color: Colors.white)),
              ],
            ]),
          ),
          Expanded(
            child: Container(
              height: isActive ? 2 : 1,
              decoration: BoxDecoration(color: isActive ? accent : Colors.white.withValues(alpha: 0.12)),
            ),
          ),
        ]),
      ),
    );
  }
}

// ============================================================================
// 4. شاشة النجاح — بلا أي تعديل عن النسخة الأصلية (منطق الحفظ/المشاركة سليم)
// ============================================================================

class SplitSuccessScreen extends StatelessWidget {
  final List<File> files;
  const SplitSuccessScreen({super.key, required this.files});

  String _fmtSize(int b) =>
      b > 1048576 ? '${(b / 1048576).toStringAsFixed(1)} MB' : '${(b / 1024).toStringAsFixed(0)} KB';

  Future<void> _saveSingleFile(BuildContext context, File file) async {
    try {
      String destPath = '';

      if (Platform.isAndroid) {
        if (await Permission.manageExternalStorage.status.isDenied) {
          await Permission.manageExternalStorage.request();
        }
        if (await Permission.storage.status.isDenied) {
          await Permission.storage.request();
        }
        if (!await Permission.manageExternalStorage.isGranted && !await Permission.storage.isGranted) {
          throw Exception('يجب الموافقة على صلاحية التخزين لنتمكن من حفظ الملف.');
        }
        Directory dir = Directory('/storage/emulated/0/Download');
        if (!await dir.exists()) {
          dir = (await getExternalStorageDirectory()) ?? dir;
        }
        destPath = dir.path;
      } else if (Platform.isIOS) {
        final dir = await getApplicationDocumentsDirectory();
        destPath = dir.path;
      } else {
        final dir = await getDownloadsDirectory();
        destPath = dir?.path ?? '';
      }

      if (destPath.isEmpty) {
        throw Exception('لم نتمكن من تحديد مسار الحفظ في جهازك.');
      }

      String fileName = file.path.split('/').last;
      String nameWithoutExt = fileName.replaceAll('.pdf', '');
      String newPath = '$destPath/$fileName';

      bool isSaved = false;
      int counter = 1;
      while (!isSaved) {
        try {
          if (await File(newPath).exists()) {
            newPath = '$destPath/${nameWithoutExt}_($counter).pdf';
            counter++;
            continue;
          }
          await file.copy(newPath);
          isSaved = true;
        } catch (e) {
          if (e is FileSystemException && e.osError?.errorCode == 17) {
            newPath = '$destPath/${nameWithoutExt}_($counter).pdf';
            counter++;
          } else {
            rethrow;
          }
        }
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Row(children: [
            const Icon(Icons.check_circle, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
                child: Text('تم حفظ\n${newPath.split('/').last}\nفي التنزيلات (Downloads)',
                    style: GoogleFonts.cairo(fontWeight: FontWeight.bold, color: Colors.white))),
          ]),
          backgroundColor: const Color(0xFF42D09E),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.all(20),
        ));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('حدث خطأ: ${e.toString().replaceAll("Exception: ", "")}',
              style: GoogleFonts.cairo(fontWeight: FontWeight.bold)),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ));
        debugPrint('Save Error: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const bgColor = Color(0xFF171721);
    const cardColor = Color(0xFF252535);

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Column(children: [
          Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.close, color: Colors.white70, size: 20),
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(children: [
                const SizedBox(height: 10),
                Container(
                  width: 90,
                  height: 90,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF42D09E),
                    boxShadow: [BoxShadow(color: Color(0x3342D09E), blurRadius: 20, spreadRadius: 5)],
                  ),
                  child: const Icon(Icons.check_rounded, color: Colors.white, size: 50),
                ),
                const SizedBox(height: 24),
                Text('تم التقسيم بنجاح!', style: GoogleFonts.cairo(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
                const SizedBox(height: 8),
                Text('تم استخراج ${files.length} ملف بنجاح', style: GoogleFonts.cairo(fontSize: 14, color: Colors.white54)),
                const SizedBox(height: 32),
                Expanded(
                  child: ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    itemCount: files.length,
                    itemBuilder: (context, index) {
                      final file = files[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(16)),
                        child: Column(children: [
                          Row(children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(color: const Color(0xFFE55D5D), borderRadius: BorderRadius.circular(12)),
                              child: const Text('PDF', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(file.path.split('/').last,
                                    style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 4),
                                Text(_fmtSize(file.lengthSync()), style: GoogleFonts.cairo(color: Colors.white54, fontSize: 12)),
                              ]),
                            ),
                          ]),
                          const SizedBox(height: 16),
                          Divider(color: Colors.white.withValues(alpha: 0.05), height: 1, thickness: 1),
                          const SizedBox(height: 8),
                          Row(children: [
                            Expanded(
                              child: TextButton.icon(
                                onPressed: () => _saveSingleFile(context, file),
                                icon: const Icon(Icons.download_rounded, size: 20, color: Color(0xFF8B5CF6)),
                                label: Text('حفظ الملف', style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextButton.icon(
                                onPressed: () => SharePlus.instance.share(
                                    ShareParams(files: [XFile(file.path)])),
                                icon: const Icon(Icons.share_rounded, size: 20, color: Color(0xFF4FD1C5)),
                                label: Text('مشاركة', style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                              ),
                            ),
                          ]),
                        ]),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.only(bottom: 24),
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: cardColor,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: Text('العودة للرئيسية', style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
