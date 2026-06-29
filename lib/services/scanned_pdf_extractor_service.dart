/// خدمة استخراج صفحات PDF "ممسوحة" (صور مصوّرة محفوظة كـ PDF بدون طبقة
/// نص) كصور منفصلة، لتمريرها لاحقاً لمحرك OCR صفحة بصفحة.
///
/// تستخدم `PdfPageRenderService` الموجودة فعلياً في المشروع (نفس الخدمة
/// التي تستخدمها أداة التوقيع لعرض صفحة PDF بدقة 1:1) بدل تكرار منطق
/// ترندر PDF بمكتبة مختلفة — هذا يحافظ على تناسق الجودة ويستفيد من
/// pdfx (PDFium) الموجودة مسبقاً كاعتمادية.
///
/// ⚠️ ملاحظة دقّة مهمة: `PdfPageRenderService.renderPage` تُعيد الصورة
/// بدقة محسوبة من `pixelRatio` (صورة = أبعاد الصفحة بالنقاط × pixelRatio)
/// لا بدقة DPI مباشرة. صفحة A4 (595×842 نقطة) بـ pixelRatio=2.0 تُعطي
/// صورة 1190×1684px تقريباً، أي ما يقارب 144 DPI فعلياً (72 نقطة/إنش ×
/// 2). لأغراض OCR نحتاج دقة أعلى من المعاينة العادية (300 DPI تقريباً
/// هي الموصى بها صناعياً لـ Tesseract)، فنستخدم pixelRatio أعلى من
/// الافتراضي (2.0) المستخدَم في أداة التوقيع.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../pdf_engine/pdf_page_render_service.dart';

/// نتيجة استخراج صفحة واحدة من PDF كصورة.
class ExtractedPdfPage {
  final int pageNumber; // 1-indexed، يطابق ترقيم PdfPageRenderService
  final File imageFile;
  final int widthPx;
  final int heightPx;

  const ExtractedPdfPage({
    required this.pageNumber,
    required this.imageFile,
    required this.widthPx,
    required this.heightPx,
  });
}

class ScannedPdfExtractorService {
  /// نسبة بكسل توازي تقريباً 300 نقطة/إنش لصفحة A4 قياسية (72pt/inch
  /// الأساس × ~4.17 ≈ 300dpi). قيمة عملية موصى بها لدقة OCR جيدة دون
  /// تضخيم حجم الصورة الناتجة بلا داعٍ.
  static const double recommendedOcrPixelRatio = 4.0;

  /// يستخرج كل صفحات ملف PDF كصور PNG منفصلة في مجلد مؤقت.
  static Future<List<ExtractedPdfPage>> extractPagesAsImages(
    File pdfFile, {
    double pixelRatio = recommendedOcrPixelRatio,
    void Function(int currentPage, int totalPages)? onProgress,
  }) async {
    final renderService = PdfPageRenderService();
    final pageCount = await renderService.getPageCount(pdfFile.path);

    if (pageCount <= 0) {
      throw const FormatException(
        'لم يتم العثور على صفحات صالحة في ملف PDF. تحقق من أن الملف غير تالف.',
      );
    }

    final tempDir = await getTemporaryDirectory();
    final sessionDir = Directory(
      '${tempDir.path}/ocr_pdf_extract_${DateTime.now().millisecondsSinceEpoch}',
    );
    await sessionDir.create(recursive: true);

    final results = <ExtractedPdfPage>[];

    // PdfPageRenderService.renderPage هي 1-indexed (تطابق ترقيم Syncfusion
    // +1 حسب توثيق pdf_thumbnail_service.dart المشابهة).
    for (int pageNumber = 1; pageNumber <= pageCount; pageNumber++) {
      onProgress?.call(pageNumber, pageCount);

      final rendered = await renderService.renderPage(
        filePath: pdfFile.path,
        pageNumber: pageNumber,
        pixelRatio: pixelRatio,
      );

      final pageFile = File(
        '${sessionDir.path}/page_${pageNumber.toString().padLeft(4, '0')}.png',
      );
      await pageFile.writeAsBytes(rendered.imageBytes);

      // أبعاد الصورة الفعلية بالبكسل = أبعاد الصفحة بالنقاط × pixelRatio
      // (هذا تماماً ما طلبناه عبر width/height في PdfPageRenderService.renderPage،
      // فلا حاجة لفك تشفير الصورة من جديد لقراءة أبعادها).
      final widthPx = (rendered.pageWidthPt * pixelRatio).round();
      final heightPx = (rendered.pageHeightPt * pixelRatio).round();

      results.add(ExtractedPdfPage(
        pageNumber: pageNumber,
        imageFile: pageFile,
        widthPx: widthPx,
        heightPx: heightPx,
      ));
    }

    return results;
  }

  /// يحذف مجلد الصفحات المؤقتة بعد انتهاء معالجة OCR لكل الصفحات.
  static Future<void> cleanup(List<ExtractedPdfPage> pages) async {
    if (pages.isEmpty) return;
    final dir = pages.first.imageFile.parent;
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}
