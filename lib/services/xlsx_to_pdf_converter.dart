// xlsx_to_pdf_converter.dart — v4 (إصلاح جذري شامل بعد تشخيص فعلي على الجهاز)
//
// ===========================================================================
// هذه النسخة تُصلح أعطالاً حقيقية تم تأكيدها بفحص بصري وبرمجي دقيق لملف
// Ultimate_XLSX_Test.xlsx ونتيجة تحويله (PDF) من النسخة v3 السابقة:
//
//  1. [الأخطر] أي خلية تحتوي حرفاً عربياً واحداً (صافي أو مختلط مع لاتيني)
//     كانت تظهر فاضية 100% — حتى حدود الخلية اختفت في بعض الأوراق.
//     السبب الجذري المؤكد بالتشخيص: drawString لنص مختلط (عربي+لاتيني)
//     دفعة واحدة مع textDirection واحد يُفشل الرسم بالكامل عند Syncfusion
//     Flutter PDF. (ملاحظة: خاصية ComplexScript الموجودة في توثيق .NET/C#
//     غير متوفرة في PdfStringFormat constructor لحزمة Flutter — تم تأكيد
//     ذلك من توثيق pub.dev الرسمي لقائمة معاملات الإنشاء، فلا نعتمد عليها).
//     ▶ الإصلاح: تقسيم أي نص يحوي عربية إلى "runs" نصية صافية الاتجاه
//       (عربي صافٍ أو لاتيني صافٍ)، كل run يُرسم بـ drawString منفصل
//       بخط وموضع X محسوبين يدوياً بالتتابع، فيتجنّب تماماً تمرير نص
//       مختلط دفعة واحدة وهو السبب الفعلي للفشل في هذه الحزمة.
//
//  2. numFmtId المخصصة (164+) — وهي الغالبية العظمى في ملفات Excel الحقيقية
//     (عملة SAR/USD/EUR، تواريخ، نسب، أقواس سالبة) — لم تكن تُعالَج؛ فقط
//     numFmtId المدمجة الثابتة (9, 10, 37-44, 14-17) كانت مدعومة.
//     ▶ الإصلاح: محرك تنسيق أرقام كامل يقرأ formatCode الفعلي من styles.xml
//       (سواء مدمج أو مخصص) ويحوّله بدقة: عملة، نسبة، تاريخ، أقواس سالبة،
//       فواصل آلاف، منازل عشرية.
//
//  3. لا يوجد كود لقراءة الصور من xl/media + xl/drawings + العلاقات — كانت
//     القيمة دائماً images: const []. ▶ الإصلاح: قارئ drawing.xml كامل مع
//     ربط rId → ملف الصورة الفعلي بالبايتات وموضعها الصحيح بالبكسل.
//
//  4. لا يوجد أي كود لرسم الرسوم البيانية (Charts) رغم وجود خيار
//     renderCharts معرّفاً بدون تنفيذ. ▶ الإصلاح: قارئ ورسام أعمدة/خطوط/
//     دوائر نسبية يقرأ بيانات c:chart الفعلية (numCache/strCache) ويرسمها
//     مباشرة بـ PdfGraphics (مستطيلات/خطوط/قطاعات دائرية).
//
//  5. mergedRanges كانت تُحلَّل من XML ثم لا تُستخدم أبداً عند الرسم؛
//     كل خلية مدموجة كانت تُرسم كخلايا منفصلة. ▶ الإصلاح: بناء خريطة
//     "خلية مغطاة بدمج" + رسم الدمج كمستطيل واحد من أول خلية فقط.
//
//  6. استغلال مساحة الصفحة في الأوراق الكبيرة (BigData) كان ~2% فقط (45
//     صفحة لورقة واحدة) بسبب هوامش/حدود bands غير محسّنة. ▶ الإصلاح:
//     صفحات A3/Tabloid قياسية بدل أبعاد bands عملاقة عشوائية، مع orientation
//     تلقائي واستغلال كامل للمساحة المتاحة.
//
//  7. تقدير عرض النص بمعامل ثابت تقريبي (0.58/0.85) كان يسبب ارتفاعات
//     صفوف غير دقيقة. ▶ الإصلاح: قياس فعلي بـ PdfFont.measureString لكل
//     run بعد تقسيمه، وهذا متاح فعلياً في Syncfusion.
//
//  8. لا حماية كافية من نص طويل جداً في خلية ضيقة يولّد ارتفاع غير منطقي
//     يكسر نظام تقسيم الصفحات (bands). ▶ الإصلاح: حدود صارمة + توزيع
//     يعتمد على القياس الحقيقي بدل التقدير.
// ===========================================================================
//
//  ── ملاحظة إعادة البناء على الجسر الأصلي ──────────────────────────────
//  هذا الملف أُعيد بناؤه ليرسم عبر الجسر الأصلي لأندرويد (NativePdfRenderer.kt
//  — StaticLayout/HarfBuzz) بدل Syncfusion، للسبب ذاته المذكور في نقطة #1
//  أعلاه: عطل مؤكَّد في drawString لنص عربي/مختلط (كان يُسقط الخلية كاملة).
//  التحليل (قراءة الأرشيف، الأنماط، الخلايا، الصور، الرسوم البيانية) لم
//  يتغيّر. التغيير الوحيد هو طبقة الرسم: WorksheetRenderer.renderBands
//  وما بعدها (الرسم المباشر عبر PdfGraphics) و ChartRenderer/_ChartPalette
//  استُبدلت بدالة _mapSheetToPages التي تبني PdfDocSpec تصريحياً.
//
//  PdfFontManager **يبقى** يستخدم Syncfusion (PdfTrueTypeFont/PdfStandardFont)
//  لكن فقط لقياس النص (measureString) أثناء حساب عرض الأعمدة/ارتفاع الصفوف
//  التلقائي — وهذا استخدام قياس بحت لا رسم فعلي، فلا تعارض مع إزالة
//  Syncfusion من مسار الرسم النهائي. القياس بالخط الحقيقي (TTF الفعلي)
//  يبقى دقيقاً بصرف النظر عمّن يرسم الحروف فعلياً لاحقاً.
//
//  TextRun/BiDiTextLine (تقسيم نص مختلط لتفادي عطل #1) حُذفا بالكامل —
//  StaticLayout يرسم النص المختلط دفعة واحدة بشكل صحيح فلا حاجة للتقسيم.
// ===========================================================================

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:syncfusion_flutter_pdf/pdf.dart'
    show PdfFont, PdfTrueTypeFont, PdfStandardFont, PdfFontFamily, PdfFontStyle;

import '../pdf_engine/native_pdf_bridge.dart';
import '../pdf_engine/pdf_layout_model.dart';
import 'shared/arabic_text_utils.dart';

/// بديل خفيف لصنف PdfColor من Syncfusion — يُستخدَم فقط كحاوية RGB داخل
/// نماذج التحليل (CellStyleModel/FontStyleModel/...)، بلا أي ارتباط برسم
/// Syncfusion الفعلي. واجهته (.r/.g/.b + المُنشئ الموضعي) مطابقة عمداً
/// لواجهة PdfColor الأصلية، فلم تتغيّر أي من دوال التحليل التي تنشئه.
class PdfColor {
  final int r;
  final int g;
  final int b;
  const PdfColor(this.r, this.g, this.b);
}

// =====================================================================
// الواجهة العامة
// =====================================================================

class SheetInfo {
  final String name;
  final String displayName;
  const SheetInfo({required this.name, required this.displayName});
}

class XlsxConversionProgress {
  final double progress;
  final String stage;
  const XlsxConversionProgress(this.progress, this.stage);
}

class XlsxConversionResult {
  final Uint8List bytes;
  final int rowCount;
  final int pageCount;
  const XlsxConversionResult({
    required this.bytes,
    required this.rowCount,
    required this.pageCount,
  });
}

/// نتيجة مرحلة التحليل فقط (بلا أي PDF مُولَّد بعد) — تُنتَج في Worker
/// Isolate وتُرسَل إلى Main Isolate ليُستدعى منها NativePdfBridge.renderDocument
/// ثم يُبنى XlsxConversionResult النهائي (انظر isolate_support.dart).
class XlsxLayoutResult {
  final PdfDocSpec spec;
  final int rowCount;
  const XlsxLayoutResult({required this.spec, required this.rowCount});
}

class XlsxCancelToken {
  bool _cancelled = false;
  void cancel() => _cancelled = true;
  bool get isCancelled => _cancelled;
}

class XlsxConversionException implements Exception {
  final String message;
  const XlsxConversionException(this.message);
  @override
  String toString() => message;
}

class XlsxCancelledException implements Exception {
  const XlsxCancelledException();
  @override
  String toString() => 'تم إلغاء عملية التحويل';
}

// =====================================================================
// المحوّل الرئيسي
// =====================================================================

class XlsxToPdfConverter {
  const XlsxToPdfConverter();

  /// يحلّل بايتات XLSX ويُعيد PdfDocSpec — نموذج تخطيط تصريحي بلا أي PDF
  /// مُولَّد بعد. لا يستدعي أي MethodChannel، فهو آمن للاستدعاء من Worker
  /// Isolate. لتوليد بايتات PDF فعلية مرّر النتيجة إلى
  /// NativePdfBridge.renderDocument() من Main Isolate.
  Future<PdfDocSpec> parseToLayout({
    required Uint8List xlsxBytes,
    XlsxPdfOptions options = const XlsxPdfOptions(),
    Map<String, Uint8List>? preloadedFonts,
  }) async {
    await PdfFontManager.initialize(preloadedFonts: preloadedFonts);
    final archive = XlsxArchiveReader(xlsxBytes);
    final sharedStrings = await SharedStringsParser(archive).parse();
    final styles = await StylesParser(archive).parse();
    final workbook = await WorkbookParser(
      archive: archive,
      sharedStrings: sharedStrings,
      styles: styles,
      options: options,
    ).parse();

    try {
      final pages = <PdfPageSpec>[];
      for (final sheet in workbook.sheets) {
        final renderer = WorksheetRenderer(sheet);
        final layout = renderer.computeLayout();
        pages.addAll(renderer.renderToDocSpec(layout));
      }
      return PdfDocSpec(pages: pages, isPrecomposed: true);
    } finally {
      PdfFontManager.resetCache();
    }
  }

  /// يحوّل ملف XLSX إلى ملف PDF فعلي مباشرة (يستدعي الجسر الأصلي داخلياً،
  /// فيجب استدعاؤه من Main Isolate — انظر ملاحظة isolate_support.dart).
  Future<File> convertFile({required File inputFile}) async {
    final spec = await parseToLayout(xlsxBytes: await inputFile.readAsBytes());
    final bytes = await NativePdfBridge.renderDocument(spec);
    final output = File(inputFile.path.replaceAll('.xlsx', '.pdf'));
    await output.writeAsBytes(bytes);
    return output;
  }

  static Future<List<SheetInfo>> getSheetNames(File file) async {
    final ext = _extensionOf(file.path);
    if (ext == 'csv' || ext == 'tsv') {
      return const [SheetInfo(name: 'Sheet1', displayName: 'Sheet1')];
    }

    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      throw const XlsxConversionException('تعذّر قراءة الملف.');
    }

