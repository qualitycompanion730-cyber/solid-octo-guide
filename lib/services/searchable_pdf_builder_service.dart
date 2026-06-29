/// خدمة بناء "PDF قابل للبحث" (Searchable PDF) من نتيجة OCR.
///
/// مبدأ الـ Searchable PDF: كل صفحة تحتوي طبقتين متراكبتين تماماً:
///   1) صورة الصفحة الأصلية (الممسوحة) كاملة الحجم كخلفية — تُعرض
///      بصرياً للمستخدم كما هي 100%، بلا أي تغيير.
///   2) طبقة نص "شفافة" فوقها تماماً بنفس موقع كل كلمة (من صناديق
///      إحداثيات HOCR)، بحجم خط مطابق لحجم الكلمة في الصورة. القارئ
///      يستطيع نسخ النص أو البحث فيه بينما يرى الصورة الأصلية فقط.
///
/// هذه ميزة لا تتوفر في Text Fairy (يُصدّر نصاً منسّقاً من جديد بخط
/// مُعاد بناؤه، فيفقد المظهر الأصلي للوثيقة) — هنا المظهر الأصلي يبقى
/// 100% مطابقاً مع قابلية بحث/نسخ حقيقية فوقه.
///
/// ═══════════════════════ آلية التكامل مع محرك المشروع ═══════════════════════
/// هذه الخدمة تبني `PdfDocSpec` (نفس نموذج التخطيط المستخدَم في محوّلات
/// DOCX/XLSX/PPTX/HTML/TXT) وتمرّره مباشرة إلى `NativePdfBridge.renderDocument`
/// — لا يوجد أي مسار رسم خاص بـOCR في الجسر الأصلي (Kotlin)، فقط إضافتان
/// صغيرتان على النموذج العام الموجود مسبقاً:
///
///   1) `PdfPageSpec.backgroundImageBytes`: كان موجوداً في النموذج
///      والرسام (NativePdfRenderer.renderPrecomposedPage يستدعي
///      drawBitmapCover عليه فعلاً) لكنه كان معطَّلاً بقيمة null دائمة
///      في PdfSpecModels.kt (جهة Kotlin) — فعّلته في نفس الملف.
///   2) `PdfFontSpec.renderMode = 'invisible'`: إضافة جديدة بالكامل،
///      تُترجَم إلى عامل PDF القياسي `3 Tr` (Text Rendering Mode 3 —
///      "Invisible"، مواصفات PDF §9.3.3) في PdfContentBuilder.drawGlyphRun.
///      الاكتشاف الحاسم الذي يجعل هذا يكفي وحده لتفعيل البحث: محرك
///      المشروع يبني جدول `/ToUnicode` CMap كامل لكل خط مسجَّل
///      (PdfFontManager.buildType0Font) — وهذا يعني أن أي نص يُرسم
///      بهذا المحرك (مرئياً أو بـTr=3) قابل للبحث/النسخ تلقائياً عبر
///      أي قارئ PDF قياسي، بلا أي آلية "نص مخفي" خاصة إضافية.
///
/// كل كلمة OCR تُمرَّر كـ `PdfBlockParagraph` بتشغيلة واحدة (run) ضمن
/// `PdfAbsoluteOverlay` بموضع (x, y) مطلق يطابق صندوق إحداثيات الكلمة
/// (مُحوَّلاً من بكسل إلى نقاط حسب نسبة أبعاد الصورة لأبعاد صفحة PDF).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/ocr_result_model.dart';
import '../pdf_engine/native_pdf_bridge.dart';
import '../pdf_engine/pdf_layout_model.dart';

class SearchablePdfBuilderService {
  /// عائلة الخط المستخدَمة لطبقة النص الشفافة. لا تأثير بصري إطلاقاً
  /// (النص غير مرئي بـTr=3) لكنها تحدّد جدول glyph→Unicode الذي يُبنى
  /// من الخط الفعلي، فيجب أن تكون عائلة تحتوي تغطية جيدة لكل من العربية
  /// والإنجليزية معاً — NotoNaskhArabic (مسجَّلة بالفعل في كتالوج خطوط
  /// المشروع، انظر pubspec.yaml) تغطي كلا النطاقين.
  static const String _invisibleLayerFontFamily = 'NotoNaskhArabic';

