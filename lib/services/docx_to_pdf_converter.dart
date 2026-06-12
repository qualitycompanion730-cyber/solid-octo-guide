import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';

class DocxConversionException implements Exception {
  final String message;
  const DocxConversionException(this.message);
}

// ─── Data models ────────────────────────────────────────────────────────────

class _Run {
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final double fontSize; // pt
  final int? colorRgb;
  const _Run({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.fontSize = 12,
    this.colorRgb,
  });
}

class _Para {
  final List<_Run> runs;
  final String style; // 'Normal','Heading1','Heading2','Heading3'
  final bool rtl;
  final String align; // 'left','right','center','both'
  const _Para({
    required this.runs,
    this.style = 'Normal',
    this.rtl = false,
    this.align = 'right',
  });

  String get text => runs.map((r) => r.text).join();
}

class _TableCell {
  final List<_Para> paragraphs;
  const _TableCell({required this.paragraphs});
  String get text => paragraphs.map((p) => p.text).join('\n');
}

class _DocTable {
  final List<List<_TableCell>> rows;
  const _DocTable({required this.rows});
}

sealed class _DocElement {}

class _ParaElement extends _DocElement {
  final _Para para;
  _ParaElement(this.para);
}

class _TableElement extends _DocElement {
  final _DocTable table;
  _TableElement(this.table);
}

class _ImageElement extends _DocElement {
  final Uint8List bytes;
  final double widthPt;
  final double heightPt;
  _ImageElement({required this.bytes, required this.widthPt, required this.heightPt});
}

// ─── Parser ─────────────────────────────────────────────────────────────────

class _DocxParser {
  final Archive archive;
  final Map<String, Uint8List> media = {};
  final Map<String, String> relationships = {}; // rId → target path

  _DocxParser(this.archive) {
    _loadMedia();
    _loadRelationships();
  }

  void _loadMedia() {
    for (final f in archive.files) {
      if (f.name.startsWith('word/media/') && f.isFile) {
        media[f.name] = Uint8List.fromList(f.content as List<int>);
      }
    }
  }

  void _loadRelationships() {
    final relsFile = archive.findFile('word/_rels/document.xml.rels');
    if (relsFile == null) return;
    final xmlStr = utf8.decode(relsFile.content as List<int>, allowMalformed: true);
    try {
      final doc = XmlDocument.parse(xmlStr);
      for (final rel in doc.findAllElements('Relationship')) {
        final id = rel.getAttribute('Id') ?? '';
        final target = rel.getAttribute('Target') ?? '';
        relationships[id] = target;
      }
    } catch (_) {}
  }

  Uint8List? _imageForRId(String rId) {
    final target = relationships[rId];
    if (target == null) return null;
    final key = target.startsWith('media/')
        ? 'word/$target'
        : 'word/media/${target.split('/').last}';
    return media[key];
  }

  List<_DocElement> parse() {
    final docFile = archive.findFile('word/document.xml');
    if (docFile == null) throw const DocxConversionException('بنية ملف docx غير صالحة');
    final xmlStr = utf8.decode(docFile.content as List<int>, allowMalformed: true);
    final doc = XmlDocument.parse(xmlStr);
    final body = doc.findAllElements('w:body').firstOrNull;
    if (body == null) throw const DocxConversionException('لم يُعثر على محتوى الملف');

    final elements = <_DocElement>[];
    for (final child in body.children) {
      if (child is! XmlElement) continue;
      switch (child.name.qualified) {
        case 'w:p':
          final el = _parsePara(child);
          // Skip completely empty paragraphs only if many consecutive
          elements.add(_ParaElement(el));
        case 'w:tbl':
          elements.add(_TableElement(_parseTable(child)));
        default:
          break;
      }
    }
    return elements;
  }

