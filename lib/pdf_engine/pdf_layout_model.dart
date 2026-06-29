// ═══════════════════════════════════════════════════════════════════════════
//  pdf_layout_model.dart
//  ─────────────────────────────────────────────────────────────────────────
//  نموذج التخطيط التصريحي (Dart mirror of PdfSpecModels.kt).
//  كل كلاس هنا يطابق data class مقابله في PdfSpecModels.kt من حيث
//  مفاتيح JSON التي يتوقعها PdfSpecParser.parse() — أي تغيير في مفتاح
//  يستلزم تغييراً متزامناً في الملف الكوتليني المقابل.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:typed_data';

// ── Enums ──────────────────────────────────────────────────────────────────

enum PdfTextAlign { left, center, right, justify }

enum PdfTextDirection { auto, ltr, rtl }

enum PdfSuperSub { none, superscript, subscript }

enum PdfShapeKind {
  rectangle,
  roundedRectangle,
  oval,
  line,
  triangle,
  diamond,
  rightArrow,
  pentagon,
  hexagon,
  star,
  chevron,
}

// ── FontSpec / TextRun ─────────────────────────────────────────────────────

class PdfFontSpec {
  final String family;
  final double sizePt;
  final bool bold;
  final bool italic;
  final int colorArgb;
  final double? letterSpacing; // نسبة em (letterSpacingPt / sizePt)
  final bool underline;
  final bool strikethrough;
  final PdfSuperSub superSub;
  final int? highlightColorArgb;
  final String underlineStyle; // "single"|"double"|"wave"|"dotted"|"dashed"
  final bool strikethroughDouble;
  final String renderMode; // "normal"|"invisible"

  const PdfFontSpec({
    required this.family,
    this.sizePt = 12,
    this.bold = false,
    this.italic = false,
    this.colorArgb = 0xFF000000,
    this.letterSpacing,
    this.underline = false,
    this.strikethrough = false,
    this.superSub = PdfSuperSub.none,
    this.highlightColorArgb,
    this.underlineStyle = 'single',
    this.strikethroughDouble = false,
    this.renderMode = 'normal',
  });

  Map<String, dynamic> toJson() => {
        'family': family,
        'size': sizePt,
        'bold': bold,
        'italic': italic,
        'color': colorArgb,
        if (letterSpacing != null) 'letterSpacing': letterSpacing,
        'underline': underline,
        'strike': strikethrough,
        'superSub': superSub.name,
        if (highlightColorArgb != null) 'highlightColor': highlightColorArgb,
        'underlineStyle': underlineStyle,
        'strikeDouble': strikethroughDouble,
        if (renderMode != 'normal') 'renderMode': renderMode,
      };
}

class PdfTextRun {
  final String text;
  final PdfFontSpec font;
  final String? linkUri;
  final String? linkAnchor;

  const PdfTextRun(this.text, this.font, {this.linkUri, this.linkAnchor});

  Map<String, dynamic> toJson() => {
        'text': text,
        'font': font.toJson(),
        if (linkUri != null) 'linkUri': linkUri,
        if (linkAnchor != null) 'linkAnchor': linkAnchor,
      };
}

// ── Border helpers ─────────────────────────────────────────────────────────

class PdfBorderSpec {
  final double widthPt;
  final int colorArgb;
  const PdfBorderSpec(this.widthPt, this.colorArgb);

  Map<String, dynamic> toJson() => {'width': widthPt, 'color': colorArgb};
}

class PdfCellEdgeBorders {
  final PdfBorderSpec? top;
  final PdfBorderSpec? bottom;
  final PdfBorderSpec? left;
  final PdfBorderSpec? right;

  const PdfCellEdgeBorders({this.top, this.bottom, this.left, this.right});

  Map<String, dynamic> toJson() => {
        if (top != null) 'top': top!.toJson(),
        if (bottom != null) 'bottom': bottom!.toJson(),
        if (left != null) 'left': left!.toJson(),
        if (right != null) 'right': right!.toJson(),
      };
}

// ── Abstract block ─────────────────────────────────────────────────────────

abstract class PdfBlock {
  const PdfBlock();
  Map<String, dynamic> toJson();
}

// ── Paragraph block ────────────────────────────────────────────────────────

class PdfBlockParagraph extends PdfBlock {
  final List<PdfTextRun> runs;
  final PdfTextAlign align;
  final PdfTextDirection direction;
  final double spaceBeforePt;
  final double spaceAfterPt;
  final double lineSpacingMultiplier;
  final double indentStartPt;
  final double firstLineIndentPt;
  final int? listLevel;
  final bool listOrdered;
  final String? listMarkerOverride;
  final List<double> tabStopsPt;
  final List<String> footnotes;
  final String? bookmarkName;