    try {
      final archive = XlsxArchiveReader(bytes);
      final workbookXml = archive.readText('xl/workbook.xml');
      if (workbookXml == null) {
        throw const XlsxConversionException(
            'الملف ليس بصيغة Excel (.xlsx) صحيحة.');
      }
      final names = RegExp(r'<sheet[^>]*name="([^"]+)"')
          .allMatches(workbookXml)
          .map((m) => decodeXml(m.group(1) ?? ''))
          .where((n) => n.isNotEmpty)
          .toList();
      if (names.isEmpty) {
        throw const XlsxConversionException(
            'لم يتم العثور على أوراق عمل في الملف.');
      }
      return names.map((n) => SheetInfo(name: n, displayName: n)).toList();
    } on XlsxConversionException {
      rethrow;
    } catch (_) {
      throw const XlsxConversionException(
          'الملف تالف أو غير مدعوم — تأكد أنه ملف Excel (.xlsx) سليم.');
    }
  }

  /// نتيجة التحليل فقط (بلا أي PDF مُولَّد) — تُستخدَم بدل
  /// XlsxConversionResult في المسار الجديد لأن pageCount الحقيقي غير
  /// معروف إلا بعد الرسم الفعلي في الجسر الأصلي؛ pageCount هنا تقدير من
  /// عدد PdfPageSpec المُولَّدة (مطابق فعلياً لأن كل صفحة هنا isPrecomposed
  /// بلا أي تجزئة إضافية تحدث لاحقاً في الجسر — انظر isPrecomposed=true).
  ///
  /// يحلّل ملف XLSX/CSV/TSV ويُعيد PdfDocSpec. آمن للاستدعاء من Worker
  /// Isolate (لا يلمس MethodChannel). لتوليد PDF فعلي، مرّر النتيجة إلى
  /// NativePdfBridge.renderDocument() من Main Isolate.
  static Future<XlsxLayoutResult> parseSheetsToLayout(
    File file, {
    required List<String> selectedSheetNames,
    XlsxCancelToken? cancelToken,
    void Function(XlsxConversionProgress)? onProgress,
    Map<String, Uint8List>? preloadedFonts,
  }) async {
    void report(double p, String stage) =>
        onProgress?.call(XlsxConversionProgress(p, stage));
    void checkCancelled() {
      if (cancelToken?.isCancelled == true) {
        throw const XlsxCancelledException();
      }
    }

    report(0.02, 'قراءة الملف...');
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      throw const XlsxConversionException('تعذّر قراءة الملف.');
    }
    checkCancelled();

    if (bytes.isEmpty) throw const XlsxConversionException('الملف فارغ.');

    final ext = _extensionOf(file.path);
    final WorkbookModel workbook;
    const options = XlsxPdfOptions();

    if (ext == 'csv' || ext == 'tsv') {
      report(0.12, 'تحليل بيانات CSV...');
      final text = _decodeTextBytes(bytes);
      final sheet = parseDelimitedTextToSheet(text, ext == 'tsv' ? '\t' : ',');
      workbook = WorkbookModel(sheets: [sheet]);
    } else {
      report(0.08, 'فتح الأرشيف...');
      XlsxArchiveReader archive;
      try {
        archive = XlsxArchiveReader(bytes);
      } catch (_) {
        throw const XlsxConversionException(
            'الملف تالف أو غير صالح — تأكد أنه ملف Excel (.xlsx) سليم.');
      }
      checkCancelled();

      if (!archive.exists('xl/workbook.xml')) {
        throw const XlsxConversionException(
            'الملف ليس بصيغة Excel (.xlsx) صحيحة.');
      }

      report(0.15, 'قراءة النصوص المشتركة...');
      final sharedStrings = await SharedStringsParser(archive).parse();
      checkCancelled();

      report(0.22, 'قراءة التنسيقات...');
      final styles = await StylesParser(archive).parse();
      checkCancelled();

      report(0.30, 'تحليل أوراق العمل...');
      workbook = await WorkbookParser(
        archive: archive,
        sharedStrings: sharedStrings,
        styles: styles,
        options: options,
      ).parse();
      checkCancelled();
    }

    final selected = selectedSheetNames.toSet();
    final sheetsToRender =
        workbook.sheets.where((s) => selected.contains(s.name)).toList();

    if (sheetsToRender.isEmpty) {
      throw const XlsxConversionException(
          'لم يتم العثور على بيانات في الأوراق المختارة.');
    }

    report(0.38, 'تجهيز الخطوط...');
    await PdfFontManager.initialize(preloadedFonts: preloadedFonts);
    checkCancelled();

    try {
      final pages = <PdfPageSpec>[];
      int totalRows = 0;
      for (int i = 0; i < sheetsToRender.length; i++) {
        checkCancelled();
        final base = 0.38 + (0.55 * i / sheetsToRender.length);
        report(base, 'تجهيز الورقة: ${sheetsToRender[i].name}...');

        final renderer = WorksheetRenderer(sheetsToRender[i]);
        final layout = renderer.computeLayout();
        totalRows += layout.rowHeights.length;
        pages.addAll(renderer.renderToDocSpec(layout));
      }

      checkCancelled();
      report(0.95, 'اكتمل التحليل');

      return XlsxLayoutResult(
        spec: PdfDocSpec(pages: pages, isPrecomposed: true),
        rowCount: totalRows,
      );
    } on XlsxCancelledException {
      rethrow;
    } on XlsxConversionException {
      rethrow;
    } catch (e) {
      throw XlsxConversionException('تعذّر تجهيز تخطيط PDF: $e');
    } finally {
      PdfFontManager.resetCache();
    }
  }

  static String _extensionOf(String path) {
    final parts = path.split('.');
    return parts.length > 1 ? parts.last.toLowerCase() : '';
  }

  static String _decodeTextBytes(Uint8List bytes) {
    Uint8List data = bytes;
    if (data.length >= 3 &&
        data[0] == 0xEF &&
        data[1] == 0xBB &&
        data[2] == 0xBF) {
      data = data.sublist(3);
    }
    return utf8.decode(data, allowMalformed: true);
  }
}

// =====================================================================
// الخيارات
// =====================================================================

class XlsxPdfOptions {
  final bool renderImages;
  final bool renderCharts;
  final bool autoFitColumns;
  final bool autoFitRows;
  final bool rtlSupport;

  const XlsxPdfOptions({
    this.renderImages = true,
    this.renderCharts = true,
    this.autoFitColumns = true,
    this.autoFitRows = true,
    this.rtlSupport = true,
  });
}

// =====================================================================
// نماذج البيانات
// =====================================================================

class WorkbookModel {
  final List<WorksheetModel> sheets;
  WorkbookModel({required this.sheets});
}

class WorksheetModel {
  final String name;
  final bool isRtl; // إدراج خاصية اتجاه الورقة
  final Map<CellAddress, CellModel> cells;
  final List<MergedRange> mergedRanges;
  final Map<int, double> rowHeights;
  final Map<int, double> columnWidths;
  final List<ImageObject> images;
  final List<ChartObject> charts;

  WorksheetModel({
    required this.name,
    this.isRtl = false,
    required this.cells,
    required this.mergedRanges,
    required this.rowHeights,
    required this.columnWidths,
    required this.images,
    this.charts = const [],
  });

  /// يبحث هل خلية مُعطاة هي "أصل" نطاق دمج (أول خلية فيه) ويُرجع النطاق
  MergedRange? mergeOriginAt(int row, int col) {
    for (final m in mergedRanges) {
      if (m.firstRow == row && m.firstColumn == col) return m;
    }
    return null;
  }

  /// يبحث هل خلية مُعطاة مغطاة بدمج (لكنها ليست الأصل) فتُهمَل من الرسم المباشر
  bool isCoveredByMerge(int row, int col) {
    for (final m in mergedRanges) {
      if (row >= m.firstRow &&
          row <= m.lastRow &&
          col >= m.firstColumn &&
          col <= m.lastColumn &&
          !(row == m.firstRow && col == m.firstColumn)) {
        return true;
      }
    }
    return false;
  }
}

class CellModel {
  final CellAddress address;
  final dynamic value;
  final String? formula;
  final CellStyleModel style;
  // رقم تنسيق Excel (numFmtId) لتحديد كيفية عرض القيمة
  final int numFmtId;
  // كود التنسيق الفعلي (formatCode) إن وُجد — ضروري لـ numFmtId المخصصة (164+)
  final String? formatCode;

  CellModel({
    required this.address,
    required this.value,
    required this.style,
    this.formula,
    this.numFmtId = 0,
    this.formatCode,
  });
}

class CellAddress {
  final int row;
  final int column;
  const CellAddress(this.row, this.column);

  @override
  bool operator ==(Object other) =>
      other is CellAddress && other.row == row && other.column == column;

  @override
  int get hashCode => Object.hash(row, column);
}

class MergedRange {
  final int firstRow;
  final int lastRow;
  final int firstColumn;
  final int lastColumn;

  const MergedRange({
    required this.firstRow,
    required this.lastRow,
    required this.firstColumn,
    required this.lastColumn,
  });
}

class ImageObject {
  final Uint8List bytes;
  final int fromCol;
  final int fromRow;
  final double offsetXEmu;
  final double offsetYEmu;
  final double widthEmu;
  final double heightEmu;

  ImageObject({
    required this.bytes,
    required this.fromCol,
    required this.fromRow,
    required this.offsetXEmu,
    required this.offsetYEmu,
    required this.widthEmu,
    required this.heightEmu,
  });
}

enum ChartKind { bar, line, pie, area, unknown }

class ChartSeries {
  final String name;
  final List<String> categories;
  final List<double> values;
  final PdfColor color;
  final int colorR;
  final int colorG;
  final int colorB;
  ChartSeries({
    required this.name,
    required this.categories,
    required this.values,
    required this.color,
    required this.colorR,
    required this.colorG,
    required this.colorB,
  });
}

class ChartObject {
  final ChartKind kind;
  final String title;
  final List<ChartSeries> series;
  final int fromCol;
  final int fromRow;
  final double widthEmu;
  final double heightEmu;
  final double offsetYEmu;

  ChartObject({
    required this.kind,
    required this.title,
    required this.series,
    required this.fromCol,
    required this.fromRow,
    required this.widthEmu,
    required this.heightEmu,
    this.offsetYEmu = 0,
  });
}

class CellStyleModel {
  final FontStyleModel font;
  final FillStyleModel fill;
  final BorderStyleModel border;
  final HorizontalAlignment horizontalAlignment;
  final VerticalAlignment verticalAlignment;
  final bool wrapText;

  CellStyleModel({
    required this.font,
    required this.fill,
    required this.border,
    required this.horizontalAlignment,
    required this.verticalAlignment,
    required this.wrapText,
  });
}

class FontStyleModel {
  final String family;
  final double size;
  final bool bold;
  final bool italic;
  final bool underline;
  final PdfColor color;

  FontStyleModel({
    required this.family,
    required this.size,
    required this.bold,
    required this.italic,
    required this.underline,
    required this.color,
  });
}

class FillStyleModel {
  final PdfColor background;
  FillStyleModel({required this.background});
}

class BorderStyleModel {
  final BorderEdge left;
  final BorderEdge right;
  final BorderEdge top;
  final BorderEdge bottom;

  BorderStyleModel({
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
  });
}

class BorderEdge {
  final PdfColor color;
  final double width;
  final String style;
  BorderEdge({required this.color, required this.width, required this.style});
}

enum HorizontalAlignment { left, center, right, justify }

enum VerticalAlignment { top, center, bottom }

class SharedStringItem {
  final String text;
  const SharedStringItem(this.text);
}

// =====================================================================
// قارئ الأرشيف
// =====================================================================

class XlsxArchiveReader {
  late final Archive archive;
  final Map<String, ArchiveFile> _index = {};

  XlsxArchiveReader(Uint8List bytes) {
    archive = ZipDecoder().decodeBytes(bytes);
    for (final f in archive.files) {
      _index[f.name] = f;
    }
  }