  _Para _parsePara(XmlElement pEl) {
    final pPr = pEl.findElements('w:pPr').firstOrNull;
    final styleId = pPr?.findElements('w:pStyle').firstOrNull
        ?.getAttribute('w:val') ?? 'Normal';
    final jc = pPr?.findElements('w:jc').firstOrNull
        ?.getAttribute('w:val') ?? 'right';
    final bidi = pPr?.findElements('w:bidi').firstOrNull != null;

    final runs = <_Run>[];
    for (final child in pEl.children) {
      if (child is! XmlElement) continue;
      if (child.name.qualified == 'w:r') {
        final run = _parseRun(child);
        if (run != null) runs.add(run);
      } else if (child.name.qualified == 'w:hyperlink') {
        for (final r in child.findElements('w:r')) {
          final run = _parseRun(r);
          if (run != null) runs.add(run);
        }
      } else if (child.name.qualified == 'w:ins') {
        for (final r in child.findElements('w:r')) {
          final run = _parseRun(r);
          if (run != null) runs.add(run);
        }
      }
    }

    // Detect RTL from content if not explicit
    final text = runs.map((r) => r.text).join();
    final arabicCount = RegExp(r'[؀-ۿ]').allMatches(text).length;
    final nonSpace = text.replaceAll(RegExp(r'\s'), '').length;
    final isRtl = bidi || (nonSpace > 0 && arabicCount / nonSpace > 0.3);

    final styleMap = {
      'Heading1': 'Heading1', 'heading1': 'Heading1',
      'Heading2': 'Heading2', 'heading2': 'Heading2',
      'Heading3': 'Heading3', 'heading3': 'Heading3',
      '1': 'Heading1', '2': 'Heading2', '3': 'Heading3',
    };

    return _Para(
      runs: runs,
      style: styleMap[styleId] ?? 'Normal',
      rtl: isRtl,
      align: jc,
    );
  }

  _Run? _parseRun(XmlElement rEl) {
    final rPr = rEl.findElements('w:rPr').firstOrNull;
    final buf = StringBuffer();

    for (final child in rEl.children) {
      if (child is! XmlElement) continue;
      switch (child.name.qualified) {
        case 'w:t':
          buf.write(child.innerText);
        case 'w:tab':
          buf.write('    ');
        case 'w:br':
        case 'w:cr':
          buf.write('\n');
      }
    }

    final text = buf.toString();
    if (text.isEmpty) return null;

    bool bold = rPr?.findElements('w:b').isNotEmpty ?? false;
    bool italic = rPr?.findElements('w:i').isNotEmpty ?? false;
    bool underline = rPr?.findElements('w:u').isNotEmpty ?? false;
    bool strike = rPr?.findElements('w:strike').isNotEmpty ?? false;

    double fontSize = 12;
    final szEl = rPr?.findElements('w:sz').firstOrNull;
    if (szEl != null) {
      final halfPt = double.tryParse(szEl.getAttribute('w:val') ?? '');
      if (halfPt != null) fontSize = halfPt / 2;
    }

    int? colorRgb;
    final colorEl = rPr?.findElements('w:color').firstOrNull;
    if (colorEl != null) {
      final hex = colorEl.getAttribute('w:val');
      if (hex != null && hex != 'auto' && hex.length == 6) {
        colorRgb = int.tryParse(hex, radix: 16);
      }
    }

    return _Run(
      text: text,
      bold: bold,
      italic: italic,
      underline: underline,
      strike: strike,
      fontSize: fontSize.clamp(8, 72),
      colorRgb: colorRgb,
    );
  }

  _DocTable _parseTable(XmlElement tblEl) {
    final rows = <List<_TableCell>>[];
    for (final trEl in tblEl.findElements('w:tr')) {
      final cells = <_TableCell>[];
      for (final tcEl in trEl.findElements('w:tc')) {
        final paras = tcEl.findElements('w:p').map(_parsePara).toList();
        cells.add(_TableCell(paragraphs: paras));
      }
      if (cells.isNotEmpty) rows.add(cells);
    }
    return _DocTable(rows: rows);
  }
}

// ─── PDF Renderer ────────────────────────────────────────────────────────────

class DocxToPdfConverter {
  static Uint8List? _cairoFontBytes;

  static Future<void> _ensureFont() async {
    if (_cairoFontBytes != null) return;
    try {
      final data = await rootBundle.load('assets/fonts/Cairo-Regular.ttf');
      _cairoFontBytes = data.buffer.asUint8List();
    } catch (_) {}
  }

  static Future<Uint8List> convert(File file) async {
    final bytes = await file.readAsBytes();
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const DocxConversionException('الملف تالف أو ليس ملف DOCX صالحاً');
    }

    await _ensureFont();

    final parser = _DocxParser(archive);
    final elements = parser.parse();