  /// يبني ملف PDF قابل للبحث من نتيجة OCR لوثيقة كاملة (صورة واحدة أو
  /// عدة صفحات من PDF ممسوح)، ويُعيد بايتات PDF جاهزة للحفظ.
  static Future<Uint8List> buildPdfBytes(
    OcrDocumentResult document, {
    void Function(double progress, String stage)? onProgress,
  }) async {
    final pages = <PdfPageSpec>[];

    for (final page in document.pages) {
      final imageBytes = await File(page.sourceImagePath).readAsBytes();

      // أبعاد صفحة PDF بالنقاط: نستخدم نفس الأبعاد المنطقية لصفحة A4
      // القياسية بنسبة العرض/الارتفاع الفعلية للصورة الممسوحة، بدل قيمة
      // ثابتة قد تُشوّه الصورة. نُثبّت العرض عند عرض A4 (595.28pt) ونحسب
      // الارتفاع تبعاً لنسبة الصورة الأصلية، فتُحافَظ نسبة الأبعاد
      // الحقيقية للمستند الممسوح كاملةً.
      const pageWidthPt = 595.28;
      final aspect = page.imageWidthPx > 0 && page.imageHeightPx > 0
          ? page.imageHeightPx / page.imageWidthPx
          : 1.4142; // نسبة A4 الافتراضية كقيمة احتياطية أخيرة فقط
      final pageHeightPt = pageWidthPt * aspect;

      // عامل التحويل من بكسل الصورة إلى نقاط الصفحة — موحَّد لكل من
      // المحورين لأن خلفية الصورة تُرسم بنفس نسبة عرض/ارتفاع الصفحة
      // تماماً (drawBitmapCover يملأ كامل الصفحة)، فلا تشويه نسبي.
      final scaleXPtPerPx = pageWidthPt / page.imageWidthPx;
      final scaleYPtPerPx = pageHeightPt / page.imageHeightPx;

      final overlays = <PdfAbsoluteOverlay>[];
      for (final block in page.blocks) {
        for (final line in block.lines) {
          for (final word in line.words) {
            if (word.text.trim().isEmpty) continue;

            final xPt = word.boundingBox.left * scaleXPtPerPx;
            final yPt = word.boundingBox.top * scaleYPtPerPx;
            final hPt = word.boundingBox.height * scaleYPtPerPx;

            // حجم خط يطابق ارتفاع صندوق الكلمة تقريباً (نسبة 0.85 شائعة
            // بين ارتفاع صندوق Tesseract وارتفاع em الفعلي للخط، فتُحافَظ
            // محاذاة طبقة النص الشفافة على موقع الكلمة المرئية في الصورة
            // بدقة كافية لأغراض البحث/النسخ، لا لأغراض طباعة بصرية).
            final fontSizePt = (hPt * 0.85).clamp(4.0, 96.0);

            overlays.add(
              PdfAbsoluteOverlay(
                xPt: xPt,
                yPt: yPt,
                block: PdfBlockParagraph(
                  runs: [
                    PdfTextRun(
                      word.text,
                      PdfFontSpec(
                        family: _invisibleLayerFontFamily,
                        sizePt: fontSizePt,
                        renderMode: 'invisible',
                      ),
                    ),
                  ],
                  direction: line.direction == OcrTextDirection.rtl
                      ? PdfTextDirection.rtl
                      : PdfTextDirection.ltr,
                ),
              ),
            );
          }
        }
      }

      pages.add(PdfPageSpec(
        widthPt: pageWidthPt,
        heightPt: pageHeightPt,
        backgroundImageBytes: imageBytes,
        blocks: const [],
        overlayBlocks: overlays,
      ));
    }

    final spec = PdfDocSpec(pages: pages, isPrecomposed: true);

    try {
      return await NativePdfBridge.renderDocument(spec, onProgress: onProgress);
    } on NativePdfBridgeException catch (e) {
      throw SearchablePdfBuildException('فشل بناء PDF القابل للبحث: ${e.message}');
    }
  }

  /// يبني الملف ويحفظه في المجلد المؤقت، جاهزاً للتمرير إلى ResultScreen
  /// الموحَّدة (نفس نمط كل أدوات التحويل الأخرى في المشروع).
  static Future<File> buildAndSave(
    OcrDocumentResult document, {
    String? outputFileName,
    void Function(double progress, String stage)? onProgress,
  }) async {
    final bytes = await buildPdfBytes(document, onProgress: onProgress);

    final dir = await getTemporaryDirectory();
    final fileName = outputFileName ?? '${document.suggestedTitle}.pdf';
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }
}

class SearchablePdfBuildException implements Exception {
  final String message;
  const SearchablePdfBuildException(this.message);
  @override
  String toString() => message;
}