  const PdfBlockParagraph({
    required this.runs,
    this.align = PdfTextAlign.left,
    this.direction = PdfTextDirection.auto,
    this.spaceBeforePt = 0,
    this.spaceAfterPt = 0,
    this.lineSpacingMultiplier = 1.15,
    this.indentStartPt = 0,
    this.firstLineIndentPt = 0,
    this.listLevel,
    this.listOrdered = false,
    this.listMarkerOverride,
    this.tabStopsPt = const [],
    this.footnotes = const [],
    this.bookmarkName,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'paragraph',
        'runs': runs.map((r) => r.toJson()).toList(),
        'align': align.name,
        'direction': direction.name,
        'spaceBefore': spaceBeforePt,
        'spaceAfter': spaceAfterPt,
        'lineSpacing': lineSpacingMultiplier,
        'indentStart': indentStartPt,
        'firstLineIndent': firstLineIndentPt,
        if (listLevel != null) 'listLevel': listLevel,
        'listOrdered': listOrdered,
        if (listMarkerOverride != null) 'listMarker': listMarkerOverride,
        if (tabStopsPt.isNotEmpty) 'tabStops': tabStopsPt,
        if (footnotes.isNotEmpty) 'footnotes': footnotes,
        if (bookmarkName != null) 'bookmarkName': bookmarkName,
      };
}

// ── Table block ────────────────────────────────────────────────────────────

class PdfTableCell {
  final List<PdfBlock> blocks;
  final int colSpan;
  final int rowSpan;
  final int? backgroundColorArgb;
  final double paddingPt;
  // PdfTextAlign re-used for vertical: left=top, center=middle, right=bottom
  final PdfTextAlign verticalAlign;
  final PdfBorderSpec? border;
  final PdfCellEdgeBorders? edgeBorders;
  final String? imageAssetRefId;
  final double? imageWidthPt;
  final double? imageHeightPt;
  // Raw bytes — NOT serialised into toJson(); collected separately by
  // NativePdfBridge.renderDocument() via the _imageAssets channel arg.
  final Uint8List? imageBytes;

  const PdfTableCell({
    required this.blocks,
    this.colSpan = 1,
    this.rowSpan = 1,
    this.backgroundColorArgb,
    this.paddingPt = 4,
    this.verticalAlign = PdfTextAlign.center,
    this.border,
    this.edgeBorders,
    this.imageAssetRefId,
    this.imageWidthPt,
    this.imageHeightPt,
    this.imageBytes,
  });

  Map<String, dynamic> toJson() => {
        'blocks': blocks.map((b) => b.toJson()).toList(),
        'colSpan': colSpan,
        'rowSpan': rowSpan,
        if (backgroundColorArgb != null) 'bgColor': backgroundColorArgb,
        'padding': paddingPt,
        'vAlign': verticalAlign.name,
        if (border != null) 'border': border!.toJson(),
        if (edgeBorders != null) 'edgeBorders': edgeBorders!.toJson(),
        if (imageAssetRefId != null) 'imageAssetRef': imageAssetRefId,
        if (imageWidthPt != null) 'imageWidth': imageWidthPt,
        if (imageHeightPt != null) 'imageHeight': imageHeightPt,
      };
}

class PdfBlockTable extends PdfBlock {
  final List<List<PdfTableCell>> rows;
  final List<double>? columnWidthsPt;
  final PdfTextDirection direction;
  final bool repeatHeaderRow;
  final PdfBorderSpec? defaultBorder;
  final PdfBorderSpec? insideHBorder;
  final PdfBorderSpec? insideVBorder;

  const PdfBlockTable({
    required this.rows,
    this.columnWidthsPt,
    this.direction = PdfTextDirection.auto,
    this.repeatHeaderRow = false,
    this.defaultBorder,
    this.insideHBorder,
    this.insideVBorder,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'table',
        'rows': rows
            .map((row) => row.map((c) => c.toJson()).toList())
            .toList(),
        if (columnWidthsPt != null) 'columnWidths': columnWidthsPt,
        'direction': direction.name,
        'repeatHeader': repeatHeaderRow,
        if (defaultBorder != null) 'defaultBorder': defaultBorder!.toJson(),
        if (insideHBorder != null) 'insideHBorder': insideHBorder!.toJson(),
        if (insideVBorder != null) 'insideVBorder': insideVBorder!.toJson(),
      };
}

// ── Image block ────────────────────────────────────────────────────────────

class PdfBlockImage extends PdfBlock {
  final Uint8List bytes;
  final double widthPt;
  final double heightPt;
  final PdfTextAlign align;
  // Stable unique key for this image — used as the key in _imageAssets and
  // as the "assetRef" value in the JSON block.
  final String assetRefId;

  static int _idCounter = 0;