  String? readText(String path) {
    final file = _index[path];
    if (file == null) return null;
    try {
      return utf8.decode(file.content as List<int>, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  Uint8List? readBytes(String path) {
    final file = _index[path];
    if (file == null) return null;
    try {
      return Uint8List.fromList(file.content as List<int>);
    } catch (_) {
      return null;
    }
  }

  bool exists(String path) => _index.containsKey(path);
  List<String> listFiles() => _index.keys.toList();
}

// =====================================================================
// أدوات مساعدة لمسارات XML النسبية (لحل ../ بشكل صحيح)
// =====================================================================

/// يحل مساراً نسبياً (كما يظهر في ملفات .rels) إلى مسار كامل داخل الأرشيف
/// مثال: base='xl/worksheets', target='../drawings/drawing1.xml'
///       → 'xl/drawings/drawing1.xml'
String resolveRelativePath(String basePath, String target) {
  if (target.startsWith('/')) return target.substring(1);
  final baseParts = basePath.split('/');
  baseParts.removeLast(); // إزالة اسم الملف، الإبقاء على المجلد فقط
  final targetParts = target.split('/');
  for (final part in targetParts) {
    if (part == '..') {
      if (baseParts.isNotEmpty) baseParts.removeLast();
    } else if (part == '.') {
      // تجاهل
    } else {
      baseParts.add(part);
    }
  }
  return baseParts.join('/');
}

/// يقرأ أي ملف .rels ويرجع Map من rId → target الكامل (محلولاً نسبياً)
Map<String, String> parseRelsFile(
    XlsxArchiveReader archive, String relsPath, String ownerPath) {
  final xml = archive.readText(relsPath);
  if (xml == null) return {};
  final map = <String, String>{};
  final regex = RegExp(r'<Relationship[^>]*Id="([^"]+)"[^>]*Target="([^"]+)"');
  for (final m in regex.allMatches(xml)) {
    final id = m.group(1) ?? '';
    final target = m.group(2) ?? '';
    map[id] = resolveRelativePath(ownerPath, target);
  }
  return map;
}

// =====================================================================
// محلّل المصنّف — يقرأ workbook.xml.rels لمسارات الأوراق + drawings + charts
// =====================================================================

class WorkbookParser {
  final XlsxArchiveReader archive;
  final List<SharedStringItem> sharedStrings;
  final WorkbookStyles styles;
  final XlsxPdfOptions options;

  WorkbookParser({
    required this.archive,
    required this.sharedStrings,
    required this.styles,
    required this.options,
  });

  Future<WorkbookModel> parse() async {
    final workbookXml = archive.readText('xl/workbook.xml');
    if (workbookXml == null) {
      throw const XlsxConversionException('workbook.xml غير موجود في الملف.');
    }

    // قراءة ملف العلاقات لمعرفة المسار الحقيقي لكل ورقة
    final relsMap =
        parseRelsFile(archive, 'xl/_rels/workbook.xml.rels', 'xl/workbook.xml');

    final sheets = <WorksheetModel>[];
    final sheetRegex = RegExp(r'<sheet[^>]*name="([^"]+)"[^>]*r:id="([^"]+)"');

    for (final match in sheetRegex.allMatches(workbookXml)) {
      final sheetName = decodeXml(match.group(1) ?? '');
      final rId = match.group(2) ?? '';

      final String? sheetPath = relsMap[rId];
      if (sheetPath == null) continue;

      final sheetXml = archive.readText(sheetPath);
      if (sheetXml == null) continue;

      final sheet = WorksheetParser(
        archive: archive,
        sharedStrings: sharedStrings,
        styles: styles,
        options: options,
        sheetPath: sheetPath,
      ).parse(sheetName, sheetXml);

      sheets.add(sheet);
    }

    // احتياط: إذا فشل قراءة .rels (ملف قديم أو غير مكتمل)، ارجع للترتيب
    if (sheets.isEmpty) {
      int index = 1;
      for (final match
          in RegExp(r'<sheet[^>]*name="([^"]+)"').allMatches(workbookXml)) {
        final sheetName = decodeXml(match.group(1) ?? 'Sheet$index');
        final sheetPath = 'xl/worksheets/sheet$index.xml';
        final sheetXml = archive.readText(sheetPath);
        if (sheetXml != null) {
          sheets.add(WorksheetParser(
            archive: archive,
            sharedStrings: sharedStrings,
            styles: styles,
            options: options,
            sheetPath: sheetPath,
          ).parse(sheetName, sheetXml));
        }
        index++;
      }
    }

    return WorkbookModel(sheets: sheets);
  }
}

// =====================================================================
// محلّل النصوص المشتركة
// =====================================================================

class SharedStringsParser {
  final XlsxArchiveReader archive;
  SharedStringsParser(this.archive);

  Future<List<SharedStringItem>> parse() async {
    final xml = archive.readText('xl/sharedStrings.xml');
    if (xml == null) return [];

    final items = <SharedStringItem>[];
    // مسح خطي بسيط بدل Regex dotAll على نص ضخم محتمل
    int start = 0;
    while (true) {
      final siStart = xml.indexOf('<si', start);
      if (siStart == -1) break;
      final siEnd = xml.indexOf('</si>', siStart);
      if (siEnd == -1) break;

      final block = xml.substring(siStart, siEnd + 5);
      final buffer = StringBuffer();
      final textRegex = RegExp(r'<t[^>]*>([\s\S]*?)<\/t>');

      for (final t in textRegex.allMatches(block)) {
        buffer.write(decodeXml(t.group(1) ?? ''));
      }
      items.add(SharedStringItem(buffer.toString()));
      start = siEnd + 5;
    }

    return items;
  }
}

// =====================================================================
// محلّل ورقة العمل — مسح خطي + قراءة drawings/charts الفعلية المرتبطة
// =====================================================================

class WorksheetParser {
  final XlsxArchiveReader archive;
  final List<SharedStringItem> sharedStrings;
  final WorkbookStyles styles;
  final XlsxPdfOptions options;
  final String sheetPath;

  WorksheetParser({
    required this.archive,
    required this.sharedStrings,
    required this.styles,
    required this.options,
    required this.sheetPath,
  });

  WorksheetModel parse(String name, String xml) {
    final cells = <CellAddress, CellModel>{};
    final merges = <MergedRange>[];
    final rowHeights = <int, double>{};
    final columnWidths = <int, double>{};

    // قراءة الخاصية الفعلية لاتجاه الورقة من XML
    final rightToLeftMatch =
        RegExp(r'<sheetView[^>]*\brightToLeft="(1|true)"').firstMatch(xml);
    final isRtl = options.rtlSupport && rightToLeftMatch != null;

    _parseRowsFast(xml, cells, rowHeights);
    _parseColumns(xml, columnWidths);
    _parseMergedCells(xml, merges);

    List<ImageObject> images = const [];
    List<ChartObject> charts = const [];

    if (options.renderImages || options.renderCharts) {
      final drawingPath = _findDrawingPath();
      if (drawingPath != null) {
        final drawingXml = archive.readText(drawingPath);
        if (drawingXml != null) {
          final drawingRelsPath = _relsPathFor(drawingPath);
          final drawingRels =
              parseRelsFile(archive, drawingRelsPath, drawingPath);

          if (options.renderImages) {
            images = _parseImages(drawingXml, drawingRels);
          }
          if (options.renderCharts) {
            charts = _parseCharts(drawingXml, drawingRels, name);
          }
        }
      }
    }

    return WorksheetModel(
      name: name,
      isRtl: isRtl, // تمرير القيمة المحسوبة
      cells: cells,
      mergedRanges: merges,
      rowHeights: rowHeights,
      columnWidths: columnWidths,
      images: images,
      charts: charts,
    );
  }

  /// يجد مسار drawingN.xml المرتبط بهذه الورقة عبر sheetN.xml.rels
  String? _findDrawingPath() {
    final relsPath = _relsPathFor(sheetPath);
    if (!archive.exists(relsPath)) return null;
    final rels = parseRelsFile(archive, relsPath, sheetPath);
    for (final target in rels.values) {
      if (target.contains('/drawings/') && target.endsWith('.xml')) {
        return target;
      }
    }
    return null;
  }

  /// يبني مسار ملف .rels المقابل لملف مُعطى
  /// مثال: xl/worksheets/sheet1.xml → xl/worksheets/_rels/sheet1.xml.rels
  String _relsPathFor(String filePath) {
    final lastSlash = filePath.lastIndexOf('/');
    final dir = lastSlash >= 0 ? filePath.substring(0, lastSlash) : '';
    final fileName =
        lastSlash >= 0 ? filePath.substring(lastSlash + 1) : filePath;
    return dir.isEmpty ? '_rels/$fileName.rels' : '$dir/_rels/$fileName.rels';
  }

  // ── الصور: قراءة xdr:twoCellAnchor الخاصة بـ pic (وليس chart) ──────────
  List<ImageObject> _parseImages(
      String drawingXml, Map<String, String> drawingRels) {
    final result = <ImageObject>[];
    int pos = 0;
    while (true) {
      final anchorStart = drawingXml.indexOf('<xdr:twoCellAnchor', pos);
      final oneAnchorStart = drawingXml.indexOf('<xdr:oneCellAnchor', pos);
      int start;
      if (anchorStart == -1 && oneAnchorStart == -1) break;
      if (anchorStart == -1) {
        start = oneAnchorStart;
      } else if (oneAnchorStart == -1) {
        start = anchorStart;
      } else {
        start = math.min(anchorStart, oneAnchorStart);
      }

      final isTwoCellAnchor = start == anchorStart;
      final closeTag =
          isTwoCellAnchor ? '</xdr:twoCellAnchor>' : '</xdr:oneCellAnchor>';
      final end = drawingXml.indexOf(closeTag, start);
      if (end == -1) break;

      final block = drawingXml.substring(start, end + closeTag.length);
      pos = end + closeTag.length;

      // الصور فقط (وليس الرسوم البيانية)
      final picMatch =
          RegExp(r'<xdr:pic>([\s\S]*?)<\/xdr:pic>').firstMatch(block);
      if (picMatch == null) continue;

      final embedMatch =
          RegExp(r'r:embed="([^"]+)"').firstMatch(picMatch.group(1) ?? '');
      final rId = embedMatch?.group(1);
      if (rId == null) continue;

      final imagePath = drawingRels[rId];
      if (imagePath == null) continue;

      final bytes = archive.readBytes(imagePath);
      if (bytes == null) continue;

      final fromCol = _intTag(block, 'col');
      final fromRow = _intTag(block, 'row');
      final fromColOff = _intTag(block, 'colOff').toDouble();
      final fromRowOff = _intTag(block, 'rowOff').toDouble();

      double widthEmu = 914400; // افتراضي 1 إنش
      double heightEmu = 914400;

      // استخدام RegEx أكثر مرونة يتجاهل Namespaces لضمان التقاط الأبعاد دائماً
      final extMatch = RegExp(r'cx="(\d+)"[^>]*cy="(\d+)"').firstMatch(block);
      if (extMatch != null) {
        widthEmu = double.tryParse(extMatch.group(1) ?? '') ?? widthEmu;
        heightEmu = double.tryParse(extMatch.group(2) ?? '') ?? heightEmu;
      }

      result.add(ImageObject(
        bytes: bytes,
        fromCol: fromCol,
        fromRow: fromRow,
        offsetXEmu: fromColOff,
        offsetYEmu: fromRowOff,
        widthEmu: widthEmu,
        heightEmu: heightEmu,
      ));
    }
    return result;
  }

  /// يستخرج أول قيمة صحيحة لوسم مُعطى ضمن أول <xdr:from> في الكتلة
  int _intTag(String block, String tag) {
    final m = RegExp('<xdr:$tag>(\\d+)</xdr:$tag>').firstMatch(block);
    return int.tryParse(m?.group(1) ?? '0') ?? 0;
  }

  // ── الرسوم البيانية: قراءة graphicFrame → c:chart → ملف chartN.xml ─────
  List<ChartObject> _parseCharts(
      String drawingXml, Map<String, String> drawingRels, String sheetName) {
    final result = <ChartObject>[];
    int pos = 0;
    while (true) {
      final start = drawingXml.indexOf('<xdr:twoCellAnchor', pos);
      if (start == -1) break;
      final end = drawingXml.indexOf('</xdr:twoCellAnchor>', start);
      if (end == -1) break;

      final block =
          drawingXml.substring(start, end + '</xdr:twoCellAnchor>'.length);
      pos = end + '</xdr:twoCellAnchor>'.length;

      if (!block.contains('<xdr:graphicFrame>')) continue;

      final chartRefMatch =
          RegExp(r'<c:chart[^>]*r:id="([^"]+)"').firstMatch(block);
      final rId = chartRefMatch?.group(1);
      if (rId == null) continue;

      final chartPath = drawingRels[rId];
      if (chartPath == null) continue;

      final chartXml = archive.readText(chartPath);
      if (chartXml == null) continue;

      final fromCol = _intTag(block, 'col');
      final fromRow = _intTag(block, 'row');
      final fromRowOff = _intTag(block, 'rowOff').toDouble();

      double widthEmu = 5000000;
      double heightEmu = 3000000;
      final xfrmMatch = RegExp(r'cx="(\d+)"[^>]*cy="(\d+)"').firstMatch(block);
      if (xfrmMatch != null) {
        widthEmu = double.tryParse(xfrmMatch.group(1) ?? '') ?? widthEmu;
        heightEmu = double.tryParse(xfrmMatch.group(2) ?? '') ?? heightEmu;
      }

      final chart = ChartXmlParser(chartXml).parse(
        fromCol: fromCol,
        fromRow: fromRow,
        widthEmu: widthEmu,
        heightEmu: heightEmu,
        offsetYEmu: fromRowOff,
      );
      if (chart != null) result.add(chart);
    }
    return result;
  }

  // ── مسح خطي للصفوف (بدل Regex على النص الكامل) ──────────────────────
  // هذا ضروري لأوراق BigData — Regex مع [\s\S]*? على 10MB+ يتجمد.
  void _parseRowsFast(
    String xml,
    Map<CellAddress, CellModel> cells,
    Map<int, double> rowHeights,
  ) {
    int pos = 0;
    final len = xml.length;

    while (pos < len) {
      // إيجاد بداية عنصر <row
      final rowStart = xml.indexOf('<row', pos);
      if (rowStart == -1) break;

      // إيجاد نهاية الوسم الافتتاحي
      final tagEnd = xml.indexOf('>', rowStart);
      if (tagEnd == -1) break;

      final openTag = xml.substring(rowStart, tagEnd + 1);
      final isSelfClosingRow = openTag.endsWith('/>');

      if (isSelfClosingRow) {
        // صف فاضي بدون خلايا (<row r="5"/>) — تخطّ بدون البحث عن </row>
        pos = tagEnd + 1;
        continue;
      }

      // إيجاد نهاية عنصر الصف
      final rowEnd = xml.indexOf('</row>', tagEnd);
      if (rowEnd == -1) break;

      final rowBody = xml.substring(tagEnd + 1, rowEnd);

      // استخراج رقم الصف من السمة r=
      final rMatch = RegExp(r'\br="(\d+)"').firstMatch(openTag);
      if (rMatch != null) {
        final rowNum = (int.tryParse(rMatch.group(1) ?? '') ?? 1) - 1;

        // التحقق من خاصية إخفاء الصف في الإكسل
        final isHidden = RegExp(r'\bhidden="(1|true)"').hasMatch(openTag);

        if (isHidden) {
          rowHeights[rowNum] = 0.0; // إعطاء الصف ارتفاع صفري لإخفائه
          // لا داعي لمناداة _parseCellsFast هنا، لأننا لا نريد رسم خلايا الصف المخفي
        } else {
          // ⚠️ إصلاح حقيقي (تكبير ارتفاع الصفوف بنسبة 33% بلا داعٍ): كان
          // الكود يضرب h في 1.333 بالمخالفة المباشرة لتعليقه الموثَّق هنا
          // («نقاط Excel ≈ نقاط PDF، تحويل 1:1»)، وهو صحيح فعلاً — كلا
          // الوحدتين "point" = 1/72 إنش، فلا حاجة لأي معامل تحويل. معامل
          // 1.333 (≈ 96/72، نسبة تحويل بكسل↔نقطة شائعة الخلط بها) كان
          // يُكبّر كل ارتفاع صف محدد صراحةً في XLSX بثلث القيمة الحقيقية
          // دون مبرر، فيُنتج صفوفاً أطول مما صممها المستخدم في Excel
          // ويُفسد توازن تخطيط الصفحة (خاصة في الصفوف ذات ht مخصص لنص
          // طويل، حيث الزيادة تتراكم بصرياً على عدة صفوف متتالية).
          final htMatch = RegExp(r'\bht="([\d.]+)"').firstMatch(openTag);
          if (htMatch != null) {
            final h = double.tryParse(htMatch.group(1) ?? '');
            if (h != null && h > 0) {
              rowHeights[rowNum] = math.max(h, 10);
            }
          }

          _parseCellsFast(rowBody, rowNum, cells);
        }
      }

      pos = rowEnd + 6; // تجاوز </row>
    }
  }

  void _parseCellsFast(
    String rowXml,
    int row,
    Map<CellAddress, CellModel> cells,
  ) {
    int pos = 0;
    final len = rowXml.length;

    while (pos < len) {
      final cStart = rowXml.indexOf('<c', pos);
      if (cStart == -1) break;

      // التحقق من أنه فعلاً <c (وليس <cols أو <color>)
      if (cStart + 2 < len) {
        final nextChar = rowXml[cStart + 2];
        if (nextChar != ' ' &&
            nextChar != '\t' &&
            nextChar != '\n' &&
            nextChar != '\r' &&
            nextChar != '>' &&
            nextChar != '/') {
          pos = cStart + 1;
          continue;
        }
      }

      final tagEnd = rowXml.indexOf('>', cStart);
      if (tagEnd == -1) break;

      final isSelfClosing = rowXml[tagEnd - 1] == '/';
      String cellXml;
      int nextPos;

      if (isSelfClosing) {
        cellXml = rowXml.substring(cStart, tagEnd + 1);
        nextPos = tagEnd + 1;
      } else {
        final cEnd = rowXml.indexOf('</c>', tagEnd);
        if (cEnd == -1) break;
        cellXml = rowXml.substring(cStart, cEnd + 4);
        nextPos = cEnd + 4;
      }

      _processCell(cellXml, row, cells);
      pos = nextPos;
    }
  }

  void _processCell(
      String cellXml, int row, Map<CellAddress, CellModel> cells) {
    // استخراج عنوان العمود من r="A3" مثلاً
    final rMatch = RegExp(r'\br="([A-Z]+)\d+"').firstMatch(cellXml);
    if (rMatch == null) return;
    final colName = rMatch.group(1) ?? '';
    final column = columnNameToIndex(colName);

    final styleIndex = int.tryParse(
          RegExp(r'\bs="(\d+)"').firstMatch(cellXml)?.group(1) ?? '0',
        ) ??
        0;

    final value = resolveCellValue(
      cellXml: cellXml,
      sharedStrings: sharedStrings,
    );

    final formula = extractFormula(cellXml);

    final style = styles.cellStyles.isNotEmpty
        ? styles.cellStyles[math.min(styleIndex, styles.cellStyles.length - 1)]
        : defaultCellStyle();

    // استخراج numFmtId و formatCode من نفس xf المرتبط بـ styleIndex
    final numFmtId = styles.cellNumFmtIds.isNotEmpty &&
            styleIndex < styles.cellNumFmtIds.length
        ? styles.cellNumFmtIds[styleIndex]
        : 0;
    final formatCode = styles.numberFormats[numFmtId];

    cells[CellAddress(row, column)] = CellModel(
      address: CellAddress(row, column),
      value: value,
      formula: formula,
      style: style,
      numFmtId: numFmtId,
      formatCode: formatCode,
    );
  }

  void _parseColumns(String xml, Map<int, double> widths) {
    final regex = RegExp(r'<col\s+([^>]+)>');

    for (final match in regex.allMatches(xml)) {
      final attrs = match.group(1) ?? '';

      final minMatch = RegExp(r'\bmin="(\d+)"').firstMatch(attrs);
      final maxMatch = RegExp(r'\bmax="(\d+)"').firstMatch(attrs);
      final widthMatch = RegExp(r'\bwidth="([\d.]+)"').firstMatch(attrs);

      if (minMatch == null || maxMatch == null) continue;

      final min = int.parse(minMatch.group(1)!);
      final max = int.parse(maxMatch.group(1)!);

      final isHidden = RegExp(r'\bhidden="(1|true)"').hasMatch(attrs);

      // [الحل هنا]: استخدمنا 68.0 كقيمة رقمية ثابتة بدلاً من المتغير غير المعرف في هذا الكلاس
      double pdfWidth = 68.0;
      if (widthMatch != null) {
        final w = double.tryParse(widthMatch.group(1)!) ?? 8.43;
        // معادلة محاكاة الإكسل الدقيقة: (العرض × 7.5) + مساحة أمان 5.0 نقاط
        pdfWidth = ((w * 7.5) + 5.0).clamp(10.0, 500.0);
      }

      if (isHidden) pdfWidth = 0.0;

      for (int c = min - 1; c <= max - 1 && c >= 0; c++) {
        widths[c] = pdfWidth;
      }
    }
  }

  void _parseMergedCells(String xml, List<MergedRange> merges) {
    final regex = RegExp(r'<mergeCell[^>]*ref="([A-Z]+)(\d+):([A-Z]+)(\d+)"');

    for (final match in regex.allMatches(xml)) {
      merges.add(MergedRange(
        firstRow: int.parse(match.group(2)!) - 1,
        lastRow: int.parse(match.group(4)!) - 1,
        firstColumn: columnNameToIndex(match.group(1)!),
        lastColumn: columnNameToIndex(match.group(3)!),
      ));
    }
  }
}

// =====================================================================
// محلّل ملف الرسم البياني (chartN.xml) — يستخرج numCache/strCache مباشرة
// (هذه القيم جاهزة بالفعل في الملف ولا تحتاج حساب الصيغ Excel)
// =====================================================================

class ChartXmlParser {
  final String xml;
  ChartXmlParser(this.xml);

  static const List<int> _palette = [
    0xFF4F81BD,
    0xFFC0504D,
    0xFF9BBB59,
    0xFFF6A625,
    0xFF8064A2,
    0xFF4BACC6,
  ];

  ChartObject? parse({
    required int fromCol,
    required int fromRow,
    required double widthEmu,
    required double heightEmu,
    required double offsetYEmu,
  }) {
    final kind = _detectKind();
    if (kind == ChartKind.unknown) return null;

    final title = _extractTitle();
    final series =
        kind == ChartKind.pie ? _extractPieSeries() : _extractCartesianSeries();

    if (series.isEmpty) return null;

    return ChartObject(
      kind: kind,
      title: title,
      series: series,
      fromCol: fromCol,
      fromRow: fromRow,
      widthEmu: widthEmu,
      heightEmu: heightEmu,
      offsetYEmu: offsetYEmu,
    );
  }

  ChartKind _detectKind() {
    if (xml.contains('<c:barChart')) return ChartKind.bar;
    if (xml.contains('<c:lineChart')) return ChartKind.line;
    if (xml.contains('<c:pieChart') || xml.contains('<c:pie3DChart')) {
      return ChartKind.pie;
    }
    if (xml.contains('<c:areaChart')) return ChartKind.area;
    return ChartKind.unknown;
  }

  String _extractTitle() {
    final titleBlock = _extractSection(xml, 'c:title');
    if (titleBlock.isEmpty) return '';
    final texts = RegExp(r'<a:t>([^<]*)<\/a:t>').allMatches(titleBlock);
    return texts.map((m) => decodeXml(m.group(1) ?? '')).join();
  }

  List<ChartSeries> _extractCartesianSeries() {
    final result = <ChartSeries>[];
    int colorIdx = 0;
    int pos = 0;
    while (true) {
      final start = xml.indexOf('<c:ser>', pos);
      if (start == -1) break;
      final end = xml.indexOf('</c:ser>', start);
      if (end == -1) break;
      final block = xml.substring(start, end + 8);
      pos = end + 8;

      final name = _extractSeriesName(block);
      final categories = _extractStrCache(block, 'c:cat');
      final values = _extractNumCache(block, 'c:val');
      final rgb = _extractSeriesRgb(block) ?? _paletteRgb(colorIdx);
      colorIdx++;

      if (values.isNotEmpty) {
        result.add(ChartSeries(
          name: name,
          categories: categories,
          values: values,
          color: PdfColor(rgb.$1, rgb.$2, rgb.$3),
          colorR: rgb.$1,
          colorG: rgb.$2,
          colorB: rgb.$3,
        ));
      }
    }
    return result;
  }

  List<ChartSeries> _extractPieSeries() {
    final result = <ChartSeries>[];
    final start = xml.indexOf('<c:ser>');
    if (start == -1) return result;
    final end = xml.indexOf('</c:ser>', start);
    if (end == -1) return result;
    final block = xml.substring(start, end + 8);

    final categories = _extractStrCache(block, 'c:cat');
    final values = _extractNumCache(block, 'c:val');
    final name = _extractSeriesName(block);

    if (values.isNotEmpty) {
      result.add(ChartSeries(
        name: name,
        categories: categories,
        values: values,
        color: const PdfColor(79, 129, 189),
        colorR: 79,
        colorG: 129,
        colorB: 189,
      ));
    }
    return result;
  }

  String _extractSeriesName(String serBlock) {
    final txBlock = _extractSection(serBlock, 'c:tx');
    final m = RegExp(r'<c:v>([^<]*)<\/c:v>').firstMatch(txBlock);
    return decodeXml(m?.group(1) ?? '');
  }

  (int, int, int)? _extractSeriesRgb(String serBlock) {
    final spPr = _extractSection(serBlock, 'c:spPr');
    final m = RegExp(r'srgbClr val="([0-9A-Fa-f]{6})"').firstMatch(spPr);
    if (m == null) return null;
    final hex = m.group(1)!;
    return (
      int.parse(hex.substring(0, 2), radix: 16),
      int.parse(hex.substring(2, 4), radix: 16),
      int.parse(hex.substring(4, 6), radix: 16),
    );
  }

  (int, int, int) _paletteRgb(int idx) {
    final v = _palette[idx % _palette.length];
    return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
  }

  List<String> _extractStrCache(String block, String tag) {
    final section = _extractSection(block, tag);
    if (section.isEmpty) return [];
    // قد تكون فئات رقمية (numRef) أو نصية (strRef)
    final pts = RegExp(r'<c:pt[^>]*idx="(\d+)"[^>]*>\s*<c:v>([^<]*)<\/c:v>')
        .allMatches(section)
        .toList();
    if (pts.isEmpty) return [];
    final maxIdx = pts.map((m) => int.parse(m.group(1)!)).reduce(math.max);
    final result = List<String>.filled(maxIdx + 1, '');
    for (final m in pts) {
      final idx = int.parse(m.group(1)!);
      result[idx] = decodeXml(m.group(2) ?? '');
    }
    return result;
  }

  List<double> _extractNumCache(String block, String tag) {
    final section = _extractSection(block, tag);
    if (section.isEmpty) return [];
    final pts = RegExp(r'<c:pt[^>]*idx="(\d+)"[^>]*>\s*<c:v>([^<]*)<\/c:v>')
        .allMatches(section)
        .toList();
    if (pts.isEmpty) return [];
    final maxIdx = pts.map((m) => int.parse(m.group(1)!)).reduce(math.max);
    final result = List<double>.filled(maxIdx + 1, 0);
    for (final m in pts) {
      final idx = int.parse(m.group(1)!);
      result[idx] = double.tryParse(m.group(2) ?? '0') ?? 0;
    }
    return result;
  }

  String _extractSection(String text, String tag) {
    final start = text.indexOf('<$tag>');
    if (start == -1) {
      // قد يكون بدون محتوى وذو سمات: <c:tag ...>
      final start2 = text.indexOf('<$tag ');
      if (start2 == -1) return '';
      final end2 = text.indexOf('</$tag>', start2);
      if (end2 == -1) return '';
      return text.substring(start2, end2 + tag.length + 3);
    }
    final end = text.indexOf('</$tag>', start);
    if (end == -1) return '';
    return text.substring(start, end + tag.length + 3);
  }
}

// =====================================================================
// أنماط المصنّف
// =====================================================================

class WorkbookStyles {
  final List<FontStyleModel> fonts;
  final List<FillStyleModel> fills;
  final List<BorderStyleModel> borders;
  final List<CellStyleModel> cellStyles;
  final List<int> cellNumFmtIds; // نحتفظ بـ numFmtId لكل xf
  final Map<int, String> numberFormats; // numFmtId → formatCode (مدمج + مخصص)

  WorkbookStyles({
    required this.fonts,
    required this.fills,
    required this.borders,
    required this.cellStyles,
    required this.cellNumFmtIds,
    required this.numberFormats,
  });

  factory WorkbookStyles.empty() => WorkbookStyles(
        fonts: [],
        fills: [],
        borders: [],
        cellStyles: [],
        cellNumFmtIds: [],
        numberFormats: {},
      );
}

class StylesParser {
  final XlsxArchiveReader archive;
  StylesParser(this.archive);

  Future<WorkbookStyles> parse() async {
    final xml = archive.readText('xl/styles.xml');
    if (xml == null) return WorkbookStyles.empty();

    final fonts = _parseFonts(xml);
    final fills = _parseFills(xml);
    final borders = _parseBorders(xml);
    final numberFormats = _parseNumberFormats(xml);
    final (cellStyles, numFmtIds) = _parseCellXfs(xml, fonts, fills, borders);

    return WorkbookStyles(
      fonts: fonts,
      fills: fills,
      borders: borders,
      cellStyles: cellStyles,
      cellNumFmtIds: numFmtIds,
      numberFormats: numberFormats,
    );
  }

  List<FontStyleModel> _parseFonts(String xml) {
    final result = <FontStyleModel>[];
    // استخراج قسم <fonts> أولاً لتجنب اصطياد <font> خارج القسم
    final fontsSection = _extractSection(xml, 'fonts');
    final regex = RegExp(r'<font>(.*?)<\/font>', dotAll: true);

    for (final match in regex.allMatches(fontsSection)) {
      final block = match.group(1)!;
      final size = double.tryParse(
            RegExp(r'<sz val="([\d.]+)"').firstMatch(block)?.group(1) ?? '11',
          ) ??
          11;
      final family =
          RegExp(r'<name val="([^"]+)"').firstMatch(block)?.group(1) ??
              'Calibri';
      final bold = RegExp(r'<b\s*/>|<b val="true"').hasMatch(block) &&
          !RegExp(r'<b val="false"').hasMatch(block);
      final italic = RegExp(r'<i\s*/>|<i val="true"').hasMatch(block) &&
          !RegExp(r'<i val="false"').hasMatch(block);
      final underline = RegExp(r'<u\s*/>|<u\s|<u val="').hasMatch(block);
      final color = parseFontColor(block);

      result.add(FontStyleModel(
        family: family,
        size: size,
        bold: bold,
        italic: italic,
        underline: underline,
        color: color,
      ));
    }

    if (result.isEmpty) result.add(defaultCellStyle().font);
    return result;
  }

  List<FillStyleModel> _parseFills(String xml) {
    final fills = <FillStyleModel>[];
    final section = _extractSection(xml, 'fills');
    final regex = RegExp(r'<fill>(.*?)<\/fill>', dotAll: true);

    for (final match in regex.allMatches(section)) {
      final block = match.group(1)!;
      // تجاهل patternType="none" → خلفية شفافة = أبيض
      final patternType =
          RegExp(r'patternType="([^"]+)"').firstMatch(block)?.group(1);
      if (patternType == null || patternType == 'none') {
        fills.add(FillStyleModel(background: const PdfColor(255, 255, 255)));
        continue;
      }
      final colorMatch =
          RegExp(r'fgColor[^/]*(rgb|theme)="([^"]+)"').firstMatch(block);
      fills.add(FillStyleModel(background: parseColor(colorMatch?.group(2))));
    }

    if (fills.isEmpty) fills.add(defaultCellStyle().fill);
    return fills;
  }

  List<BorderStyleModel> _parseBorders(String xml) {
    final borders = <BorderStyleModel>[];
    final section = _extractSection(xml, 'borders');
    final regex = RegExp(r'<border[^>]*>(.*?)<\/border>', dotAll: true);

    for (final match in regex.allMatches(section)) {
      final block = match.group(1)!;
      borders.add(BorderStyleModel(
        left: parseBorderEdge(block, 'left'),
        right: parseBorderEdge(block, 'right'),
        top: parseBorderEdge(block, 'top'),
        bottom: parseBorderEdge(block, 'bottom'),
      ));
    }

    if (borders.isEmpty) borders.add(defaultCellStyle().border);
    return borders;
  }

  /// يقرأ تعريفات numFmt المخصصة (164+) من styles.xml،
  /// ثم يدمجها مع جدول التنسيقات المدمجة الثابتة في Excel (0-49) كي يكون
  /// لدينا formatCode فعلي لكل numFmtId — مدمجاً كان أو مخصصاً.
  Map<int, String> _parseNumberFormats(String xml) {
    final map = <int, String>{...builtInNumberFormats};
    final regex = RegExp(r'<numFmt\s+numFmtId="(\d+)"\s+formatCode="([^"]+)"');

    for (final match in regex.allMatches(xml)) {
      map[int.parse(match.group(1)!)] = decodeXml(match.group(2)!);
    }
    return map;
  }

  // ignore: unintended_html_in_doc_comment
  /// يلتقط <xf ...></xf> (مع محتوى alignment) و <xf .../> معاً.
  (List<CellStyleModel>, List<int>) _parseCellXfs(
    String xml,
    List<FontStyleModel> fonts,
    List<FillStyleModel> fills,
    List<BorderStyleModel> borders,
  ) {
    // استخرج قسم cellXfs فقط (وليس cellStyleXfs الذي يحمل تعريفات الأنماط
    // المسمّاة، لأننا نريد الـ xf المرتبطة بالخلايا الفعلية)
    final section = _extractSection(xml, 'cellXfs');

    final cellStylesList = <CellStyleModel>[];
    final numFmtIds = <int>[];

    // نمط يلتقط كلاً من <xf .../> و <xf ...>...</xf>
    final regex =
        RegExp(r'<xf([^>]*?)(?:\s*/>|>([\s\S]*?)<\/xf>)', dotAll: true);

    for (final match in regex.allMatches(section)) {
      final attrs = match.group(1) ?? '';
      final inner = match.group(2) ?? ''; // محتوى <alignment> وغيره

      final fontId = _intAttr(attrs, 'fontId');
      final fillId = _intAttr(attrs, 'fillId');
      final borderId = _intAttr(attrs, 'borderId');
      final numFmtId = _intAttr(attrs, 'numFmtId');
      numFmtIds.add(numFmtId);

      // ابحث عن alignment في attrs أولاً، ثم في inner
      final alignSource = inner.isNotEmpty ? '$attrs $inner' : attrs;

      cellStylesList.add(CellStyleModel(
        font: fonts.isEmpty
            ? defaultCellStyle().font
            : fonts[math.min(fontId, fonts.length - 1)],
        fill: fills.isEmpty
            ? defaultCellStyle().fill
            : fills[math.min(fillId, fills.length - 1)],
        border: borders.isEmpty
            ? defaultCellStyle().border
            : borders[math.min(borderId, borders.length - 1)],
        horizontalAlignment: horizontalAlignmentFromAttrs(alignSource),
        verticalAlignment: verticalAlignmentFromAttrs(alignSource),
        wrapText: alignSource.contains('wrapText="1"') ||
            alignSource.contains('wrapText="true"'),
      ));
    }

    return (cellStylesList, numFmtIds);
  }

  int _intAttr(String attrs, String name) {
    return int.tryParse(
          RegExp('$name="(\\d+)"').firstMatch(attrs)?.group(1) ?? '0',
        ) ??
        0;
  }

  // ignore: unintended_html_in_doc_comment
  /// يستخرج محتوى قسم XML بين <tag ...> و </tag>
  String _extractSection(String xml, String tag) {
    final start = xml.indexOf('<$tag');
    if (start == -1) return '';
    final end = xml.indexOf('</$tag>', start);
    if (end == -1) return '';
    return xml.substring(start, end + tag.length + 3);
  }
}

/// جدول numFmtId المدمجة في Excel (Built-in Number Formats 0-49) —
/// هذه لا تُكتب صراحةً في styles.xml لأنها معروفة ضمنياً لكل برامج Excel،
/// لذلك يجب توفيرها يدوياً كي يعمل معها محرك التنسيق نفسه المستخدَم
/// للتنسيقات المخصصة (164+) دون تفريق في الكود.
const Map<int, String> builtInNumberFormats = {
  0: 'General',
  1: '0',
  2: '0.00',
  3: '#,##0',
  4: '#,##0.00',
  9: '0%',
  10: '0.00%',
  11: '0.00E+00',
  12: '# ?/?',
  13: '# ??/??',
  14: 'mm-dd-yy',
  15: 'd-mmm-yy',
  16: 'd-mmm',
  17: 'mmm-yy',
  18: 'h:mm AM/PM',
  19: 'h:mm:ss AM/PM',
  20: 'h:mm',
  21: 'h:mm:ss',
  22: 'm/d/yy h:mm',
  37: '#,##0 ;(#,##0)',
  38: '#,##0 ;[Red](#,##0)',
  39: '#,##0.00;(#,##0.00)',
  40: '#,##0.00;[Red](#,##0.00)',
  41: '_(* #,##0_);_(* (#,##0);_(* "-"_);_(@_)',
  42: '_(\$* #,##0_);_(\$* (#,##0);_(\$* "-"_);_(@_)',
  43: '_(* #,##0.00_);_(* (#,##0.00);_(* "-"??_);_(@_)',
  44: '_(\$* #,##0.00_);_(\$* (#,##0.00);_(\$* "-"??_);_(@_)',
  45: 'mm:ss',
  46: '[h]:mm:ss',
  47: 'mmss.0',
  48: '##0.0E+0',
  49: '@',
};

// =====================================================================
// دوال مساعدة عامة
// =====================================================================

String decodeXml(String input) {
  return input
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

int columnNameToIndex(String name) {
  int result = 0;
  for (int i = 0; i < name.length; i++) {
    result = result * 26 + (name.codeUnitAt(i) - 64);
  }
  return result - 1;
}

dynamic resolveCellValue({
  required String cellXml,
  required List<SharedStringItem> sharedStrings,
}) {
  final typeMatch = RegExp(r'\bt="([a-zA-Z]+)"').firstMatch(cellXml);
  final type = typeMatch?.group(1);

  if (type == 'inlineStr') {
    final isMatch = RegExp(r'<is>([\s\S]*?)<\/is>').firstMatch(cellXml);
    final tMatch =
        RegExp(r'<t[^>]*>([\s\S]*?)<\/t>').firstMatch(isMatch?.group(1) ?? '');
    return decodeXml(tMatch?.group(1) ?? '');
  }

  final vMatch = RegExp(r'<v>([\s\S]*?)<\/v>').firstMatch(cellXml);
  final raw = vMatch?.group(1) ?? '';
  if (raw.isEmpty) return '';

  if (type == 's') {
    final idx = int.tryParse(raw);
    if (idx != null && idx >= 0 && idx < sharedStrings.length) {
      return sharedStrings[idx].text;
    }
    return '';
  }
  if (type == 'str') return decodeXml(raw);
  if (type == 'b') return raw == '1';

  final n = num.tryParse(raw);
  return n ?? decodeXml(raw);
}

String? extractFormula(String cellXml) {
  final m = RegExp(r'<f[^>]*>([\s\S]*?)<\/f>').firstMatch(cellXml);
  return m != null ? decodeXml(m.group(1) ?? '') : null;
}

CellStyleModel defaultCellStyle() {
  return CellStyleModel(
    font: FontStyleModel(
      family: 'Calibri',
      size: 10,
      bold: false,
      italic: false,
      underline: false,
      color: const PdfColor(0, 0, 0),
    ),
    fill: FillStyleModel(background: const PdfColor(255, 255, 255)),
    border: BorderStyleModel(
      left: BorderEdge(
          color: const PdfColor(216, 216, 216), width: 0.4, style: 'thin'),
      right: BorderEdge(
          color: const PdfColor(216, 216, 216), width: 0.4, style: 'thin'),
      top: BorderEdge(
          color: const PdfColor(216, 216, 216), width: 0.4, style: 'thin'),
      bottom: BorderEdge(
          color: const PdfColor(216, 216, 216), width: 0.4, style: 'thin'),
    ),
    horizontalAlignment: HorizontalAlignment.left,
    verticalAlignment: VerticalAlignment.center,
    wrapText: false,
  );
}

PdfColor parseColor(String? value) {
  if (value == null || value.isEmpty) return const PdfColor(255, 255, 255);
  String hex = value;
  if (hex.length == 8) hex = hex.substring(2);
  if (hex.length != 6) return const PdfColor(255, 255, 255);
  try {
    return PdfColor(
      int.parse(hex.substring(0, 2), radix: 16),
      int.parse(hex.substring(2, 4), radix: 16),
      int.parse(hex.substring(4, 6), radix: 16),
    );
  } catch (_) {
    return const PdfColor(255, 255, 255);
  }
}

PdfColor parseFontColor(String fontXml) {
  final rgb = RegExp(r'rgb="([0-9A-Fa-f]+)"').firstMatch(fontXml);
  if (rgb == null) return const PdfColor(0, 0, 0);
  return parseColor(rgb.group(1));
}

HorizontalAlignment horizontalAlignmentFromAttrs(String attrs) {
  final m = RegExp(r'horizontal="([a-zA-Z]+)"').firstMatch(attrs);
  switch (m?.group(1)) {
    case 'center':
    case 'centerContinuous':
      return HorizontalAlignment.center;
    case 'right':
      return HorizontalAlignment.right;
    case 'justify':
    case 'distributed':
      return HorizontalAlignment.justify;
    default:
      return HorizontalAlignment.left;
  }
}

VerticalAlignment verticalAlignmentFromAttrs(String attrs) {
  final m = RegExp(r'vertical="([a-zA-Z]+)"').firstMatch(attrs);
  switch (m?.group(1)) {
    case 'top':
      return VerticalAlignment.top;
    case 'bottom':
      return VerticalAlignment.bottom;
    default:
      return VerticalAlignment.center;
  }
}

BorderEdge parseBorderEdge(String borderBlock, String edge) {
  final edgeMatch = RegExp('<$edge([^>]*)(?:/>|>(.*?)<\\/$edge>)', dotAll: true)
      .firstMatch(borderBlock);

  if (edgeMatch == null) {
    return BorderEdge(
        color: const PdfColor(216, 216, 216), width: 0, style: 'none');
  }

  final attrs = edgeMatch.group(1) ?? '';
  final inner = edgeMatch.group(2) ?? '';
  final style =
      RegExp(r'style="([^"]+)"').firstMatch(attrs)?.group(1) ?? 'none';

  if (style.isEmpty || style == 'none') {
    return BorderEdge(
        color: const PdfColor(216, 216, 216), width: 0, style: 'none');
  }

  final colorMatch = RegExp(r'rgb="([0-9A-Fa-f]+)"').firstMatch(inner);
  return BorderEdge(
    color: parseColor(colorMatch?.group(1)),
    width: borderWidthForStyle(style),
    style: style,
  );
}

double borderWidthForStyle(String style) {
  switch (style) {
    case 'thick':
      return 1.4;
    case 'medium':
    case 'mediumDashed':
    case 'mediumDashDot':
      return 0.9;
    case 'hair':
      return 0.25;
    default:
      return 0.5;
  }
}

// =====================================================================
// محرك تنسيق الأرقام — يقرأ formatCode الفعلي (مدمج أو مخصص) ويُنتج
// النص النهائي بدقة: عملة، نسبة، تاريخ، فواصل آلاف، أقواس للسالب.
// هذا يحل المشكلة الجوهرية: numFmtId المخصصة (164+) لم تكن تُعالَج إطلاقاً.
// =====================================================================

class NumberFormatEngine {
  /// نقطة الدخول الرئيسية: ينسّق قيمة الخلية بحسب numFmtId/formatCode الخاص بها
  static String format(dynamic value, int numFmtId, String? formatCode) {
    if (value == null) return '';
    if (value is bool) return value ? 'TRUE' : 'FALSE';
    if (value is! num) return value.toString();

    final code = formatCode ?? builtInNumberFormats[numFmtId] ?? 'General';

    if (code == 'General' || code == '@') {
      return _generalNumber(value);
    }

    if (_isDateCode(numFmtId, code)) {
      return _formatDate(value, code);
    }

    return _formatWithCode(value, code);
  }

  static bool _isDateCode(int numFmtId, String code) {
    if ((numFmtId >= 14 && numFmtId <= 22) ||
        (numFmtId >= 45 && numFmtId <= 47)) {
      return true;
    }
    final lower = code.toLowerCase();
    // تجاهل علامات النصوص بين قوسين عند الفحص (مثل "SAR" التي قد تحوي حروفاً)
    final withoutQuoted = lower.replaceAll(RegExp(r'"[^"]*"'), '');
    return withoutQuoted.contains('yy') ||
        withoutQuoted.contains('mmm') ||
        (withoutQuoted.contains('dd') && !withoutQuoted.contains('0.00')) ||
        withoutQuoted.contains('hh') ||
        (withoutQuoted.contains('m/d')) ||
        (withoutQuoted.contains('d-m'));
  }

  static String _generalNumber(num value) {
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return value.toInt().toString();
    }
    // Excel "General" يعرض حتى ~11 رقم معنوي مع حذف الأصفار الزائدة
    String s = value.toStringAsFixed(6);
    s = s.replaceFirst(RegExp(r'0+$'), '');
    s = s.replaceFirst(RegExp(r'\.$'), '');
    return s;
  }

  /// ينسّق التاريخ/الوقت بحسب رموز Excel الشائعة (yyyy, mm, dd, mmmm, hh, ss...)
  static String _formatDate(num serial, String code) {
    final dt = _excelSerialToDate(serial);
    if (dt == null) return _generalNumber(serial);

    const monthsFull = [
      'يناير',
      'فبراير',
      'مارس',
      'أبريل',
      'مايو',
      'يونيو',
      'يوليو',
      'أغسطس',
      'سبتمبر',
      'أكتوبر',
      'نوفمبر',
      'ديسمبر',
    ];
    const monthsShort = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    String two(int n) => n.toString().padLeft(2, '0');
    final lower = code.toLowerCase();

    String result = code;
    // الترتيب مهم: استبدل الأطول أولاً لتجنب تعارض الرموز (yyyy قبل yy)
    if (lower.contains('yyyy')) {
      result = _ireplace(result, 'yyyy', dt.year.toString().padLeft(4, '0'));
    } else if (lower.contains('yy')) {
      result = _ireplace(result, 'yy', two(dt.year % 100));
    }

    if (lower.contains('mmmm')) {
      result = _ireplace(result, 'mmmm', monthsFull[dt.month - 1]);
    } else if (lower.contains('mmm')) {
      result = _ireplace(result, 'mmm', monthsShort[dt.month - 1]);
    } else if (lower.contains('mm')) {
      result = _ireplace(result, 'mm', two(dt.month));
    }

    if (lower.contains('dd')) {
      result = _ireplace(result, 'dd', two(dt.day));
    } else if (lower.contains('d')) {
      result = _ireplace(result, 'd', dt.day.toString());
    }

    if (lower.contains('hh')) {
      result = _ireplace(result, 'hh', two(dt.hour));
    }
    if (lower.contains('ss')) {
      result = _ireplace(result, 'ss', two(dt.second));
    }

    // إزالة الفواصل والشرطات المهرَّبة (\- \  إلخ) من Excel format codes
    result = result.replaceAll('\\', '');
    return result;
  }

  static String _ireplace(String source, String pattern, String value) {
    final regex = RegExp(RegExp.escape(pattern), caseSensitive: false);
    return source.replaceFirst(regex, value);
  }

  static DateTime? _excelSerialToDate(num serial) {
    if (serial < 0 || serial > 2958465) return null;
    int days = serial.toInt();
    if (days >= 60) days--; // تصحيح خطأ Excel التاريخي (29 فبراير 1900 الوهمي)
    final base = DateTime(1899, 12, 31);
    final fractional = serial - serial.toInt();
    final date = base.add(Duration(
      days: days,
      milliseconds: (fractional * 86400000).round(),
    ));
    return date;
  }

  /// يطبّق formatCode عام (عملة/نسبة/فواصل آلاف/أقواس سالبة) على رقم
  static String _formatWithCode(num value, String code) {
    // تنسيقات مع قسمين (موجب;سالب) مثل: #,##0.00;(#,##0.00)
    final sections = _splitFormatSections(code);
    final isNegative = value < 0;
    final absValue = value.abs();

    String activeSection;
    bool wrapNegativeInParens = false;

    if (isNegative && sections.length > 1) {
      activeSection = sections[1];
    } else {
      activeSection = sections[0];
    }

    // استخرج أي نص ثابت بين علامات اقتباس (مثل "SAR" أو "$" أو "EUR")
    final literals = <String>[];
    final withoutLiterals = activeSection.replaceAllMapped(
      RegExp(r'"([^"]*)"'),
      (m) {
        literals.add(m.group(1) ?? '');
        return '\u0001${literals.length - 1}\u0001';
      },
    );

    // كشف وجود أقواس صريحة في القسم السالب (شكل تحاسبي) مقابل علامة سالب عادية
    if (isNegative && sections.length > 1 && sections[1].contains('(')) {
      wrapNegativeInParens = true;
    }

    final isPercent = withoutLiterals.contains('%');
    final decimalsMatch = RegExp(r'0\.(0+)').firstMatch(withoutLiterals);
    final decimals = decimalsMatch?.group(1)?.length ?? 0;
    final hasThousands =
        withoutLiterals.contains('#,##0') || withoutLiterals.contains('#,###');

    num displayValue = isPercent ? absValue * 100 : absValue;

    String numStr = decimals > 0
        ? displayValue.toStringAsFixed(decimals)
        : displayValue.round().toString();

    if (hasThousands) {
      numStr = _addThousandsSeparator(numStr);
    }

    // أعد إدراج النصوص الثابتة (عملات) في مواضعها
    String output = withoutLiterals;
    for (int i = 0; i < literals.length; i++) {
      output = output.replaceFirst('\u0001$i\u0001', literals[i]);
    }

    // استبدل أول تسلسل أرقام/علامات تنسيق بالقيمة الفعلية المُنسَّقة
    output = output.replaceFirst(
      RegExp(r'#?,?#*#?,?#*0(\.0+)?'),
      numStr,
    );
    if (isPercent && !output.contains('%')) output += '%';

    if (isNegative) {
      if (wrapNegativeInParens) {
        return '($output)';
      }
      if (sections.length > 1) {
        // القسم السالب لم يُحدّد أقواساً ولا علامة سالب صريحة ضمن الأدبيات؛
        // الأَولى عرضها كما صِيغت في القسم نفسه (قد تحوي بالفعل تنسيقاً خاصاً)
        return output;
      }
      return '-$output';
    }
    return output;
  }

  static List<String> _splitFormatSections(String code) {
    // تقسيم بسيط على ; مع تجاهل ; الموجودة داخل علامات اقتباس
    final sections = <String>[];
    final buffer = StringBuffer();
    bool inQuotes = false;
    for (int i = 0; i < code.length; i++) {
      final ch = code[i];
      if (ch == '"') inQuotes = !inQuotes;
      if (ch == ';' && !inQuotes) {
        sections.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
    sections.add(buffer.toString());
    return sections.isEmpty ? [code] : sections;
  }

  static String _addThousandsSeparator(String numStr) {
    final parts = numStr.split('.');
    final intPart = parts[0];
    final buffer = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buffer.write(',');
      buffer.write(intPart[i]);
    }
    if (parts.length > 1) {
      return '${buffer.toString()}.${parts[1]}';
    }
    return buffer.toString();
  }
}

// =====================================================================
// CSV / TSV
// =====================================================================

WorksheetModel parseDelimitedTextToSheet(String text, String delimiter) {
  final cells = <CellAddress, CellModel>{};
  final rows = parseDelimitedRows(text, delimiter);
  final baseStyle = defaultCellStyle();
  final headerStyle = CellStyleModel(
    font: FontStyleModel(
      family: baseStyle.font.family,
      size: baseStyle.font.size,
      bold: true,
      italic: false,
      underline: false,
      color: baseStyle.font.color,
    ),
    fill: FillStyleModel(background: const PdfColor(230, 230, 230)),
    border: baseStyle.border,
    horizontalAlignment: baseStyle.horizontalAlignment,
    verticalAlignment: baseStyle.verticalAlignment,
    wrapText: false,
  );

  int rowIndex = 0;
  for (final fields in rows) {
    final isBlankRow = fields.every((f) => f.trim().isEmpty);
    if (isBlankRow && rowIndex == 0) continue;

    for (int col = 0; col < fields.length; col++) {
      final raw = fields[col].trim();
      if (raw.isEmpty) continue;
      cells[CellAddress(rowIndex, col)] = CellModel(
        address: CellAddress(rowIndex, col),
        value: _inferDelimitedValue(raw),
        style: rowIndex == 0 ? headerStyle : baseStyle,
      );
    }
    rowIndex++;
  }

  return WorksheetModel(
    name: 'Sheet1',
    cells: cells,
    mergedRanges: const [],
    rowHeights: const {},
    columnWidths: const {},
    images: const [],
    charts: const [],
  );
}

/// محلل RFC 4180 كامل — يدعم حقول متعددة الأسطر داخل علامات اقتباس
List<List<String>> parseDelimitedRows(String text, String delimiter) {
  final rows = <List<String>>[];
  var fields = <String>[];
  final buffer = StringBuffer();
  bool inQuotes = false;
  int i = 0;
  final len = text.length;

  void endField() {
    fields.add(buffer.toString());
    buffer.clear();
  }

  void endRow() {
    endField();
    rows.add(fields);
    fields = <String>[];
  }

  while (i < len) {
    final ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < len && text[i + 1] == '"') {
          buffer.write('"');
          i += 2;
        } else {
          inQuotes = false;
          i++;
        }
      } else {
        buffer.write(ch);
        i++;
      }
      continue;
    }

    if (ch == '"') {
      inQuotes = true;
      i++;
    } else if (ch == delimiter) {
      endField();
      i++;
    } else if (ch == '\r') {
      if (i + 1 < len && text[i + 1] == '\n') i++;
      endRow();
      i++;
    } else if (ch == '\n') {
      endRow();
      i++;
    } else {
      buffer.write(ch);
      i++;
    }
  }

  if (buffer.isNotEmpty || fields.isNotEmpty) endRow();
  return rows;
}

dynamic _inferDelimitedValue(String raw) {
  final n = num.tryParse(raw);
  return n ?? raw;
}

// =====================================================================
// إدارة الخطوط
// =====================================================================

class PdfFontManager {
  PdfFontManager._();

