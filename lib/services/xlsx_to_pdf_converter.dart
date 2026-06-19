// xlsx_to_pdf_converter.dart — v4 (Comprehensive Fix)
//
// إصلاحات جذرية في هذه النسخة:
//  1. كشف RTL لكل ورقة عمل على حدة (rightToLeft من sheetView XML)
//     — السابق: rtl=true مُشفَّر لجميع الأوراق → عكس ترتيب أعمدة LTR خطأً.
//  2. تحليل عرض الأعمدة (<col>) مستقل عن ترتيب السمات
//     — السابق: regex يتطلب ترتيب min→max→width لكنّ XML يُدرج max قبل min.
//  3. تنسيق numFmt مخصص للعملات/التواريخ/النسب (numFmtId 164–173)
//     — السابق: تُعرض الأرقام الخام دون تنسيق SAR/USD/EUR/yyyy-mm-dd/%
//  4. دعم ألوان الـ theme (theme="0"=أسود, theme="1"=أبيض, …)
//     — السابق: يُعيد دائماً أسوداً مما يُخفي النص الأبيض على الخلفيات الداكنة.
//  5. قراءة defaultColWidth / defaultRowHeight من sheetFormatPr
//  6. حد أدنى لارتفاع الصفوف يكفل رسم النص في Syncfusion PDF.
//  7. WorksheetRenderer تحصل على WorkbookStyles لتنسيق الأرقام صحيحاً.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:syncfusion_flutter_pdf/pdf.dart';

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

  Future<Uint8List> convert({
    required Uint8List xlsxBytes,
    XlsxPdfOptions options = const XlsxPdfOptions(),
  }) async {
    await PdfFontManager.initialize();
    final archive = XlsxArchiveReader(xlsxBytes);
    final sharedStrings = await SharedStringsParser(archive).parse();
    final styles = await StylesParser(archive).parse();
    final workbook = await WorkbookParser(
      archive: archive,
      sharedStrings: sharedStrings,
      styles: styles,
    ).parse();

    final document = PdfDocument();
    try {
      for (final sheet in workbook.sheets) {
        final renderer = WorksheetRenderer(sheet, styles);
        final layout = renderer.computeLayout();
        renderer.renderBands(document, layout);
      }
      return Uint8List.fromList(document.saveSync());
    } finally {
      document.dispose();
      PdfFontManager.resetCache();
    }
  }

  Future<File> convertFile({required File inputFile}) async {
    final bytes = await convert(xlsxBytes: await inputFile.readAsBytes());
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
        throw const XlsxConversionException('الملف ليس بصيغة Excel (.xlsx) صحيحة.');
      }
      final names = RegExp(r'<sheet[^>]*name="([^"]+)"')
          .allMatches(workbookXml)
          .map((m) => decodeXml(m.group(1) ?? ''))
          .where((n) => n.isNotEmpty)
          .toList();
      if (names.isEmpty) {
        throw const XlsxConversionException('لم يتم العثور على أوراق عمل في الملف.');
      }
      return names.map((n) => SheetInfo(name: n, displayName: n)).toList();
    } on XlsxConversionException {
      rethrow;
    } catch (_) {
      throw const XlsxConversionException(
          'الملف تالف أو غير مدعوم — تأكد أنه ملف Excel (.xlsx) سليم.');
    }
  }

  static Future<XlsxConversionResult> convertMultipleSheets(
    File file, {
    required List<String> selectedSheetNames,
    XlsxCancelToken? cancelToken,
    void Function(XlsxConversionProgress)? onProgress,
  }) async {
    void report(double p, String stage) =>
        onProgress?.call(XlsxConversionProgress(p, stage));
    void checkCancelled() {
      if (cancelToken?.isCancelled == true) throw const XlsxCancelledException();
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
    WorkbookStyles styles = WorkbookStyles.empty();

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
        throw const XlsxConversionException('الملف ليس بصيغة Excel (.xlsx) صحيحة.');
      }

      report(0.15, 'قراءة النصوص المشتركة...');
      final sharedStrings = await SharedStringsParser(archive).parse();
      checkCancelled();

      report(0.22, 'قراءة التنسيقات...');
      styles = await StylesParser(archive).parse();
      checkCancelled();

      report(0.30, 'تحليل أوراق العمل...');
      workbook = await WorkbookParser(
        archive: archive,
        sharedStrings: sharedStrings,
        styles: styles,
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
    await PdfFontManager.initialize();
    checkCancelled();

    final document = PdfDocument();
    int totalRows = 0;
    try {
      for (int i = 0; i < sheetsToRender.length; i++) {
        checkCancelled();
        final base = 0.45 + (0.45 * i / sheetsToRender.length);
        report(base, 'رسم الورقة: ${sheetsToRender[i].name}...');

        final renderer = WorksheetRenderer(sheetsToRender[i], styles);
        final layout = renderer.computeLayout();
        totalRows += layout.rowHeights.length;
        renderer.renderBands(document, layout);
      }

      checkCancelled();
      report(0.95, 'حفظ الملف...');

      final outBytes = Uint8List.fromList(document.saveSync());
      return XlsxConversionResult(
        bytes: outBytes,
        rowCount: totalRows,
        pageCount: document.pages.count,
      );
    } on XlsxCancelledException {
      rethrow;
    } on XlsxConversionException {
      rethrow;
    } catch (e) {
      throw XlsxConversionException('تعذّر إنشاء ملف PDF: $e');
    } finally {
      document.dispose();
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
  final Map<CellAddress, CellModel> cells;
  final List<MergedRange> mergedRanges;
  final Map<int, double> rowHeights;
  final Map<int, double> columnWidths;
  final List<ImageObject> images;
  final bool isRtl;
  final double defaultColWidth;
  final double defaultRowHeight;

  WorksheetModel({
    required this.name,
    required this.cells,
    required this.mergedRanges,
    required this.rowHeights,
    required this.columnWidths,
    required this.images,
    this.isRtl = false,
    this.defaultColWidth = 64.0,
    this.defaultRowHeight = 15.0,
  });
}

class CellModel {
  final CellAddress address;
  final dynamic value;
  final String? formula;
  final CellStyleModel style;
  final int numFmtId;

  CellModel({
    required this.address,
    required this.value,
    required this.style,
    this.formula,
    this.numFmtId = 0,
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
  final double x;
  final double y;
  final double width;
  final double height;

  ImageObject({
    required this.bytes,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
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

  XlsxArchiveReader(Uint8List bytes) {
    archive = ZipDecoder().decodeBytes(bytes);
  }

  String? readText(String path) {
    try {
      final file = archive.files.firstWhere((e) => e.name == path);
      return utf8.decode(file.content as List<int>, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  Uint8List? readBytes(String path) {
    try {
      final file = archive.files.firstWhere((e) => e.name == path);
      return Uint8List.fromList(file.content as List<int>);
    } catch (_) {
      return null;
    }
  }

  bool exists(String path) => archive.files.any((e) => e.name == path);
  List<String> listFiles() => archive.files.map((e) => e.name).toList();
}

// =====================================================================
// محلّل المصنّف
// =====================================================================

class WorkbookParser {
  final XlsxArchiveReader archive;
  final List<SharedStringItem> sharedStrings;
  final WorkbookStyles styles;

  WorkbookParser({
    required this.archive,
    required this.sharedStrings,
    required this.styles,
  });

  Future<WorkbookModel> parse() async {
    final workbookXml = archive.readText('xl/workbook.xml');
    if (workbookXml == null) {
      throw const XlsxConversionException('workbook.xml غير موجود في الملف.');
    }

    final relsMap = _parseWorkbookRels();
    final sheets = <WorksheetModel>[];
    final sheetRegex =
        RegExp(r'<sheet[^>]*name="([^"]+)"[^>]*r:id="([^"]+)"');

    for (final match in sheetRegex.allMatches(workbookXml)) {
      final sheetName = decodeXml(match.group(1) ?? '');
      final rId = match.group(2) ?? '';

      String? relativePath = relsMap[rId];
      if (relativePath == null) continue;

      final fullPath = 'xl/$relativePath';
      final sheetXml = archive.readText(fullPath);
      if (sheetXml == null) continue;

      final sheet = WorksheetParser(
        archive: archive,
        sharedStrings: sharedStrings,
        styles: styles,
      ).parse(sheetName, sheetXml);

      sheets.add(sheet);
    }

    if (sheets.isEmpty) {
      int index = 1;
      for (final match in
          RegExp(r'<sheet[^>]*name="([^"]+)"').allMatches(workbookXml)) {
        final sheetName = decodeXml(match.group(1) ?? 'Sheet$index');
        final sheetPath = 'xl/worksheets/sheet$index.xml';
        final sheetXml = archive.readText(sheetPath);
        if (sheetXml != null) {
          sheets.add(WorksheetParser(
            archive: archive,
            sharedStrings: sharedStrings,
            styles: styles,
          ).parse(sheetName, sheetXml));
        }
        index++;
      }
    }

    return WorkbookModel(sheets: sheets);
  }

  Map<String, String> _parseWorkbookRels() {
    final relsXml = archive.readText('xl/_rels/workbook.xml.rels');
    if (relsXml == null) return {};

    final map = <String, String>{};
    final regex = RegExp(
        r'<Relationship[^>]*Id="([^"]+)"[^>]*Target="([^"]+)"');

    for (final match in regex.allMatches(relsXml)) {
      final id = match.group(1) ?? '';
      final target = match.group(2) ?? '';
      if (target.contains('worksheet') || target.startsWith('worksheets/')) {
        map[id] = target;
      }
    }
    return map;
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
// محلّل ورقة العمل
// =====================================================================

class WorksheetParser {
  final XlsxArchiveReader archive;
  final List<SharedStringItem> sharedStrings;
  final WorkbookStyles styles;

  WorksheetParser({
    required this.archive,
    required this.sharedStrings,
    required this.styles,
  });

  WorksheetModel parse(String name, String xml) {
    final cells = <CellAddress, CellModel>{};
    final merges = <MergedRange>[];
    final rowHeights = <int, double>{};
    final columnWidths = <int, double>{};

    // إصلاح #5: قراءة الأبعاد الافتراضية من sheetFormatPr
    final defaultColWidthStr =
        RegExp(r'defaultColWidth="([\d.]+)"').firstMatch(xml)?.group(1);
    final excelDefaultColWidth =
        double.tryParse(defaultColWidthStr ?? '') ?? 8.43;
    // تحويل وحدات Excel (حرف) إلى نقاط PDF: 1 وحدة ≈ 7pt
    final defaultColWidthPt = (excelDefaultColWidth * 7.0).clamp(20.0, 400.0);

    final defaultRowHeightStr =
        RegExp(r'defaultRowHeight="([\d.]+)"').firstMatch(xml)?.group(1);
    final defaultRowHeightPt = double.tryParse(defaultRowHeightStr ?? '') ?? 15.0;

    // إصلاح #1: كشف RTL لهذه الورقة تحديداً
    final isRtl = RegExp(r'rightToLeft="(?:1|true)"').hasMatch(xml);

    _parseRowsFast(xml, cells, rowHeights);
    _parseColumns(xml, columnWidths, excelDefaultColWidth);
    _parseMergedCells(xml, merges);

    return WorksheetModel(
      name: name,
      cells: cells,
      mergedRanges: merges,
      rowHeights: rowHeights,
      columnWidths: columnWidths,
      images: const [],
      isRtl: isRtl,
      defaultColWidth: defaultColWidthPt,
      defaultRowHeight: defaultRowHeightPt,
    );
  }

  void _parseRowsFast(
    String xml,
    Map<CellAddress, CellModel> cells,
    Map<int, double> rowHeights,
  ) {
    int pos = 0;
    final len = xml.length;

    while (pos < len) {
      final rowStart = xml.indexOf('<row', pos);
      if (rowStart == -1) break;

      final tagEnd = xml.indexOf('>', rowStart);
      if (tagEnd == -1) break;

      final openTag = xml.substring(rowStart, tagEnd + 1);

      final rowEnd = xml.indexOf('</row>', tagEnd);
      if (rowEnd == -1) break;

      final rowBody = xml.substring(tagEnd + 1, rowEnd);

      final rMatch = RegExp(r'\br="(\d+)"').firstMatch(openTag);
      if (rMatch != null) {
        final rowNum = (int.tryParse(rMatch.group(1) ?? '') ?? 1) - 1;

        final htMatch = RegExp(r'\bht="([\d.]+)"').firstMatch(openTag);
        if (htMatch != null) {
          final h = double.tryParse(htMatch.group(1) ?? '');
          if (h != null && h > 0) rowHeights[rowNum] = h;
        }

        _parseCellsFast(rowBody, rowNum, cells);
      }

      pos = rowEnd + 6;
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

      if (cStart + 2 < len) {
        final nextChar = rowXml[cStart + 2];
        if (nextChar != ' ' && nextChar != '\t' && nextChar != '\n' &&
            nextChar != '\r' && nextChar != '>') {
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

  void _processCell(String cellXml, int row, Map<CellAddress, CellModel> cells) {
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

    final numFmtId = styles.cellNumFmtIds.isNotEmpty &&
            styleIndex < styles.cellNumFmtIds.length
        ? styles.cellNumFmtIds[styleIndex]
        : 0;

    cells[CellAddress(row, column)] = CellModel(
      address: CellAddress(row, column),
      value: value,
      formula: formula,
      style: style,
      numFmtId: numFmtId,
    );
  }

  // إصلاح #2: تحليل عرض الأعمدة مستقل عن ترتيب السمات
  void _parseColumns(String xml, Map<int, double> widths, double excelDefault) {
    int pos = 0;
    while (true) {
      final start = xml.indexOf('<col', pos);
      if (start == -1) break;
      // تجنب <color> و<cols>
      if (start + 4 < xml.length) {
        final nc = xml[start + 4];
        if (nc != ' ' && nc != '\t' && nc != '\n' && nc != '\r' && nc != '/') {
          pos = start + 1;
          continue;
        }
      }

      final end = xml.indexOf('>', start);
      if (end == -1) break;
      final tag = xml.substring(start, end + 1);

      final minVal = _tagIntAttr(tag, 'min');
      final maxVal = _tagIntAttr(tag, 'max');
      final widthStr = RegExp(r'\bwidth="([\d.]+)"').firstMatch(tag)?.group(1);

      if (minVal > 0 && maxVal > 0) {
        final excelWidth =
            double.tryParse(widthStr ?? '') ?? excelDefault;
        final pdfWidth = (excelWidth * 7.0).clamp(20.0, 400.0);
        for (int c = minVal - 1; c <= maxVal - 1; c++) {
          widths[c] = pdfWidth;
        }
      }

      pos = end + 1;
    }
  }

  int _tagIntAttr(String tag, String attr) {
    return int.tryParse(
          RegExp('\\b$attr="(\\d+)"').firstMatch(tag)?.group(1) ?? '0',
        ) ??
        0;
  }

  void _parseMergedCells(String xml, List<MergedRange> merges) {
    final regex =
        RegExp(r'<mergeCell[^>]*ref="([A-Z]+)(\d+):([A-Z]+)(\d+)"');
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
// أنماط المصنّف
// =====================================================================

class WorkbookStyles {
  final List<FontStyleModel> fonts;
  final List<FillStyleModel> fills;
  final List<BorderStyleModel> borders;
  final List<CellStyleModel> cellStyles;
  final List<int> cellNumFmtIds;
  final Map<int, String> numberFormats;

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
    final (cellStyles, numFmtIds) =
        _parseCellXfs(xml, fonts, fills, borders);

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
    final fontsSection = _extractSection(xml, 'fonts');
    final regex = RegExp(r'<font>([\s\S]*?)<\/font>');

    for (final match in regex.allMatches(fontsSection)) {
      final block = match.group(1)!;
      final size = double.tryParse(
            RegExp(r'<sz val="([\d.]+)"').firstMatch(block)?.group(1) ?? '11',
          ) ??
          11;
      final family =
          RegExp(r'<name val="([^"]+)"').firstMatch(block)?.group(1) ??
              'Calibri';
      final bold = RegExp(r'<b\s*(?:val="true")?(?:\s*/)?>').hasMatch(block);
      final italic = RegExp(r'<i\s*(?:val="true")?(?:\s*/)?>').hasMatch(block);
      final underline = RegExp(r'<u\b').hasMatch(block);
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
    final regex = RegExp(r'<fill>([\s\S]*?)<\/fill>');

    for (final match in regex.allMatches(section)) {
      final block = match.group(1)!;
      final patternType =
          RegExp(r'patternType="([^"]+)"').firstMatch(block)?.group(1);

      if (patternType == null || patternType == 'none') {
        fills.add(FillStyleModel(background: PdfColor(255, 255, 255)));
        continue;
      }

      if (patternType != 'solid') {
        // أنماط غير صلبة (gray125, darkGrid, …) → رمادي فاتح
        fills.add(FillStyleModel(background: PdfColor(242, 242, 242)));
        continue;
      }

      // patternType="solid": ابحث عن fgColor أولاً ثم bgColor
      final fgRgb = RegExp(r'<fgColor[^>]*rgb="([0-9A-Fa-f]+)"')
          .firstMatch(block)
          ?.group(1);
      final fgTheme =
          RegExp(r'<fgColor[^>]*theme="(\d+)"').firstMatch(block)?.group(1);

      if (fgRgb != null) {
        fills.add(FillStyleModel(background: parseColor(fgRgb)));
      } else if (fgTheme != null) {
        fills.add(FillStyleModel(
            background: themeColor(int.tryParse(fgTheme) ?? 0)));
      } else {
        fills.add(FillStyleModel(background: PdfColor(255, 255, 255)));
      }
    }

    if (fills.isEmpty) fills.add(defaultCellStyle().fill);
    return fills;
  }

  List<BorderStyleModel> _parseBorders(String xml) {
    final borders = <BorderStyleModel>[];
    final section = _extractSection(xml, 'borders');
    final regex = RegExp(r'<border[^>]*>([\s\S]*?)<\/border>');

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

  Map<int, String> _parseNumberFormats(String xml) {
    final map = <int, String>{};
    // numFmt قد يُكتب بترتيب سمات مختلف
    final regex = RegExp(r'<numFmt\b[^>]*>');
    for (final match in regex.allMatches(xml)) {
      final tag = match.group(0)!;
      final idStr = RegExp(r'\bnumFmtId="(\d+)"').firstMatch(tag)?.group(1);
      final fmtCode =
          RegExp(r'\bformatCode="([^"]*)"').firstMatch(tag)?.group(1);
      if (idStr != null && fmtCode != null) {
        map[int.parse(idStr)] = decodeXml(fmtCode);
      }
    }
    return map;
  }

  (List<CellStyleModel>, List<int>) _parseCellXfs(
    String xml,
    List<FontStyleModel> fonts,
    List<FillStyleModel> fills,
    List<BorderStyleModel> borders,
  ) {
    final section = _extractSection(xml, 'cellXfs');
    final styles = <CellStyleModel>[];
    final numFmtIds = <int>[];

    final regex = RegExp(
        r'<xf([^>]*?)(?:\s*/>|>([\s\S]*?)<\/xf>)',
        dotAll: true);

    for (final match in regex.allMatches(section)) {
      final attrs = match.group(1) ?? '';
      final inner = match.group(2) ?? '';

      final fontId = _intAttr(attrs, 'fontId');
      final fillId = _intAttr(attrs, 'fillId');
      final borderId = _intAttr(attrs, 'borderId');
      final numFmtId = _intAttr(attrs, 'numFmtId');
      numFmtIds.add(numFmtId);

      final alignSource = inner.isNotEmpty ? '$attrs $inner' : attrs;

      styles.add(CellStyleModel(
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

    return (styles, numFmtIds);
  }

  int _intAttr(String attrs, String name) {
    return int.tryParse(
          RegExp('$name="(\\d+)"').firstMatch(attrs)?.group(1) ?? '0',
        ) ??
        0;
  }

  String _extractSection(String xml, String tag) {
    final start = xml.indexOf('<$tag');
    if (start == -1) return '';
    final end = xml.indexOf('</$tag>', start);
    if (end == -1) return '';
    return xml.substring(start, end + tag.length + 3);
  }
}

// =====================================================================
// دوال مساعدة
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
  if (type == 'b') return raw == '1' ? true : false;

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
      size: 11,
      bold: false,
      italic: false,
      underline: false,
      color: PdfColor(0, 0, 0),
    ),
    fill: FillStyleModel(background: PdfColor(255, 255, 255)),
    border: BorderStyleModel(
      left: BorderEdge(color: PdfColor(216, 216, 216), width: 0.4, style: 'thin'),
      right: BorderEdge(color: PdfColor(216, 216, 216), width: 0.4, style: 'thin'),
      top: BorderEdge(color: PdfColor(216, 216, 216), width: 0.4, style: 'thin'),
      bottom:
          BorderEdge(color: PdfColor(216, 216, 216), width: 0.4, style: 'thin'),
    ),
    horizontalAlignment: HorizontalAlignment.left,
    verticalAlignment: VerticalAlignment.center,
    wrapText: false,
  );
}

// إصلاح #4: ألوان الـ theme في Office 2007 القياسية (index → RRGGBB)
// مصدر: ملف theme1.xml المستخرج من ملف الاختبار
PdfColor themeColor(int index) {
  const colors = <int, int>{
    0: 0x000000, // dk1 – أسود
    1: 0xFFFFFF, // lt1 – أبيض
    2: 0x1F497D, // dk2 – أزرق داكن
    3: 0xEEECE1, // lt2 – بيج فاتح
    4: 0x4F81BD, // Accent1
    5: 0xC0504D, // Accent2
    6: 0x9BBB59, // Accent3
    7: 0x8064A2, // Accent4
    8: 0x4BACC6, // Accent5
    9: 0xF79646, // Accent6
  };
  final rgb = colors[index] ?? 0x000000;
  return PdfColor(
    (rgb >> 16) & 0xFF,
    (rgb >> 8) & 0xFF,
    rgb & 0xFF,
  );
}

// إصلاح #4: دعم theme= في parseFontColor
PdfColor parseFontColor(String fontXml) {
  // أولاً: جرّب rgb= صريح
  final rgb = RegExp(r'\brgb="([0-9A-Fa-f]+)"').firstMatch(fontXml);
  if (rgb != null) return parseColor(rgb.group(1));

  // ثانياً: جرّب theme=
  final theme =
      RegExp(r'\btheme="(\d+)"').firstMatch(fontXml);
  if (theme != null) return themeColor(int.tryParse(theme.group(1)!) ?? 0);

  // افتراضي: أسود
  return PdfColor(0, 0, 0);
}

PdfColor parseColor(String? value) {
  if (value == null || value.isEmpty) return PdfColor(255, 255, 255);
  String hex = value.trim();
  // إزالة الـ alpha (AARRGGBB → RRGGBB)
  if (hex.length == 8) hex = hex.substring(2);
  if (hex.length != 6) return PdfColor(255, 255, 255);
  try {
    return PdfColor(
      int.parse(hex.substring(0, 2), radix: 16),
      int.parse(hex.substring(2, 4), radix: 16),
      int.parse(hex.substring(4, 6), radix: 16),
    );
  } catch (_) {
    return PdfColor(255, 255, 255);
  }
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
  final edgeMatch =
      RegExp('<$edge([^>]*)(?:/>|>(.*?)<\\/$edge>)', dotAll: true)
          .firstMatch(borderBlock);

  if (edgeMatch == null) {
    return BorderEdge(color: PdfColor(216, 216, 216), width: 0, style: 'none');
  }

  final attrs = edgeMatch.group(1) ?? '';
  final inner = edgeMatch.group(2) ?? '';
  final style =
      RegExp(r'style="([^"]+)"').firstMatch(attrs)?.group(1) ?? 'none';

  if (style.isEmpty || style == 'none') {
    return BorderEdge(color: PdfColor(216, 216, 216), width: 0, style: 'none');
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
// تحويل أرقام تاريخ Excel (Date Serial)
// =====================================================================

bool isDateFormat(int numFmtId, String? formatCode) {
  if ((numFmtId >= 14 && numFmtId <= 17) ||
      (numFmtId >= 20 && numFmtId <= 22) ||
      (numFmtId >= 45 && numFmtId <= 47)) {
    return true;
  }
  if (formatCode != null) {
    final lower = formatCode.toLowerCase();
    // تجنب عدّ m% كتاريخ (مثل تنسيقات النسب المئوية)
    if (lower.contains('%')) return false;
    return lower.contains('yy') ||
        lower.contains('yyyy') ||
        lower.contains('mmmm') ||
        lower.contains('mmm') ||
        lower.contains('dd') ||
        (lower.contains('mm') && (lower.contains('dd') || lower.contains('yy')));
  }
  return false;
}

String excelDateToString(num serial, {String? formatCode}) {
  int days = serial.toInt();
  if (days >= 60) days--;

  final base = DateTime(1899, 12, 31);
  final date = base.add(Duration(days: days));

  // تطبيق الـ formatCode إذا أمكن
  if (formatCode != null) {
    final fmt = formatCode.toLowerCase();
    if (fmt.contains('mmmm')) {
      // تنسيق طويل مثل: dd mmmm yyyy
      const months = [
        'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'
      ];
      return '${date.day.toString().padLeft(2, '0')} '
          '${months[date.month - 1]} ${date.year}';
    }
    if (fmt.contains('yyyy') && fmt.contains('mm') && fmt.contains('dd')) {
      // تنسيق yyyy-mm-dd أو مشابه
      return '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}';
    }
  }

  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
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
    fill: FillStyleModel(background: PdfColor(230, 230, 230)),
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
  );
}

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
  static bool _fontsLoaded = false;
  static Uint8List? _arabicRegular;
  static Uint8List? _arabicBold;
  static Uint8List? _latinRegular;
  static Uint8List? _latinBold;
  static Uint8List? _latinSerifRegular;
  static Uint8List? _latinSerifBold;
  static final Map<String, PdfFont> _cache = {};

  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    Future<Uint8List?> tryLoad(String path) async {
      try {
        final data = await rootBundle.load(path);
        return data.buffer.asUint8List();
      } catch (_) {
        return null;
      }
    }

    _arabicRegular = await tryLoad('assets/fonts/Cairo-Regular.ttf');
    _arabicBold = await tryLoad('assets/fonts/Cairo-Bold.ttf');
    _latinRegular = await tryLoad('assets/fonts/LiberationSans-Regular.ttf');
    _latinBold = await tryLoad('assets/fonts/LiberationSans-Bold.ttf');
    _latinSerifRegular =
        await tryLoad('assets/fonts/LiberationSerif-Regular.ttf');
    _latinSerifBold = await tryLoad('assets/fonts/LiberationSerif-Bold.ttf');

    _fontsLoaded = _arabicRegular != null ||
        _latinRegular != null ||
        _latinSerifRegular != null;
  }

  static void resetCache() {
    _cache.clear();
    _initialized = false;
    _fontsLoaded = false;
    _arabicRegular = null;
    _arabicBold = null;
    _latinRegular = null;
    _latinBold = null;
    _latinSerifRegular = null;
    _latinSerifBold = null;
  }

  static PdfFont resolve({
    required String text,
    required double size,
    bool bold = false,
    bool italic = false,
    bool underline = false,
    String? family,
  }) {
    final bool arabic = _containsArabic(text);
    final double roundedSize = ((size.clamp(6, 72)) * 2).round() / 2;
    final bool serif =
        !arabic && family != null && _isSerifFamily(family);

    final String key =
        '${arabic ? 'ar' : (serif ? 'sf' : 'sn')}_${bold ? 1 : 0}_${italic ? 1 : 0}_${underline ? 1 : 0}_$roundedSize';

    final cached = _cache[key];
    if (cached != null) return cached;

    Uint8List? bytes;
    if (arabic) {
      bytes = bold ? (_arabicBold ?? _arabicRegular) : _arabicRegular;
    } else if (serif) {
      bytes =
          bold ? (_latinSerifBold ?? _latinSerifRegular) : _latinSerifRegular;
    } else {
      bytes = bold ? (_latinBold ?? _latinRegular) : _latinRegular;
    }

    final styles = <PdfFontStyle>[
      if (italic) PdfFontStyle.italic,
      if (underline) PdfFontStyle.underline,
    ];

    final PdfFont font;
    if (bytes != null) {
      try {
        font = PdfTrueTypeFont(bytes, roundedSize,
            multiStyle: styles.isEmpty ? null : styles);
      } catch (_) {
        font = PdfStandardFont(
            italic ? PdfFontFamily.helvetica : PdfFontFamily.helvetica,
            roundedSize);
      }
    } else {
      font = PdfStandardFont(PdfFontFamily.helvetica, roundedSize);
    }

    _cache[key] = font;
    return font;
  }

  static bool _isSerifFamily(String family) {
    final lower = family.toLowerCase();
    return lower.contains('times') ||
        lower.contains('serif') ||
        lower.contains('georgia') ||
        lower.contains('garamond') ||
        lower.contains('amiri') ||
        lower.contains('liberation serif');
  }

  static bool _containsArabic(String s) {
    for (final cp in s.runes) {
      if ((cp >= 0x0600 && cp <= 0x06FF) ||
          (cp >= 0x0750 && cp <= 0x077F) ||
          (cp >= 0xFB50 && cp <= 0xFDFF) ||
          (cp >= 0xFE70 && cp <= 0xFEFF)) {
        return true;
      }
    }
    return false;
  }
}

// =====================================================================
// محرّك العرض
// =====================================================================

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
  static const double _cellPadX = 3.0;
  static const double _cellPadY = 2.0;
  static const double _maxBandWidth = 1800.0;
  static const double _maxBandHeight = 2400.0;
  static const double _margin = 16.0;
  // إصلاح #6: الحد الأدنى لارتفاع الصف لضمان رسم النص في Syncfusion
  static const double _minRowHeight = 18.0;

  final WorksheetModel sheet;
  final WorkbookStyles styles;

  const WorksheetRenderer(this.sheet, this.styles);

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
    for (final addr in sheet.cells.keys) {
      if (addr.row > maxRow) maxRow = addr.row;
      if (addr.column > maxCol) maxCol = addr.column;
    }

    // إصلاح #5: استخدام defaultColWidth من الورقة
    final colWidths = List<double>.generate(
      maxCol + 1,
      (i) => (sheet.columnWidths[i] ?? sheet.defaultColWidth).clamp(20.0, 400.0),
    );

    // إصلاح #6: تطبيق الحد الأدنى لارتفاع الصف بعد قراءة Excel
    final rowHeights = List<double>.generate(
      maxRow + 1,
      (i) {
        final raw = sheet.rowHeights[i] ?? sheet.defaultRowHeight;
        return math.max(raw, _minRowHeight).clamp(_minRowHeight, 500.0);
      },
    );

    _growWrappedRows(rowHeights, colWidths);

    final colBands = _bandIndices(colWidths, _maxBandWidth - _margin * 2);
    final rowBands = _bandIndices(rowHeights, _maxBandHeight - _margin * 2);

    return XlsxSheetLayout(
      colWidths: colWidths,
      rowHeights: rowHeights,
      colBands: colBands,
      rowBands: rowBands,
    );
  }

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

  void _growWrappedRows(List<double> rowHeights, List<double> colWidths) {
    for (final entry in sheet.cells.entries) {
      final cell = entry.value;
      if (!cell.style.wrapText) continue;

      final text = cell.value?.toString() ?? '';
      if (text.isEmpty) continue;

      final col = entry.key.column.clamp(0, colWidths.length - 1);
      final row = entry.key.row;
      if (row < 0 || row >= rowHeights.length) continue;

      final colWidth = colWidths[col];
      final fontSize = cell.style.font.size;

      final rawLines = text.split('\n');
      int totalLines = 0;
      final isArabic = PdfFontManager._containsArabic(text);
      final charWidthFactor = isArabic ? 0.85 : 0.58;
      final charsPerLine =
          math.max(1, (colWidth / (fontSize * charWidthFactor)).floor());

      for (final line in rawLines) {
        if (line.isEmpty) {
          totalLines++;
        } else {
          totalLines += (line.length / charsPerLine).ceil().clamp(1, 200);
        }
      }

      totalLines = totalLines.clamp(1, 100);
      final needed =
          (totalLines * (fontSize + 4.0) + _cellPadY * 2 + 4).clamp(0, 800);

      if (needed > rowHeights[row]) rowHeights[row] = needed.toDouble();
    }
  }

  // إصلاح #1: renderBands تستخدم sheet.isRtl بدل المعامل العام
  void renderBands(PdfDocument document, XlsxSheetLayout layout) {
    if (sheet.cells.isEmpty || layout.colBands.first.isEmpty) {
      final section = document.sections!.add();
      section.pageSettings.size = const Size(320, 120);
      section.pageSettings.margins.all = 0;
      final page = section.pages.add();
      final label = sheet.name.isEmpty ? 'ورقة بلا بيانات' : sheet.name;
      page.graphics.drawString(
        label,
        PdfFontManager.resolve(text: label, size: 12, bold: true),
        bounds: const Rect.fromLTWH(_margin, _margin, 280, 30),
      );
      return;
    }

    for (final rowBand in layout.rowBands) {
      for (final colBand in layout.colBands) {
        final bandWidth =
            colBand.fold<double>(0, (a, i) => a + layout.colWidths[i]);
        final bandHeight =
            rowBand.fold<double>(0, (a, i) => a + layout.rowHeights[i]);

        final section = document.sections!.add();
        section.pageSettings.size =
            Size(bandWidth + _margin * 2, bandHeight + _margin * 2);
        section.pageSettings.margins.all = 0;
        final page = section.pages.add();

        _renderPage(page, rowBand, colBand, layout);
      }
    }
  }

  void _renderPage(
    PdfPage page,
    List<int> rowBand,
    List<int> colBand,
    XlsxSheetLayout layout,
  ) {
    final graphics = page.graphics;
    // إصلاح #1: عكس الأعمدة فقط للأوراق المحددة كـ RTL
    final orderedCols = sheet.isRtl ? colBand.reversed.toList() : colBand;

    double y = _margin;
    for (final r in rowBand) {
      double x = _margin;
      final rowH = layout.rowHeights[r];

      for (final c in orderedCols) {
        final colW = layout.colWidths[c];
        final cell = sheet.cells[CellAddress(r, c)];
        final bounds = Rect.fromLTWH(x, y, colW, rowH);

        if (cell != null) {
          _drawCell(graphics, cell, bounds);
        } else {
          graphics.drawRectangle(
            pen: PdfPen(PdfColor(235, 235, 235), width: 0.25),
            bounds: bounds,
          );
        }
        x += colW;
      }
      y += rowH;
    }

    for (final img in sheet.images) {
      try {
        final bitmap = PdfBitmap(img.bytes);
        graphics.drawImage(
          bitmap,
          Rect.fromLTWH(
              img.x + _margin, img.y + _margin, img.width, img.height),
        );
      } catch (_) {
        // صورة تالفة أو بصيغة غير مدعومة
      }
    }
  }

  void _drawCell(PdfGraphics g, CellModel cell, Rect bounds) {
    final style = cell.style;

    // رسم الخلفية
    g.drawRectangle(
      brush: PdfSolidBrush(style.fill.background),
      bounds: bounds,
    );
    _drawBorderEdges(g, style.border, bounds);

    final text = _formatCellValue(cell);
    if (text.isEmpty) return;

    final font = PdfFontManager.resolve(
      text: text,
      size: style.font.size,
      bold: style.font.bold,
      italic: style.font.italic,
      underline: style.font.underline,
      family: style.font.family,
    );

    final isArabicText = PdfFontManager._containsArabic(text);
    final effectiveHAlign = isArabicText && style.horizontalAlignment == HorizontalAlignment.left
        ? HorizontalAlignment.right
        : style.horizontalAlignment;

    final format = PdfStringFormat(
      alignment: _toPdfHorizontalAlignment(effectiveHAlign),
      lineAlignment: _toPdfVerticalAlignment(style.verticalAlignment),
      wordWrap:
          style.wrapText ? PdfWordWrapType.word : PdfWordWrapType.none,
      textDirection: isArabicText
          ? PdfTextDirection.rightToLeft
          : PdfTextDirection.leftToRight,
    );

    // إصلاح #6: تقليل الـ padding عند الحاجة لضمان مساحة كافية للنص
    final availH = math.max(0.0, bounds.height - _cellPadY * 2);
    final availW = math.max(0.0, bounds.width - _cellPadX * 2);
    if (availH <= 0 || availW <= 0) return;

    final textBounds = Rect.fromLTWH(
      bounds.left + _cellPadX,
      bounds.top + _cellPadY,
      availW,
      availH,
    );

    try {
      g.drawString(
        text,
        font,
        bounds: textBounds,
        format: format,
        brush: PdfSolidBrush(style.font.color),
      );
    } catch (_) {
      // في حال فشل رسم النص (خط لا يدعم الحروف) — تجاهل
    }
  }

  void _drawBorderEdges(PdfGraphics g, BorderStyleModel border, Rect bounds) {
    void drawEdge(BorderEdge edge, Offset p1, Offset p2) {
      if (edge.style == 'none' || edge.width <= 0) return;
      g.drawLine(PdfPen(edge.color, width: edge.width), p1, p2);
    }

    drawEdge(border.top, Offset(bounds.left, bounds.top),
        Offset(bounds.right, bounds.top));
    drawEdge(border.bottom, Offset(bounds.left, bounds.bottom),
        Offset(bounds.right, bounds.bottom));
    drawEdge(border.left, Offset(bounds.left, bounds.top),
        Offset(bounds.left, bounds.bottom));
    drawEdge(border.right, Offset(bounds.right, bounds.top),
        Offset(bounds.right, bounds.bottom));
  }

  // إصلاح #3: تنسيق القيم باستخدام numFmt المخصص من styles
  String _formatCellValue(CellModel cell) {
    final value = cell.value;
    if (value == null) return '';

    if (value is bool) return value ? 'TRUE' : 'FALSE';

    if (value is String) {
      return value.isEmpty ? '' : value;
    }

    if (value is num) {
      final numFmtId = cell.numFmtId;
      final customFmt = styles.numberFormats[numFmtId];

      // 1) كشف تنسيق التاريخ
      if (isDateFormat(numFmtId, customFmt) && value > 0 && value < 2958466) {
        return excelDateToString(value, formatCode: customFmt);
      }

      // 2) نسبة مئوية — مدمجة
      if (numFmtId == 9) return '${(value * 100).toStringAsFixed(0)}%';
      if (numFmtId == 10) return '${(value * 100).toStringAsFixed(2)}%';

      // 3) تنسيقات مخصصة
      if (customFmt != null && customFmt.isNotEmpty && customFmt != 'General') {
        return _applyCustomFmt(value, customFmt);
      }

      // 4) أرقام بتنسيق عملة/آلاف مدمج (numFmtId 37–44)
      if (numFmtId >= 37 && numFmtId <= 44) {
        return _formatWithThousands(value, decimals: numFmtId <= 38 ? 0 : 2);
      }

      // 5) رقم عادي
      if (value == value.roundToDouble() && value.abs() < 1e15) {
        return value.toInt().toString();
      }
      return value.toStringAsFixed(value.abs() < 1 ? 4 : 2);
    }

    return value.toString();
  }

  // إصلاح #3: تطبيق تنسيق مخصص مبسّط
  String _applyCustomFmt(num value, String fmt) {
    final lower = fmt.toLowerCase();

    // نسبة مئوية مخصصة مثل 0.00% أو 0%
    if (lower.contains('%') && !lower.contains('"')) {
      final pct = value * 100;
      if (lower.contains('0.00')) return '${pct.toStringAsFixed(2)}%';
      if (lower.contains('0.0')) return '${pct.toStringAsFixed(1)}%';
      return '${pct.toStringAsFixed(0)}%';
    }

    // تنسيق بأقواس للأرقام السالبة (#,##0.00;(#,##0.00))
    if (fmt.contains(';') && fmt.contains('(')) {
      if (value < 0) {
        return '(${_formatWithThousands(value.abs(), decimals: 2)})';
      }
      return _formatWithThousands(value, decimals: 2);
    }

    // تنسيق بفاصل آلاف + لاحقة نصية مثل #,##0.00 "SAR"
    final suffixMatch =
        RegExp(r'"([^"]+)"').firstMatch(fmt);
    final prefixMatch =
        RegExp(r'^"([^"]+)"').firstMatch(fmt);

    String numPart;
    if (lower.contains('0.00')) {
      numPart = _formatWithThousands(value, decimals: 2);
    } else if (lower.contains('0.0')) {
      numPart = _formatWithThousands(value, decimals: 1);
    } else {
      numPart = _formatWithThousands(value, decimals: 0);
    }

    if (prefixMatch != null) {
      return '${prefixMatch.group(1)}$numPart';
    }
    if (suffixMatch != null) {
      return '$numPart ${suffixMatch.group(1)!.trim()}';
    }

    return numPart;
  }

  String _formatWithThousands(num value, {int decimals = 0}) {
    final isNegative = value < 0;
    final abs = value.abs();
    final intPart = abs.toInt();
    final frac = abs - intPart;

    final intStr = intPart.toString();
    final buffer = StringBuffer();
    for (int i = 0; i < intStr.length; i++) {
      if (i > 0 && (intStr.length - i) % 3 == 0) buffer.write(',');
      buffer.write(intStr[i]);
    }

    String result = buffer.toString();
    if (decimals > 0) {
      final fracStr = (frac * math.pow(10, decimals))
          .round()
          .toString()
          .padLeft(decimals, '0');
      result += '.$fracStr';
    }
    return isNegative ? '-$result' : result;
  }

  PdfTextAlignment _toPdfHorizontalAlignment(HorizontalAlignment a) {
    switch (a) {
      case HorizontalAlignment.center:
        return PdfTextAlignment.center;
      case HorizontalAlignment.right:
        return PdfTextAlignment.right;
      case HorizontalAlignment.justify:
        return PdfTextAlignment.justify;
      case HorizontalAlignment.left:
        return PdfTextAlignment.left;
    }
  }

  PdfVerticalAlignment _toPdfVerticalAlignment(VerticalAlignment a) {
    switch (a) {
      case VerticalAlignment.top:
        return PdfVerticalAlignment.top;
      case VerticalAlignment.bottom:
        return PdfVerticalAlignment.bottom;
      case VerticalAlignment.center:
        return PdfVerticalAlignment.middle;
    }
  }
}