  PdfBlockImage({
    required this.bytes,
    required this.widthPt,
    required this.heightPt,
    this.align = PdfTextAlign.center,
  }) : assetRefId = 'img_${_idCounter++}';

  @override
  Map<String, dynamic> toJson() => {
        'type': 'image',
        'assetRef': assetRefId,
        'width': widthPt,
        'height': heightPt,
        'align': align.name,
      };
}

// ── Page-break block ───────────────────────────────────────────────────────

class PdfBlockPageBreak extends PdfBlock {
  const PdfBlockPageBreak();

  @override
  Map<String, dynamic> toJson() => {'type': 'pageBreak'};
}

// ── Divider block ──────────────────────────────────────────────────────────

class PdfBlockDivider extends PdfBlock {
  final double thicknessPt;
  final int colorArgb;
  final double spaceBeforePt;
  final double spaceAfterPt;

  const PdfBlockDivider({
    this.thicknessPt = 1,
    this.colorArgb = 0xFF888888,
    this.spaceBeforePt = 0,
    this.spaceAfterPt = 0,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'divider',
        'thickness': thicknessPt,
        'color': colorArgb,
        'spaceBefore': spaceBeforePt,
        'spaceAfter': spaceAfterPt,
      };
}

// ── Chart block ────────────────────────────────────────────────────────────

class PdfChartSeries {
  final String name;
  final List<double> values;
  final int colorArgb;
  final List<int>? perValueColors;

  const PdfChartSeries(this.name, this.values, this.colorArgb,
      {this.perValueColors});

  Map<String, dynamic> toJson() => {
        'name': name,
        'values': values,
        'color': colorArgb,
        if (perValueColors != null) 'perValueColors': perValueColors,
      };
}

class PdfBlockChart extends PdfBlock {
  final String kind; // "bar"|"line"|"pie"
  final String title;
  final List<String> categories;
  final List<PdfChartSeries> series;
  final double widthPt;
  final double heightPt;

  const PdfBlockChart({
    required this.kind,
    required this.title,
    required this.categories,
    required this.series,
    required this.widthPt,
    required this.heightPt,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'chart',
        'kind': kind,
        'title': title,
        'categories': categories,
        'series': series.map((s) => s.toJson()).toList(),
        'width': widthPt,
        'height': heightPt,
      };
}

// ── Shape block ────────────────────────────────────────────────────────────

class PdfBlockShape extends PdfBlock {
  final PdfShapeKind kind;
  final double widthPt;
  final double heightPt;
  final int? fillColorArgb;
  final int? lineColorArgb;
  final double lineWidthPt;
  final double rotationDegrees;
  final bool flipHorizontal;
  final bool flipVertical;

  const PdfBlockShape({
    required this.kind,
    required this.widthPt,
    required this.heightPt,
    this.fillColorArgb,
    this.lineColorArgb,
    this.lineWidthPt = 0,
    this.rotationDegrees = 0,
    this.flipHorizontal = false,
    this.flipVertical = false,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'shape',
        'kind': kind.name,
        'width': widthPt,
        'height': heightPt,
        if (fillColorArgb != null) 'fillColor': fillColorArgb,
        if (lineColorArgb != null) 'lineColor': lineColorArgb,
        'lineWidth': lineWidthPt,
        if (rotationDegrees != 0) 'rotation': rotationDegrees,
        if (flipHorizontal) 'flipH': true,
        if (flipVertical) 'flipV': true,
      };
}

// ── Group block (shape + text layers, or SmartArt node) ────────────────────

class PdfBlockGroup extends PdfBlock {
  final List<PdfBlock> children;
  final double widthPt;
  final double heightPt;
  final double rotationDegrees;
  final bool flipHorizontal;
  final bool flipVertical;
  final double paddingTopPt;
  final double paddingBottomPt;
  final double paddingLeftPt;
  final double paddingRightPt;
  // PdfTextAlign re-used for vertical alignment of content inside the group:
  // left=top, center=middle, right=bottom  (matches drawGroup in Kotlin).
  final PdfTextAlign verticalContentAlign;

  const PdfBlockGroup({
    required this.children,
    required this.widthPt,
    required this.heightPt,
    this.rotationDegrees = 0,
    this.flipHorizontal = false,
    this.flipVertical = false,
    this.paddingTopPt = 0,
    this.paddingBottomPt = 0,
    this.paddingLeftPt = 0,
    this.paddingRightPt = 0,
    this.verticalContentAlign = PdfTextAlign.center,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'group',
        'children': children.map((c) => c.toJson()).toList(),
        'width': widthPt,
        'height': heightPt,
        if (rotationDegrees != 0) 'rotation': rotationDegrees,
        if (flipHorizontal) 'flipH': true,
        if (flipVertical) 'flipV': true,
        'padTop': paddingTopPt,
        'padBottom': paddingBottomPt,
        'padLeft': paddingLeftPt,
        'padRight': paddingRightPt,
        'vAlign': verticalContentAlign.name,
      };
}

// ── Page decorations ───────────────────────────────────────────────────────

class PdfPageBorder {
  final double widthPt;
  final int colorArgb;
  final bool shadow;