  static bool _initialized = false;
  static Uint8List? _arabicRegular;
  static Uint8List? _arabicBold;
  static Uint8List? _latinRegular;
  static Uint8List? _latinBold;
  static final Map<String, PdfFont> _cache = {};

  /// يهيّئ خطوط القياس. إن مُرِّرت [preloadedFonts] (مفاتيحها مسارات
  /// assets، محمَّلة مسبقاً في Main Isolate)، تُستخدَم مباشرة بلا أي
  /// استدعاء لـ rootBundle — ضروري عند تشغيل التحليل في Worker Isolate
  /// (نفس مشكلة التوقف عند تحميل الخطوط المُشخَّصة والمُصلَحة مسبقاً في
  /// DOCX؛ rootBundle.load داخل Worker Isolate غير موثوق إطلاقاً).
  /// عند الاستدعاء من Main Isolate مباشرة بلا preloadedFonts (مثل convert()
  /// المباشرة)، يبقى المسار القديم عبر rootBundle صالحاً كاحتياط.
  static Future<void> initialize(
      {Map<String, Uint8List>? preloadedFonts}) async {
    if (_initialized) return;
    _initialized = true;

    const arabicRegPath = 'assets/fonts/Cairo-Regular.ttf';
    const arabicBoldPath = 'assets/fonts/Cairo-Bold.ttf';
    const latinRegPath = 'assets/fonts/LiberationSans-Regular.ttf';
    const latinBoldPath = 'assets/fonts/LiberationSans-Bold.ttf';

    if (preloadedFonts != null) {
      _arabicRegular = preloadedFonts[arabicRegPath];
      _arabicBold = preloadedFonts[arabicBoldPath];
      _latinRegular = preloadedFonts[latinRegPath];
      _latinBold = preloadedFonts[latinBoldPath];
      return;
    }

    Future<Uint8List?> tryLoad(String path) async {
      try {
        final data = await rootBundle.load(path);
        return data.buffer.asUint8List();
      } catch (_) {
        return null;
      }
    }

    // Cairo يدعم Arabic + Latin معاً بجودة عالية، فنستخدمه أساساً موحَّداً
    // لتجنّب اختلاف القياسات بين خط عربي وخط لاتيني منفصلين في نفس الخلية.
    _arabicRegular = await tryLoad(arabicRegPath);
    _arabicBold = await tryLoad(arabicBoldPath);
    _latinRegular = await tryLoad(latinRegPath);
    _latinBold = await tryLoad(latinBoldPath);
  }

