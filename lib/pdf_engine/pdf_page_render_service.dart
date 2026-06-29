// ═══════════════════════════════════════════════════════════════════════════
//  PdfPageRenderService — ترميز صفحة PDF كصورة بأبعاد حقيقية معروفة
// ═══════════════════════════════════════════════════════════════════════════
//
//  لماذا هذا الملف موجود:
//  Syncfusion (المستخدمة في باقي التطبيق لإنشاء/تعديل PDF) لا تدعم تحويل
//  صفحة PDF إلى صورة — هذه حقيقة موثّقة من Syncfusion نفسها، وليست قصوراً
//  مؤقتاً. ولأن "سحب التوقيع فوق الصفحة بدقة 1:1" يتطلب معرفة الأبعاد
//  الحقيقية للصفحة المعروضة بالضبط (لا تقدير من خلال widget خارجي لا يكشف
//  هذه المعلومة)، أضفنا مكتبة `pdfx` (مبنية على PDFium، نفس محرك Chrome
//  لعرض PDF) خصيصاً لهذه المهمة.
//
//  مبدأ العمل:
//  1. نفتح الصفحة عبر pdfx ونقرأ page.width / page.height — هذه القيم
//     بوحدة "نقطة" (1/72 إنش)، وهي **نفس الوحدة** التي تستخدمها Syncfusion
//     في PdfPage.size عند الرسم لاحقاً. هذا التطابق ضروري: لو اختلفت
//     الوحدات بين مرحلة العرض ومرحلة الرسم النهائي، سينحرف موضع التوقيع.
//  2. نُرمِّز الصفحة كصورة (PNG) بدقة (resolution) أعلى من ضرورتها على
//     الشاشة (pixelRatio) للحفاظ على وضوح النص عند التكبير اللمسي.
//  3. نعرض هذه الصورة في Flutter بحجم منطقي (logical size) يساوي تماماً
//     page.width × page.height بالنقاط (بعد تحجيم بسيط للشاشة) — هذا يجعل
//     widget الصورة نفسه "نظام الإحداثيات الحقيقي" للصفحة، فأي موضع
//     يسحب المستخدم التوقيع إليه يُقاس كنسبة من حجم هذا الـ widget، وهذه
//     النسبة هي ما نضربه لاحقاً في pageWidth/pageHeight الحقيقيين عند
//     الرسم النهائي بـ Syncfusion. لا حاجة لأي تخمين أو معايرة يدوية.
//
//  ⚠️ قيد تقني من توثيق pdfx يجب الالتزام به دقيقاً: على أندرويد، يجب
//  إغلاق الصفحة الحالية (page.close()) قبل فتح صفحة جديدة من نفس الوثيقة،
//  وإلا قد يتعطل التطبيق. هذه الخدمة تضمن ذلك عبر try/finally في كل
//  استدعاء، ولا تُبقي أكثر من صفحة مفتوحة في نفس اللحظة.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:typed_data';
import 'package:pdfx/pdfx.dart' as pdfx;

/// نتيجة ترميز صفحة واحدة: الصورة + الأبعاد الحقيقية للصفحة بالنقاط
/// (نفس وحدة Syncfusion)، ضروريان معاً لحساب موضع التوقيع بدقة لاحقاً.
class RenderedPdfPage {
  final Uint8List imageBytes;

  /// عرض/ارتفاع الصفحة الحقيقيان بالنقاط (1/72 إنش) — هذه القيم تُمرَّر
  /// كما هي إلى Syncfusion عند رسم التوقيع النهائي، فلا يوجد أي تحويل وحدات
  /// وسيط قد يُدخل خطأ تراكمياً.
  final double pageWidthPt;
  final double pageHeightPt;

  const RenderedPdfPage({
    required this.imageBytes,
    required this.pageWidthPt,
    required this.pageHeightPt,
  });

  double get aspectRatio => pageWidthPt / pageHeightPt;
}

class PdfPageRenderService {
  /// يفتح المستند، يُرمِّز صفحة واحدة بالرقم المطلوب (1-indexed)، ثم يُغلق
  /// الصفحة والمستند فوراً. نفتح/نغلق المستند بالكامل في كل استدعاء بدل
  /// الاحتفاظ به مفتوحاً بين الاستدعاءات — أبسط وأكثر أماناً من إدارة دورة
  /// حياة مشتركة عبر الشاشة، بتكلفة أداء صغيرة مقبولة لأن المستخدم لا يبدّل
  /// الصفحات بسرعة عالية أثناء وضع توقيع واحد.
  ///
  /// [pixelRatio] يحدد دقة الصورة الناتجة نسبة لحجمها المنطقي بالنقاط
  /// (2.0 يعطي وضوحاً جيداً عند التكبير اللمسي دون صورة ضخمة غير ضرورية).
  Future<RenderedPdfPage> renderPage({
    required String filePath,
    required int pageNumber,
    double pixelRatio = 2.0,
  }) async {
    final document = await pdfx.PdfDocument.openFile(filePath);
    try {
      final page = await document.getPage(pageNumber);
      try {
        final image = await page.render(
          width: page.width * pixelRatio,
          height: page.height * pixelRatio,
          format: pdfx.PdfPageImageFormat.png,
          backgroundColor: '#FFFFFF',
        );
        if (image == null) {
          throw Exception('فشل ترميز الصفحة $pageNumber كصورة.');
        }
        return RenderedPdfPage(
          imageBytes: image.bytes,
          pageWidthPt: page.width,
          pageHeightPt: page.height,
        );
      } finally {
        // ⚠️ إلزامي حسب توثيق pdfx لأندرويد — انظر الشرح أعلى الملف.
        await page.close();
      }
    } finally {
      await document.close();
    }
  }

  /// عدد صفحات المستند، بمعزل عن أي ترميز — يُستخدَم لبناء أزرار
  /// التنقل بين الصفحات في شاشة الوضع دون فتح/ترميز كل الصفحات دفعة واحدة.
  Future<int> getPageCount(String filePath) async {
    final document = await pdfx.PdfDocument.openFile(filePath);
    try {
      return document.pagesCount;
    } finally {
      await document.close();
    }
  }
}