    return _render(elements);
  }

  static Uint8List _render(List<_DocElement> elements) {
    const pageW = 595.0;
    const pageH = 842.0;
    const marginLeft = 50.0;
    const marginRight = 50.0;
    const marginTop = 50.0;
    const marginBottom = 60.0;
    const contentW = pageW - marginLeft - marginRight;

    final doc = PdfDocument();
    doc.pageSettings.size = const Size(pageW, pageH);
    doc.pageSettings.margins.all = 0;
    doc.compressionLevel = PdfCompressionLevel.best;

    PdfPage page = doc.pages.add();
    _drawPageBg(page, pageW, pageH);
    double y = marginTop;

    PdfFont _getFont(double size, bool bold, bool italic) {
      if (_cairoFontBytes != null && !bold && !italic) {
        return PdfTrueTypeFont(_cairoFontBytes!, size);
      }
      if (bold && italic) {
        return PdfStandardFont(PdfFontFamily.helvetica, size,
            style: PdfFontStyle.boldItalic);
      } else if (bold) {
        return PdfStandardFont(PdfFontFamily.helvetica, size,
            style: PdfFontStyle.bold);
      } else if (italic) {
        return PdfStandardFont(PdfFontFamily.helvetica, size,
            style: PdfFontStyle.italic);
      }
      return PdfStandardFont(PdfFontFamily.helvetica, size);
    }

    void newPage() {
      page = doc.pages.add();
      _drawPageBg(page, pageW, pageH);
      y = marginTop;
    }

    void ensureSpace(double needed) {
      if (y + needed > pageH - marginBottom) newPage();
    }

    for (final el in elements) {
      if (el is _ParaElement) {
        final para = el.para;
        final paraText = para.text.trimRight();

        // Heading styles
        double baseFontSize = 12;
        bool isHeadingBold = false;
        if (para.style == 'Heading1') { baseFontSize = 20; isHeadingBold = true; }
        else if (para.style == 'Heading2') { baseFontSize = 16; isHeadingBold = true; }
        else if (para.style == 'Heading3') { baseFontSize = 14; isHeadingBold = true; }

        // Empty paragraph = spacing
        if (paraText.isEmpty && para.runs.isEmpty) {
          y += baseFontSize * 0.6;
          if (y > pageH - marginBottom) newPage();
          continue;
        }

        // Heading: render as single block
        if (para.style.startsWith('Heading') || para.runs.isEmpty || para.runs.length == 1) {
          final run = para.runs.isNotEmpty ? para.runs.first : null;
          final fs = run?.fontSize ?? baseFontSize;
          final bold = (run?.bold ?? false) || isHeadingBold;
          final italic = run?.italic ?? false;
          final font = _getFont(fs, bold, italic);

          final colorRgb = run?.colorRgb;
          PdfBrush brush = colorRgb != null
              ? PdfSolidBrush(PdfColor(
                  (colorRgb >> 16) & 0xFF,
                  (colorRgb >> 8) & 0xFF,
                  colorRgb & 0xFF))
              : PdfSolidBrush(PdfColor(30, 30, 30));

          final align = _pdfAlign(para.align, para.rtl);
          final fmt = PdfStringFormat(
            alignment: align,
            textDirection: para.rtl ? PdfTextDirection.rightToLeft : PdfTextDirection.leftToRight,
            lineSpacing: fs * 0.3,
          );

          final text = paraText.isEmpty ? (run?.text ?? '') : paraText;
          if (text.trim().isEmpty) continue;

          final measured = font.measureString(text,
              layoutArea: Size(contentW, double.infinity), format: fmt);
          final lineH = measured.height + fs * 0.5;

          ensureSpace(lineH);

          // Heading underline
          if (isHeadingBold) {
            page.graphics.drawLine(
              PdfPen(PdfColor(200, 200, 220), width: 0.5),
              Offset(marginLeft, y + lineH + 2),
              Offset(marginLeft + contentW, y + lineH + 2),
            );
          }

          page.graphics.drawString(
            text, font,
            brush: brush,
            bounds: Rect.fromLTWH(marginLeft, y, contentW, lineH + 10),
            format: fmt,
          );
          y += lineH + (isHeadingBold ? 8 : 4);
        } else {
          // Multi-run paragraph: render each run sequentially
          // Simplified: collect all text, apply first run's style
          final combinedText = para.runs.map((r) => r.text).join();
          if (combinedText.trim().isEmpty) continue;

          final firstRun = para.runs.first;
          final fs = firstRun.fontSize;
          final font = _getFont(fs, firstRun.bold || isHeadingBold, firstRun.italic);
          final align = _pdfAlign(para.align, para.rtl);
          final fmt = PdfStringFormat(
            alignment: align,
            textDirection: para.rtl ? PdfTextDirection.rightToLeft : PdfTextDirection.leftToRight,
            lineSpacing: fs * 0.3,
          );

          final measured = font.measureString(combinedText,
              layoutArea: Size(contentW, double.infinity), format: fmt);
          final lineH = measured.height + fs * 0.4;

          ensureSpace(lineH);

          final colorRgb = firstRun.colorRgb;
          final brush = colorRgb != null
              ? PdfSolidBrush(PdfColor(
                  (colorRgb >> 16) & 0xFF,
                  (colorRgb >> 8) & 0xFF,
                  colorRgb & 0xFF))
              : PdfSolidBrush(PdfColor(30, 30, 30));

          page.graphics.drawString(
            combinedText, font,
            brush: brush,
            bounds: Rect.fromLTWH(marginLeft, y, contentW, lineH + 10),
            format: fmt,
          );
          y += lineH + 4;
        }
      } else if (el is _TableElement) {
        final tbl = el.table;
        if (tbl.rows.isEmpty) continue;

        final colCount = tbl.rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
        if (colCount == 0) continue;
        final colW = contentW / colCount;
        const rowPad = 6.0;
        const cellFontSize = 10.0;
        final cellFont = _getFont(cellFontSize, false, false);

        for (final row in tbl.rows) {
          // Measure max height for this row
          double rowH = 24.0;
          for (final cell in row) {
            final text = cell.text;
            if (text.trim().isEmpty) continue;
            final fmt = PdfStringFormat(
              alignment: PdfTextAlignment.right,
              textDirection: PdfTextDirection.rightToLeft,
            );
            final m = cellFont.measureString(text,
                layoutArea: Size(colW - rowPad * 2, double.infinity), format: fmt);
            rowH = rowH < m.height + rowPad * 2 + 4 ? m.height + rowPad * 2 + 4 : rowH;
          }

          ensureSpace(rowH);

          // Draw row border
          page.graphics.drawRectangle(
            pen: PdfPen(PdfColor(180, 180, 200), width: 0.5),
            bounds: Rect.fromLTWH(marginLeft, y, contentW, rowH),
          );

          for (int ci = 0; ci < row.length; ci++) {
            final cellX = marginLeft + ci * colW;
            final text = row[ci].text.trim();

            // Cell separator
            if (ci > 0) {
              page.graphics.drawLine(
                PdfPen(PdfColor(180, 180, 200), width: 0.5),
                Offset(cellX, y),
                Offset(cellX, y + rowH),
              );
            }

            if (text.isNotEmpty) {
              final arabicC = RegExp(r'[؀-ۿ]').allMatches(text).length;
              final nonSp = text.replaceAll(RegExp(r'\s'), '').length;
              final rtl = nonSp > 0 && arabicC / nonSp > 0.3;
              final fmt = PdfStringFormat(
                alignment: rtl ? PdfTextAlignment.right : PdfTextAlignment.left,
                textDirection: rtl ? PdfTextDirection.rightToLeft : PdfTextDirection.leftToRight,
                lineSpacing: 2,
              );
              page.graphics.drawString(
                text, cellFont,
                brush: PdfSolidBrush(PdfColor(30, 30, 30)),
                bounds: Rect.fromLTWH(cellX + rowPad, y + rowPad, colW - rowPad * 2, rowH - rowPad * 2),
                format: fmt,
              );
            }
          }
          y += rowH;
        }
        y += 10;
      } else if (el is _ImageElement) {
        try {
          final bitmap = PdfBitmap(el.bytes);
          final imgW = el.widthPt.clamp(0, contentW);
          final imgH = el.heightPt > 0
              ? imgW * (el.heightPt / el.widthPt)
              : imgW * 0.75;

          ensureSpace(imgH + 10);
          page.graphics.drawImage(
            bitmap,
            Rect.fromLTWH(marginLeft, y, imgW, imgH),
          );
          y += imgH + 12;
        } catch (_) {}
      }
    }

    try {
      return Uint8List.fromList(doc.saveSync());
    } finally {
      doc.dispose();
    }
  }

  static void _drawPageBg(PdfPage page, double w, double h) {
    page.graphics.drawRectangle(
      brush: PdfSolidBrush(PdfColor(252, 252, 255)),
      bounds: Rect.fromLTWH(0, 0, w, h),
    );
  }

  static PdfTextAlignment _pdfAlign(String align, bool rtl) {
    switch (align) {
      case 'center': return PdfTextAlignment.center;
      case 'left': return rtl ? PdfTextAlignment.right : PdfTextAlignment.left;
      case 'right': return rtl ? PdfTextAlignment.left : PdfTextAlignment.right;
      case 'both': return PdfTextAlignment.justify;
      default: return rtl ? PdfTextAlignment.right : PdfTextAlignment.left;
    }
  }
}