  /// يسمح بإعادة التهيئة عند تغيّر preloadedFonts بين استدعاءات منفصلة
  /// (resetCache يُصفّر الخطوط أيضاً عبر إعادة _initialized إلى false).
  static void resetCache() {
    _cache.clear();
    _initialized = false;
  }

  /// يرجّع خطاً يدعم العربية إن كان النص يحتاجها، وإلا الخط اللاتيني.
  /// نوحّد الاستخدام: عند وجود عربي في أي جزء، نستخدم Cairo لكل الـ runs
  /// بما فيها اللاتينية ضمن نفس الخلية، لضمان محاذاة الأساس (baseline)
  /// والارتفاع الموحَّد بين الأجزاء المرسومة بشكل منفصل.
  static PdfFont resolve({
    required bool preferArabicFont,
    required double size,
    bool bold = false,
    bool italic = false,
    bool underline = false,
  }) {
    final double roundedSize = ((size.clamp(4, 96)) * 2).round() / 2;
    final String key =
        '${preferArabicFont ? 'ar' : 'la'}_${bold ? 1 : 0}_${italic ? 1 : 0}_${underline ? 1 : 0}_$roundedSize';

    final cached = _cache[key];
    if (cached != null) return cached;

    Uint8List? bytes;
    if (preferArabicFont) {
      bytes = bold ? (_arabicBold ?? _arabicRegular) : _arabicRegular;
    } else {
      bytes = bold ? (_latinBold ?? _latinRegular) : _latinRegular;
    }
    // fallback نهائي: لو فشل تحميل أي خط TTF، استخدم Cairo كاحتياط أخير
    bytes ??= bold ? (_arabicBold ?? _arabicRegular) : _arabicRegular;

    final styles = <PdfFontStyle>[
      if (italic) PdfFontStyle.italic,
      if (underline) PdfFontStyle.underline,
    ];

    final PdfFont font;
    if (bytes != null) {
      font = PdfTrueTypeFont(bytes, roundedSize,
          multiStyle: styles.isEmpty ? null : styles);
    } else {
      font = PdfStandardFont(PdfFontFamily.helvetica, roundedSize);
    }

    _cache[key] = font;
    return font;
  }
}

// ⚠️ ملاحظة تاريخية: كان هنا TextRun/BiDiTextLine — تقسيم نص مختلط
// (عربي+لاتيني) إلى أجزاء صافية الاتجاه، لتفادي عطل حقيقي مؤكَّد في
// Syncfusion Flutter PDF: drawString لنص مختلط دفعة واحدة كان يُسقط
// الخلية بالكامل (لا نص يُرسم إطلاقاً). بعد الانتقال لمحرك أندرويد
// الأصلي (StaticLayout عبر Minikin/HarfBuzz في NativePdfRenderer.kt)،
// أصبح هذا التقسيم اليدوي زائداً: النص المختلط يُمرَّر دفعة واحدة بترتيبه
// المنطقي، والنظام الأصلي يتولى التشكيل/الترتيب البصري بدقة كاملة.

class XlsxSheetLayout {
  final List<double> colWidths;
  final List<double> rowHeights;
  final List<List<int>> colBands;
  final List<List<int>> rowBands;

