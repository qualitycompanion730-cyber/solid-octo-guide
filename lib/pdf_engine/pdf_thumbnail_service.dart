// ═══════════════════════════════════════════════════════════════════════════
//  PdfThumbnailService — ترميز كل صفحات المستند كصور مصغّرة
// ═══════════════════════════════════════════════════════════════════════════
//
//  الفرق عن PdfPageRenderService (المستخدمة في أداة التوقيع): هناك كانت
//  الحاجة لصفحة واحدة بدقة عالية (لوضع توقيع دقيق فوقها). هنا الحاجة
//  معكوسة: عدد كبير من الصفحات معاً (قد يصل لعشرات أو مئات)، لكن بدقة
//  منخفضة جداً (مصغّرات شبكة)، لتفادي استهلاك ذاكرة مفرط لو رمّزنا كل
//  صفحة بدقة كاملة دفعة واحدة.
//
//  نفس قيد pdfx الموثّق (إغلاق الصفحة قبل فتح التالية على أندرويد) يُطبَّق
//  هنا بصرامة أكبر فعلياً، لأننا نفتح/نغلق عدد كبير من الصفحات بالتتابع
//  ضمن حلقة واحدة، لا مرة واحدة معزولة.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:typed_data';
import 'package:pdfx/pdfx.dart' as pdfx;

class PdfThumbnail {
  final int pageNumber; // 1-indexed، يطابق ترقيم Syncfusion +1
  final Uint8List imageBytes;
  final double aspectRatio; // width/height الأصلي للصفحة، لعرض الخلية بنسبة صحيحة

  const PdfThumbnail({
    required this.pageNumber,
    required this.imageBytes,
    required this.aspectRatio,
  });
}

class PdfThumbnailService {
  /// يُرمِّز كل صفحات المستند كصور مصغّرة بعرض منطقي ثابت [thumbnailWidth]
  /// (بالنقاط)، فيُحسَب الارتفاع تلقائياً حسب نسبة كل صفحة على حدة (بعض
  /// المستندات تحتوي صفحات بأبعاد مختلطة).
  Future<List<PdfThumbnail>> renderAllThumbnails({
    required String filePath,
    double thumbnailWidth = 200,
  }) async {
    final document = await pdfx.PdfDocument.openFile(filePath);
    final thumbnails = <PdfThumbnail>[];
    try {
      for (int i = 1; i <= document.pagesCount; i++) {
        final page = await document.getPage(i);
        try {
          final aspect = page.width / page.height;
          final image = await page.render(
            width: thumbnailWidth,
            height: thumbnailWidth / aspect,
            format: pdfx.PdfPageImageFormat.png,
            backgroundColor: '#FFFFFF',
          );
          if (image != null) {
            thumbnails.add(PdfThumbnail(
              pageNumber: i,
              imageBytes: image.bytes,
              aspectRatio: aspect,
            ));
          }
        } finally {
          // ⚠️ إلزامي حسب توثيق pdfx لأندرويد، وهنا بشكل متكرر لكل صفحة
          // ضمن الحلقة — أهم نقطة فشل محتملة لو نُسيت هنا بالتحديد.
          await page.close();
        }
      }
    } finally {
      await document.close();
    }
    return thumbnails;
  }

  /// يُرمِّز الصفحة الأولى فقط من المستند — مفيدة لقوائم تضم عدة ملفات
  /// (كأداة الدمج)، حيث نحتاج معاينة سريعة واحدة لكل ملف لا كل صفحاته،
  /// لتفادي ترميز عشرات/مئات الصفحات غير الضرورية عند عرض قائمة ملفات
  /// متعددة دفعة واحدة.
  Future<PdfThumbnail?> renderFirstPageThumbnail({
    required String filePath,
    double thumbnailWidth = 120,
  }) async {
    final document = await pdfx.PdfDocument.openFile(filePath);
    try {
      if (document.pagesCount == 0) return null;
      final page = await document.getPage(1);
      try {
        final aspect = page.width / page.height;
        final image = await page.render(
          width: thumbnailWidth,
          height: thumbnailWidth / aspect,
          format: pdfx.PdfPageImageFormat.png,
          backgroundColor: '#FFFFFF',
        );
        if (image == null) return null;
        return PdfThumbnail(pageNumber: 1, imageBytes: image.bytes, aspectRatio: aspect);
      } finally {
        await page.close();
      }
    } finally {
      await document.close();
    }
  }
}