  const PdfPageBorder({
    required this.widthPt,
    required this.colorArgb,
    this.shadow = false,
  });

  Map<String, dynamic> toJson() => {
        'width': widthPt,
        'color': colorArgb,
        'shadow': shadow,
      };
}

class PdfWatermark {
  final String text;
  final int colorArgb;
  final double rotationDegrees;

  const PdfWatermark({
    required this.text,
    required this.colorArgb,
    this.rotationDegrees = -45,
  });

  Map<String, dynamic> toJson() => {
        'text': text,
        'color': colorArgb,
        'rotation': rotationDegrees,
      };
}

// ── Absolute overlay (positioned on top of page content) ───────────────────

class PdfAbsoluteOverlay {
  final double xPt;
  final double yPt;
  final PdfBlock block;

  const PdfAbsoluteOverlay({
    required this.xPt,
    required this.yPt,
    required this.block,
  });

  Map<String, dynamic> toJson() => {
        'x': xPt,
        'y': yPt,
        'block': block.toJson(),
      };
}

// ── Page spec ──────────────────────────────────────────────────────────────

class PdfPageSpec {
  final double widthPt;
  final double heightPt;
  final double marginTopPt;
  final double marginBottomPt;
  final double marginLeftPt;
  final double marginRightPt;
  final List<PdfBlock> blocks;
  final int? backgroundColorArgb;
  // Background full-page image (e.g. for searchable OCR PDFs).
  // The bytes themselves are NOT put in toChannelArgs() — they are collected
  // by NativePdfBridge.renderDocument() into _imageAssets using this ref ID.
  final Uint8List? backgroundImageBytes;
  final String? backgroundImageAssetRefId;
  final PdfPageBorder? pageBorder;
  final PdfWatermark? watermark;
  final List<PdfAbsoluteOverlay> overlayBlocks;
  final int columnCount;
  final double columnSpacingPt;
  final List<PdfBlock> headerBlocks;
  final List<PdfBlock> footerBlocks;
  final double headerHeightPt;
  final double footerHeightPt;

  const PdfPageSpec({
    required this.widthPt,
    required this.heightPt,
    required this.marginTopPt,
    required this.marginBottomPt,
    required this.marginLeftPt,
    required this.marginRightPt,
    required this.blocks,
    this.backgroundColorArgb,
    this.backgroundImageBytes,
    this.backgroundImageAssetRefId,
    this.pageBorder,
    this.watermark,
    this.overlayBlocks = const [],
    this.columnCount = 1,
    this.columnSpacingPt = 20,
    this.headerBlocks = const [],
    this.footerBlocks = const [],
    this.headerHeightPt = 0,
    this.footerHeightPt = 0,
  });

  Map<String, dynamic> toChannelArgs() => {
        'width': widthPt,
        'height': heightPt,
        'marginTop': marginTopPt,
        'marginBottom': marginBottomPt,
        'marginLeft': marginLeftPt,
        'marginRight': marginRightPt,
        'blocks': blocks.map((b) => b.toJson()).toList(),
        if (backgroundColorArgb != null) 'bgColor': backgroundColorArgb,
        if (backgroundImageAssetRefId != null)
          'backgroundImageAssetRef': backgroundImageAssetRefId,
        if (pageBorder != null) 'pageBorder': pageBorder!.toJson(),
        if (watermark != null) 'watermark': watermark!.toJson(),
        if (overlayBlocks.isNotEmpty)
          'overlays': overlayBlocks.map((o) => o.toJson()).toList(),
        'columnCount': columnCount,
        if (columnCount > 1) 'columnSpacing': columnSpacingPt,
        if (headerBlocks.isNotEmpty)
          'header': headerBlocks.map((b) => b.toJson()).toList(),
        if (footerBlocks.isNotEmpty)
          'footer': footerBlocks.map((b) => b.toJson()).toList(),
        if (headerHeightPt > 0) 'headerHeight': headerHeightPt,
        if (footerHeightPt > 0) 'footerHeight': footerHeightPt,
      };
}

// ── Doc spec (root) ────────────────────────────────────────────────────────

class PdfDocSpec {
  final List<PdfPageSpec> pages;
  final bool isPrecomposed;

  const PdfDocSpec({required this.pages, this.isPrecomposed = false});

  Map<String, dynamic> toChannelArgs() => {
        'isPrecomposed': isPrecomposed,
        'pages': pages.map((p) => p.toChannelArgs()).toList(),
      };
}