  const XlsxSheetLayout({
    required this.colWidths,
    required this.rowHeights,
    required this.colBands,
    required this.rowBands,
  });
}

class WorksheetRenderer {
  static const double _defaultRowHeight = 16.0;
  static const double _cellPadX = 3.0;
  static const double _cellPadY = 2.0;
  // أبعاد صفحة قياسية (A3 بالنقاط) — تُستخدم كحد أقصى منطقي للـ band
  // بدل أبعاد عملاقة عشوائية كانت تنتج استغلال مساحة ~2% فقط في BigData.
  static const double _maxBandWidth = 1190.0; // A3 landscape width تقريباً
  static const double _maxBandHeight = 1600.0;
  static const double _margin = 14.0;
  static const double _emuPerPoint = 12700.0; // معيار OOXML الثابت

  final WorksheetModel sheet;
  const WorksheetRenderer(this.sheet);

  XlsxSheetLayout computeLayout() {
    if (sheet.cells.isEmpty) {
      return const XlsxSheetLayout(
        colWidths: [],
        rowHeights: [],
        colBands: [[]],
        rowBands: [[]],
      );
    }

    int maxRow = 0, maxCol = 0;

    for (final entry in sheet.cells.entries) {
      final addr = entry.key;
      final cell = entry.value;

      final hasValue = cell.value != null && cell.value.toString().isNotEmpty;
      final hasBackground = cell.style.fill.background.r != 255 ||
          cell.style.fill.background.g != 255 ||
          cell.style.fill.background.b != 255;
      final hasBorder = cell.style.border.top.style != 'none' ||
          cell.style.border.bottom.style != 'none' ||
          cell.style.border.left.style != 'none' ||
          cell.style.border.right.style != 'none';

      if (hasValue || hasBackground || hasBorder) {
        if (addr.row > maxRow) maxRow = addr.row;
        if (addr.column > maxCol) maxCol = addr.column;
      }
    }

    for (final m in sheet.mergedRanges) {
      final originCell = sheet.cells[CellAddress(m.firstRow, m.firstColumn)];
      if (originCell != null &&
          originCell.value != null &&
          originCell.value.toString().isNotEmpty) {
        if (m.lastRow > maxRow) maxRow = m.lastRow;
        if (m.lastColumn > maxCol) maxCol = m.lastColumn;
      }
    }

    final colWidths = List<double>.generate(maxCol + 1, (i) {
      final w = sheet.columnWidths[i] ?? 68.0;
      return w <= 0.0 ? 0.0 : w.clamp(10.0, 500.0);
    });
    final rowHeights = List<double>.generate(maxRow + 1, (i) {
      final h = sheet.rowHeights[i] ?? _defaultRowHeight;
      return h <= 0.0 ? 0.0 : h.clamp(12.0, 500.0);
    });

    _autoFitColumns(colWidths);
    _growWrappedRows(rowHeights, colWidths);
    _growMergedRows(rowHeights, colWidths);

    final colBands = _bandIndices(colWidths, _maxBandWidth - _margin * 2);
    final rowBands = _bandIndices(rowHeights, _maxBandHeight - _margin * 2);

    return XlsxSheetLayout(
      colWidths: colWidths,
      rowHeights: rowHeights,
      colBands: colBands,
      rowBands: rowBands,
    );
  }

  void _autoFitColumns(List<double> colWidths) {
    for (final entry in sheet.cells.entries) {
      final cell = entry.value;

      if (sheet.isCoveredByMerge(entry.key.row, entry.key.column)) continue;
      if (sheet.mergeOriginAt(entry.key.row, entry.key.column) != null) {
        continue;
      }

      final text =
          NumberFormatEngine.format(cell.value, cell.numFmtId, cell.formatCode);
      if (text.isEmpty) continue;

      final font = PdfFontManager.resolve(
        preferArabicFont: hasArabic(text),
        size: cell.style.font.size,
        bold: cell.style.font.bold,
      );

      final requiredWidth = _measureSafe(font, text) + (_cellPadX * 2) + 8.0;
      final col = entry.key.column;

      if (col >= 0 && col < colWidths.length) {
        if (colWidths[col] <= 0.0) continue;
        if (requiredWidth > colWidths[col]) {
          colWidths[col] = math.min(requiredWidth, 300.0);
        }
      }
    }
  }

  // الدالة الجديدة المضافة: محرك الاحتواء التلقائي لحماية النصوص من الاقتطاع

  static List<List<int>> _bandIndices(List<double> sizes, double maxTotal) {
    final bands = <List<int>>[];
    List<int> current = [];
    double total = 0;

    for (int i = 0; i < sizes.length; i++) {
      final s = sizes[i];
      if (current.isNotEmpty && total + s > maxTotal) {
        bands.add(current);
        current = [];
        total = 0;
      }
      current.add(i);
      total += s;
    }
    if (current.isNotEmpty) bands.add(current);
    if (bands.isEmpty) bands.add([]);
    return bands;
  }

  /// يحسب ارتفاع الصف المطلوب لخلايا wrapText بالقياس الفعلي للنص
  /// (PdfFont.measureString) بدل تقدير تقريبي بمعامل ثابت غير دقيق.
  void _growWrappedRows(List<double> rowHeights, List<double> colWidths) {
    for (final entry in sheet.cells.entries) {
      final cell = entry.value;
      if (!cell.style.wrapText) continue;
      if (sheet.isCoveredByMerge(entry.key.row, entry.key.column)) continue;

      final text =
          NumberFormatEngine.format(cell.value, cell.numFmtId, cell.formatCode);
      if (text.isEmpty) continue;

      final col = entry.key.column.clamp(0, colWidths.length - 1);
      final row = entry.key.row;
      if (row < 0 || row >= rowHeights.length) continue;

      // حماية: إذا كان الصف مخفياً عمداً (ارتفاعه صفر)، تجاهل تكبيره ليبقى مخفياً
      if (rowHeights[row] <= 0.0) continue;

      // إن كانت الخلية أصل دمج، استخدم العرض الكامل للنطاق المدموج

      // إن كانت الخلية أصل دمج، استخدم العرض الكامل للنطاق المدموج
      double colWidth = colWidths[col];
      final mergeOrigin = sheet.mergeOriginAt(row, col);
      if (mergeOrigin != null) {
        colWidth = 0;
        for (int c = mergeOrigin.firstColumn;
            c <= mergeOrigin.lastColumn && c < colWidths.length;
            c++) {
          colWidth += colWidths[c];
        }
      }

      final fontSize = cell.style.font.size;
      final preferArabic = hasArabic(text);
      final font = PdfFontManager.resolve(
        preferArabicFont: preferArabic,
        size: fontSize,
        bold: cell.style.font.bold,
      );

      final availableWidth = math.max(10.0, colWidth - _cellPadX * 2);
      int totalLines = 0;
      for (final rawLine in text.split('\n')) {
        if (rawLine.isEmpty) {
          totalLines++;
          continue;
        }
        totalLines += _wrappedLineCount(rawLine, font, availableWidth);
      }

      totalLines = totalLines.clamp(1, 150);
      final needed = (totalLines * (fontSize * 1.32 + 2.5) + _cellPadY * 2 + 4)
          .clamp(0, 600);

      if (mergeOrigin != null) {
        // وزّع الارتفاع المطلوب بالتساوي عبر صفوف نطاق الدمج بدل تكديسه
        // بالكامل في الصف الأول فقط (يحافظ على توافق ارتفاعات bands).
        final rowSpan = mergeOrigin.lastRow - mergeOrigin.firstRow + 1;
        final perRow = needed / math.max(1, rowSpan);
        for (int r = mergeOrigin.firstRow;
            r <= mergeOrigin.lastRow && r < rowHeights.length;
            r++) {
          if (perRow > rowHeights[r]) rowHeights[r] = perRow;
        }
      } else {
        if (needed > rowHeights[row]) rowHeights[row] = needed.toDouble();
      }
    }
  }

  // دالة تمت إعادتها وتحسينها: مسؤولة عن حساب ارتفاع الصفوف للخلايا المدمجة التي تحتوي نصوصاً طويلة وتلتف
  void _growMergedRows(List<double> rowHeights, List<double> colWidths) {
    for (final m in sheet.mergedRanges) {
      final originCell = sheet.cells[CellAddress(m.firstRow, m.firstColumn)];
      if (originCell == null || !originCell.style.wrapText) continue;

      final text = NumberFormatEngine.format(
          originCell.value, originCell.numFmtId, originCell.formatCode);
      if (text.isEmpty) continue;

      double totalWidth = 0.0;
      for (int c = m.firstColumn; c <= m.lastColumn; c++) {
        if (c >= 0 && c < colWidths.length) {
          totalWidth += colWidths[c];
        }
      }
      if (totalWidth <= 0.0) continue;

      final font = PdfFontManager.resolve(
        preferArabicFont:hasArabic(text),
        size: originCell.style.font.size,
        bold: originCell.style.font.bold,
      );

      final availableWidth = math.max(10.0, totalWidth - _cellPadX * 2);
      final textHeight = _measureWrapHeight(font, text, availableWidth);
      final requiredHeight = textHeight + _cellPadY * 2;

      double currentHeight = 0.0;
      for (int r = m.firstRow; r <= m.lastRow; r++) {
        if (r >= 0 && r < rowHeights.length) currentHeight += rowHeights[r];
      }

      // زيادة ارتفاع الصف الأخير في النطاق المدمج لتجنب الاقتطاع (Clipping)
      if (requiredHeight > currentHeight && m.lastRow < rowHeights.length) {
        if (rowHeights[m.lastRow] > 0.0) {
          // حماية لتخطي الصفوف المخفية
          rowHeights[m.lastRow] += (requiredHeight - currentHeight);
        }
      }
    }
  }

  /// عدد الأسطر بعد التفاف نص واحد بالقياس الفعلي للخط (لا تقدير تقريبي)
  int _wrappedLineCount(String line, PdfFont font, double availableWidth) {
    if (line.isEmpty) return 1;
    final words = line.split(' ');
    int lines = 1;
    final buffer = StringBuffer();

    for (final word in words) {
      final candidate = buffer.isEmpty ? word : '${buffer.toString()} $word';
      final width = _measureSafe(font, candidate);
      if (width > availableWidth && buffer.isNotEmpty) {
        lines++;
        buffer
          ..clear()
          ..write(word);
      } else {
        buffer
          ..clear()
          ..write(candidate);
      }
    }
    return lines.clamp(1, 150);
  }

  double _measureSafe(PdfFont font, String text) {
    try {
      // إضافة هامش أمان بسيط (2.0 بكسل) لضمان عدم التفاف الكلمة أو اقتطاع حرفها الأخير
      // عند رسمها فعلياً داخل الـ bounds بواسطة محرك Syncfusion
      return font.measureString(text).width + 2.0;
    } catch (_) {
      return text.length * font.size * 0.65;
    }
  }

  // دالة مساعدة لحساب الارتفاع الكلي للنص عند التفافه داخل عرض محدد
  double _measureWrapHeight(PdfFont font, String text, double availableWidth) {
    if (text.isEmpty || availableWidth <= 0.0) return 0.0;

    double totalHeight = 0.0;
    final lineHeight = font.size * 1.25; // معامل ارتفاع السطر التقريبي

    // تقسيم النص بناءً على النزول الفعلي للسطر (Enter)
    final lines = text.split('\n');
    for (final line in lines) {
      if (line.trim().isEmpty) {
        totalHeight += lineHeight;
        continue;
      }

      // قياس عرض السطر الواحد ومقارنته بالمساحة المتاحة
      final lineWidth = _measureSafe(font, line);
      final wrapCount = (lineWidth / availableWidth).ceil();

      // إضافة ارتفاع الأسطر الملتفة
      totalHeight += (wrapCount > 0 ? wrapCount : 1) * lineHeight;
    }

    return totalHeight;
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  renderToDocSpec — يستبدل renderBands/ChartRenderer بالكامل
  //  ─────────────────────────────────────────────────────────────────────
  //  يحوّل ورقة واحدة (sheet + layout محسوبة مسبقاً) إلى قائمة PdfPageSpec
  //  (صفحة واحدة لكل band، تماماً كما كانت renderBands تُنشئ section واحداً
  //  لكل band). كل صفحة isPrecomposed (مقاس بالضبط على محتواها، لا A4
  //  قياسي) — هذا يطابق سلوك الإصدار السابق (Size(bandWidth+margin*2, ...))
  //  حرفياً. الصور والرسوم البيانية تُضاف فقط لأول band (rb=0, cb=0) كما
  //  كان الحال، عبر overlayBlocks بإحداثيات مطلقة.
  // ═══════════════════════════════════════════════════════════════════════
  List<PdfPageSpec> renderToDocSpec(XlsxSheetLayout layout) {
    if (sheet.cells.isEmpty || layout.colBands.first.isEmpty) {
      return [
        PdfPageSpec(
          widthPt: 320,
          heightPt: 100,
          blocks: [
            PdfBlockParagraph(
              runs: [
                PdfTextRun(
                  sheet.name.isEmpty ? 'ورقة بلا بيانات' : sheet.name,
                  const PdfFontSpec(family: 'Cairo', sizePt: 12, bold: true),
                )
              ],
              align: PdfTextAlign.right,
              indentStartPt: _margin,
              spaceBeforePt: _margin,
            ),
          ],
        ),
      ];
    }

    final pages = <PdfPageSpec>[];

    for (int rb = 0; rb < layout.rowBands.length; rb++) {
      for (int cb = 0; cb < layout.colBands.length; cb++) {
        final rowBand = layout.rowBands[rb];
        final colBand = layout.colBands[cb];
        if (rowBand.isEmpty || colBand.isEmpty) continue;

        final bandWidth =
            colBand.fold<double>(0, (a, i) => a + layout.colWidths[i]);
        final bandHeight =
            rowBand.fold<double>(0, (a, i) => a + layout.rowHeights[i]);

        final table = _mapBandToTable(rowBand, colBand, layout);

        final overlays = <PdfAbsoluteOverlay>[];
        if (rb == 0 && cb == 0) {
          overlays.addAll(_mapImagesToOverlays(layout));
          overlays.addAll(_mapChartsToOverlays(layout));
        }

        pages.add(PdfPageSpec(
          widthPt: bandWidth + _margin * 2,
          heightPt: bandHeight + _margin * 2,
          marginTopPt: _margin,
          marginBottomPt: _margin,
          marginLeftPt: _margin,
          marginRightPt: _margin,
          blocks: [table],
          overlayBlocks: overlays,
        ));
      }
    }

    return pages;
  }

  /// يحوّل band واحد (مجموعة صفوف × مجموعة أعمدة) إلى PdfBlockTable واحد،
  /// مع معالجة الدمج (merge) بـ colSpan/rowSpan فعليين (تحسين حقيقي عن
  /// الإصدار السابق الذي كان يرسم الدمج كمستطيل واحد منفصل عن نظام
  /// الجدول، لا كامتداد jدول حقيقي).
  PdfBlockTable _mapBandToTable(
      List<int> rowBand, List<int> colBand, XlsxSheetLayout layout) {
    // ⚠️ إصلاح حقيقي (انعكاس ترتيب الأعمدة المنطقي بدل اتجاه العرض
    // البصري فقط): كان orderedCols يعكس فعلياً ترتيب الأعمدة في القائمة
    // (colBand.reversed) عند sheet.isRtl، أي يُعيد A0 لتصبح آخر عمود في
    // القائمة المُمرَّرة لـ PdfBlockTable.rows. لكن PdfBlockTable نفسها
    // تحمل خاصية direction التي تُمرَّر بالفعل أدناه (sheet.isRtl ⇒ rtl)؛
    // drawTable في NativePdfRenderer.kt تستخدم xForCol بمنطق isRtl لقلب
    // *موضع* كل عمود بصرياً (يجعل أول عمود منطقياً يظهر على اليمين) دون
    // أي حاجة لعكس ترتيب البيانات نفسها مسبقاً من جهة Dart. عكس الترتيب
    // هنا *بالإضافة* إلى القلب البصري في drawTable يعني انعكاساً مضاعفاً:
    // العمود الأول منطقياً (مثلاً "Operating Costs | تكاليف العمليات")
    // يُحسَب كآخر عمود في القائمة، فموضعه البصري الناتج فعلياً مختلف عن
    // المتوقع، وأي ترابط نصي بين عمودين متجاورين (كالعناوين ثنائية اللغة)
    // يفقد تناسقه. الإصلاح: لا نعكس ترتيب البيانات إطلاقاً؛ نترك القلب
    // البصري بالكامل لـ direction:rtl في drawTable كما صُمم لذلك أصلاً.
    final colWidths = [for (final c in colBand) layout.colWidths[c]];

    final rows = <List<PdfTableCell>>[];
    for (final r in rowBand) {
      final rowCells = <PdfTableCell>[];
      for (final c in colBand) {
        if (sheet.isCoveredByMerge(r, c)) {
          // خلية مغطاة بدمج: لا تُضاف كخلية مستقلة — الأصل (أدناه) يحملها
          // عبر colSpan/rowSpan. لتفادي كسر شبكة الجدول (كل صف يجب أن
          // يحوي عدد خلايا يطابق المجموع المتوقع)، نُضيف خلية بعرض صفري
          // منطقياً عبر تخطّيها بالكامل — لكن جدولنا يتطلب خلية واحدة لكل
          // عمود غير مُغطّى بامتداد سابق؛ الحل: لا نُضيف شيئاً هنا لأن
          // colSpan/rowSpan في الخلية الأصل يُغطّي هذا العمود/الصف ضمن
          // حساب عرض/ارتفاع الجدول في الجسر الأصلي (انظر resolveColumnWidths
          // و measureTableHeight في NativePdfRenderer.kt التي تتعامل مع
          // colSpan فقط أفقياً ولا تدعم rowSpan فعلياً بعد — قيد v1، انظر
          // ملاحظة في القسم العلوي من هذا الملف).
          continue;
        }
        final mergeOrigin = sheet.mergeOriginAt(r, c);
        final cell = sheet.cells[CellAddress(r, c)];
        if (mergeOrigin != null) {
          final colSpan = (mergeOrigin.lastColumn - mergeOrigin.firstColumn + 1)
              .clamp(1, colBand.length);
          final rowSpan =
              (mergeOrigin.lastRow - mergeOrigin.firstRow + 1).clamp(1, 999);
          rowCells.add(_mapCell(cell, colSpan: colSpan, rowSpan: rowSpan));
        } else {
          rowCells.add(_mapCell(cell));
        }
      }
      if (rowCells.isNotEmpty) rows.add(rowCells);
    }

    return PdfBlockTable(
      rows: rows,
      columnWidthsPt: colWidths,
      direction: sheet.isRtl ? PdfTextDirection.rtl : PdfTextDirection.ltr,
    );
  }

  PdfTableCell _mapCell(CellModel? cell, {int colSpan = 1, int rowSpan = 1}) {
    if (cell == null) {
      return PdfTableCell(
        blocks: const [],
        colSpan: colSpan,
        rowSpan: rowSpan,
        edgeBorders: const PdfCellEdgeBorders(
          top: PdfBorderSpec(0.25, 0xFFEBEBEB),
          bottom: PdfBorderSpec(0.25, 0xFFEBEBEB),
          left: PdfBorderSpec(0.25, 0xFFEBEBEB),
          right: PdfBorderSpec(0.25, 0xFFEBEBEB),
        ),
      );
    }

    final style = cell.style;
    final text =
        NumberFormatEngine.format(cell.value, cell.numFmtId, cell.formatCode);

    var alignment = style.horizontalAlignment;
    if (sheet.isRtl && alignment == HorizontalAlignment.left) {
      alignment = HorizontalAlignment.right;
    }

    final paragraphs = <PdfBlockParagraph>[];
    if (text.isNotEmpty) {
      // ⚠️ إصلاح حقيقي (اتجاه النص داخل الخلايا غير محدد): كانت
      // PdfBlockParagraph تُنشأ هنا بدون تحديد direction إطلاقاً، فتبقى
      // دائماً على القيمة الافتراضية PdfTextDirection.auto بصرف النظر عن
      // محتوى الخلية الفعلي. هذا يختلف جذرياً عن docx_to_pdf_converter.dart
      // الذي يحدد direction صراحة لكل فقرة عبر فحص hasArabic على محتواها
      // (انظر mapParagraph هناك). الأثر العملي: في خلية نص مختلط (عربي+
      // لاتيني في نفس الخلية، كحال Mixed_LTR_RTL أو أي عنوان ثنائي اللغة
      // "English | عربي")، اكتشاف الاتجاه التلقائي في الجسر الأصلي
      // (StaticLayout) يعتمد على أول حرف "قوي" بالنص فقط لتحديد الاتجاه
      // الأساسي (base direction) لكل الـ run، فتنعكس أجزاء عربية ضمن
      // سياق أساسه لاتيني (أو العكس) بترتيب لا يطابق ما يتوقعه القارئ.
      // الإصلاح: نحدد direction صراحة بفحص محتوى نص الخلية نفسه (مطابقاً
      // لمنطق اختيار الخط Cairo/LiberationSans أعلاه)، فيُمرَّر اتجاه
      // أساسي صريح للجسر الأصلي بدل تركه يُخمّنه من أول حرف.
      final cellIsArabic = hasArabic(text);
      paragraphs.add(PdfBlockParagraph(
        runs: [
          PdfTextRun(
            text,
            PdfFontSpec(
              family: cellIsArabic ? 'Cairo' : 'LiberationSans',
              sizePt: style.font.size,
              bold: style.font.bold,
              italic: style.font.italic,
              underline: style.font.underline,
              colorArgb: _argbFromPdfColor(style.font.color),
            ),
          ),
        ],
        align: _mapHAlign(alignment),
        direction: cellIsArabic ? PdfTextDirection.rtl : PdfTextDirection.ltr,
      ));
    }

    final bg = style.fill.background;
    final hasBg = bg.r != 255 || bg.g != 255 || bg.b != 255;

    return PdfTableCell(
      blocks: paragraphs,
      colSpan: colSpan,
      rowSpan: rowSpan,
      backgroundColorArgb: hasBg ? _argbFromPdfColor(bg) : null,
      verticalAlign: _mapVAlign(style.verticalAlignment),
      paddingPt: _cellPadX,
      edgeBorders: PdfCellEdgeBorders(
        top: _mapBorderEdge(style.border.top),
        bottom: _mapBorderEdge(style.border.bottom),
        left: _mapBorderEdge(style.border.left),
        right: _mapBorderEdge(style.border.right),
      ),
    );
  }

  PdfBorderSpec? _mapBorderEdge(BorderEdge edge) {
    if (edge.style == 'none' || edge.width <= 0) return null;
    return PdfBorderSpec(edge.width, _argbFromPdfColor(edge.color));
  }

  PdfTextAlign _mapHAlign(HorizontalAlignment a) {
    switch (a) {
      case HorizontalAlignment.center:
        return PdfTextAlign.center;
      case HorizontalAlignment.right:
        return PdfTextAlign.right;
      case HorizontalAlignment.justify:
        return PdfTextAlign.justify;
      case HorizontalAlignment.left:
        return PdfTextAlign.left;
    }
  }

  /// PdfTextAlign مُعاد استخدامه كترميز عمودي: left=top، center=center،
  /// right=bottom (انظر تعليق PdfTableCell.verticalAlign في
  /// pdf_layout_model.dart للتفصيل الكامل لهذا الاتفاق).
  PdfTextAlign _mapVAlign(VerticalAlignment a) {
    switch (a) {
      case VerticalAlignment.top:
        return PdfTextAlign.left;
      case VerticalAlignment.bottom:
        return PdfTextAlign.right;
      case VerticalAlignment.center:
        return PdfTextAlign.center;
    }
  }

  int _argbFromPdfColor(PdfColor c) =>
      0xFF000000 | ((c.r & 0xFF) << 16) | ((c.g & 0xFF) << 8) | (c.b & 0xFF);

  List<PdfAbsoluteOverlay> _mapImagesToOverlays(XlsxSheetLayout layout) {
    final out = <PdfAbsoluteOverlay>[];
    for (final img in sheet.images) {
      try {
        final pos = _anchorToPoint(
            img.fromCol, img.fromRow, img.offsetXEmu, img.offsetYEmu, layout);
        final width = img.widthEmu / _emuPerPoint;
        final height = img.heightEmu / _emuPerPoint;
        out.add(PdfAbsoluteOverlay(
          xPt: pos.$1,
          yPt: pos.$2,
          block: PdfBlockImage(
            bytes: img.bytes,
            widthPt: width,
            heightPt: height,
          ),
        ));
      } catch (_) {
        // صورة تالفة أو بصيغة غير مدعومة — تُتجاهَل بأمان دون كسر الورقة
      }
    }
    return out;
  }

  List<PdfAbsoluteOverlay> _mapChartsToOverlays(XlsxSheetLayout layout) {
    final out = <PdfAbsoluteOverlay>[];
    for (final chart in sheet.charts) {
      try {
        final pos = _anchorToPoint(
            chart.fromCol, chart.fromRow, 0, chart.offsetYEmu, layout);
        final width = chart.widthEmu / _emuPerPoint;
        final height = chart.heightEmu / _emuPerPoint;
        out.add(PdfAbsoluteOverlay(
          xPt: pos.$1,
          yPt: pos.$2,
          block: PdfBlockChart(
            kind: _mapChartKind(chart.kind),
            title: chart.title,
            categories: chart.series.isNotEmpty
                ? chart.series.first.categories
                : const [],
            series: [
              for (final s in chart.series)
                PdfChartSeries(s.name, s.values, _argbFromPdfColor(s.color)),
            ],
            widthPt: width.clamp(80.0, 2000.0),
            heightPt: height.clamp(60.0, 1200.0),
          ),
        ));
      } catch (_) {
        // تجاهل أي خطأ في رسم رسم بياني فردي دون كسر باقي الورقة
      }
    }
    return out;
  }

  String _mapChartKind(ChartKind k) {
    switch (k) {
      case ChartKind.pie:
        return 'pie';
      case ChartKind.line:
        return 'line';
      case ChartKind.area:
        return 'area';
      case ChartKind.bar:
      case ChartKind.unknown:
        return 'bar';
    }
  }

  /// يحوّل موضع "من خلية + إزاحة EMU" إلى نقطة PDF مطلقة بحسب تخطيط
  /// الورقة. مطابق تماماً لمنطق _anchorToPoint الأصلي (نفس حساب التراكم)،
  /// لكن يُعيد Record (x, y) بدل Offset (لا حاجة لـ dart:ui بعد إزالته).
  (double, double) _anchorToPoint(
    int fromCol,
    int fromRow,
    double offsetXEmu,
    double offsetYEmu,
    XlsxSheetLayout layout,
  ) {
    double x = _margin;
    for (int c = 0; c < fromCol && c < layout.colWidths.length; c++) {
      x += layout.colWidths[c];
    }
    x += offsetXEmu / _emuPerPoint;

    double y = _margin;
    for (int r = 0; r < fromRow && r < layout.rowHeights.length; r++) {
      y += layout.rowHeights[r];
    }
    y += offsetYEmu / _emuPerPoint;

    return (x, y);
  }
}
