// ═══════════════════════════════════════════════════════════════════════════
//  PptToPdfConverter — تحويل PPTX/ODP إلى PDF عبر الجسر الأصلي لأندرويد
//  المكتبات: archive + image + xml (تحليل) + NativePdfBridge (رسم عبر
//  Minikin/HarfBuzz/Skia الحقيقي — بديل Syncfusion الذي كان يُفسد تشكيل
//  العربي، تماماً كما شُخِّص ووُثِّق سابقاً في DOCX و XLSX).
// ═══════════════════════════════════════════════════════════════════════════
//
//  ── ملخص إعادة البناء ──────────────────────────────────────────────────
//  • التحليل (ZIP→XML→نموذج _Slide/_SlideShape/_TextParagraph/...) لم
//    يتغيّر: هذا منطق OOXML/ODP بحت لا علاقة له بمحرك الرسم.
//  • حُذف بالكامل: _SlideRenderer وكل ما فيها (رسم Syncfusion المباشر)،
//    و _buildFont/_loadFontBytes/_safeBitmap (بناء خطوط/صور Syncfusion
//    للرسم المباشر فقط — لا حاجة لها مع الجسر الأصلي).
//  • أُضيف: _mapSlidesToDocSpec(...) يحوّل List<_Slide> إلى PdfDocSpec
//    (نموذج تصريحي)، باستخدام أشكال هندسية (PdfBlockShape) ومجموعات
//    (PdfBlockGroup) جديدة أُضيفت لنموذج pdf_layout_model.dart خصيصاً
//    لدعم التموضع المطلق + الدوران/الانعكاس الذي تحتاجه شرائح PPTX
//    (بخلاف DOCX المتدفّق أو شبكة XLSX).
//  • الانعكاس (flipH/flipV) يُطبَّق عبر canvas.scale(±1) الحقيقي في
//    Android — أبسط وأدق من حيلة "إزاحة+دوران 180°" التي احتاجها
//    Syncfusion لعدم دعمه scale بقيم سالبة.
//  • التدرّج اللوني (gradient) يُرسَم عبر LinearGradient الأصلي لأندرويد
//    بدل تقسيمه يدوياً إلى 64 شريحة تقريبية كما كان ضرورياً مع Syncfusion.
//  • PPTX لا يحتاج إصلاح "rootBundle داخل Worker Isolate" الذي احتاجته
//    DOCX/XLSX: لا يوجد أي استدعاء rootBundle في هذا الملف أصلاً (الشاشة
//    كانت تُحمّل الخط في Main Isolate مسبقاً وتُمرّر مساراً على القرص) —
//    لكن إعادة البناء غيّرت هذا المسار إلى تمرير bytes مسجَّلة في الجسر
//    الأصلي مباشرة، فلا حاجة لملف مؤقت على القرص بعد الآن.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:xml/xml.dart';

import '../pdf_engine/pdf_layout_model.dart';
import 'shared/arabic_text_utils.dart';

/// بديل خفيف لصنف PdfColor من Syncfusion — يُستخدَم فقط كحاوية RGB داخل
/// نماذج التحليل، بلا أي ارتباط برسم Syncfusion الفعلي. (مطابق لنفس الشيم
/// المُستخدَم في xlsx_to_pdf_converter.dart لأغراض مماثلة.)
class PdfColor {
  final int r;
  final int g;
  final int b;
  const PdfColor(this.r, this.g, this.b);
}

// ─────────────────────────────────────────────────────────────────────────────
//  كلاسات التقدم والإلغاء والاستثناءات
// ─────────────────────────────────────────────────────────────────────────────

class PptConversionProgress {
  final double progress;
  final String stage;
  const PptConversionProgress(this.progress, this.stage);
}

class PptCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class PptConversionException implements Exception {
  final String message;
  const PptConversionException(this.message);
  @override
  String toString() => message;
}

class PptCancelledException implements Exception {
  const PptCancelledException();
  @override
  String toString() => 'تم إلغاء التحويل';
}

// ─────────────────────────────────────────────────────────────────────────────
//  إعدادات التحويل
// ─────────────────────────────────────────────────────────────────────────────

enum PptSlideLayout { fromFile, widescreen, standard, a4Portrait }

enum PptTheme { light, dark, minimal, corporate }

class PptConversionOptions {
  final PptSlideLayout slideLayout;
  final PptTheme theme;
  final int slidesPerPage;
  final bool showSlideNumbers;
  final bool showSlideThumbnailBorder;
  final bool includeNotes;
  final String?
      arabicFontPath; // NotoNaskhArabic-Regular.ttf (أو أي خط عربي Regular)
  final String?
      arabicBoldFontPath; // NotoNaskhArabic-Bold.ttf (اختياري — يُستخدم عند bold=true)
  final String? emojiFontPath;

  const PptConversionOptions({
    this.slideLayout = PptSlideLayout.fromFile,
    this.theme = PptTheme.light,
    this.slidesPerPage = 1,
    this.showSlideNumbers = false,
    this.showSlideThumbnailBorder = true,
    this.includeNotes = false,
    this.arabicFontPath,
    this.arabicBoldFontPath,
    this.emojiFontPath,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
//  نماذج الشريحة الداخلية
// ─────────────────────────────────────────────────────────────────────────────

enum _ShapeType {
  rectangle,
  roundedRectangle,
  oval,
  line,
  table,
  chart,
  triangle,
  diamond,
  rightArrow,
  pentagon,
  hexagon,
  star,
  chevron
}

enum _TextAlign { left, center, right, justify }

enum _VAlign { top, middle, bottom }

class _TextRun {
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final double fontSize;
  final String? colorHex;
  final bool rtl;
  final bool isEmoji;

  const _TextRun({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.fontSize = 14,
    this.colorHex,
    this.rtl = false,
    this.isEmoji = false,
  });
}

class _TextParagraph {
  final List<_TextRun> runs;
  final _TextAlign align;
  final double spaceBefore;
  final double spaceAfter;
  final double lineSpacingPct;
  final bool isBullet;
  final String? bulletChar;
  final bool isAutoNum;
  final int indentLevel;

  const _TextParagraph({
    required this.runs,
    this.align = _TextAlign.right,
    this.spaceBefore = 0,
    this.spaceAfter = 4,
    this.lineSpacingPct = 100,
    this.isBullet = false,
    this.bulletChar,
    this.isAutoNum = false,
    this.indentLevel = 0,
  });

  String get fullText => runs.map((r) => r.text).join();
  bool get isEmpty => fullText.trim().isEmpty;
  bool get isRtl => runs.any((r) => r.rtl);
}

// ── خلية جدول ────────────────────────────────────────────────────────────────
class _TableCell {
  final List<_TextParagraph> paragraphs;
  final String? fillHex;
  final int gridSpan;
  final int rowSpan;
  final bool hMerge;
  final bool vMerge;
  final String? borderHex;

  const _TableCell({
    required this.paragraphs,
    this.fillHex,
    this.gridSpan = 1,
    this.rowSpan = 1,
    this.hMerge = false,
    this.vMerge = false,
    this.borderHex,
  });
}

class _TableRow {
  final List<_TableCell> cells;
  final double heightEmu;
  final bool isHeader;

  const _TableRow({
    required this.cells,
    this.heightEmu = 0,
    this.isHeader = false,
  });
}

class _TableData {
  final List<_TableRow> rows;
  final List<double> colWidthsEmu;
  final String? headerFillHex;

  const _TableData({
    required this.rows,
    required this.colWidthsEmu,
    this.headerFillHex,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
//  مخططات بيانية أصلية (Native Charts) — مُستخرَجة من ppt/charts/chartN.xml
//  ─────────────────────────────────────────────────────────────────────────
//  هذا فجوة كانت موجودة في المحوّل الأصلي قبل إعادة البناء بالكامل: لم
//  يكن هناك أي استخراج لمخططات DrawingML الأصلية إطلاقاً — أي شريحة فيها
//  مخطط (بار/خطي/دائري/مساحي/مبعثر) كانت تُعرَض فارغة بصمت. المنطق هنا
//  مُقتبَس مباشرة من ChartXmlParser في xlsx_to_pdf_converter.dart (نفس
//  معيار DrawingML Chart XML بالضبط في كل من PPTX/XLSX/DOCX)، مع تكييف
//  نموذج البيانات لموضع PPTX المطلق (x/y/w/h بوحدة EMU) بدل نموذج XLSX
//  المرتبط بخلية (fromCol/fromRow).
// ─────────────────────────────────────────────────────────────────────────────

enum PptChartKind { bar, line, pie, area, scatter, unknown }

class PptChartSeries {
  final String name;
  final List<String> categories;
  final List<double> values;
  final int colorArgb;
  const PptChartSeries({
    required this.name,
    required this.categories,
    required this.values,
    required this.colorArgb,
  });
}

class PptChartObject {
  final PptChartKind kind;
  final String title;
  final List<PptChartSeries> series;
  const PptChartObject({
    required this.kind,
    required this.title,
    required this.series,
  });
}

String _decodeXmlEntities(String input) {
  return input
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

class PptChartXmlParser {
  final String xml;
  const PptChartXmlParser(this.xml);

  static const List<int> _palette = [
    0xFF4F81BD,
    0xFFC0504D,
    0xFF9BBB59,
    0xFFF6A625,
    0xFF8064A2,
    0xFF4BACC6,
  ];

  PptChartObject? parse() {
    final kind = _detectKind();
    if (kind == PptChartKind.unknown) return null;

    final title = _extractTitle();
    final series = kind == PptChartKind.pie
        ? _extractPieSeries()
        : _extractCartesianSeries();

    if (series.isEmpty) return null;

    return PptChartObject(kind: kind, title: title, series: series);
  }

  PptChartKind _detectKind() {
    if (xml.contains('<c:barChart')) return PptChartKind.bar;
    if (xml.contains('<c:lineChart')) return PptChartKind.line;
    if (xml.contains('<c:pieChart') || xml.contains('<c:pie3DChart')) {
      return PptChartKind.pie;
    }
    if (xml.contains('<c:areaChart')) return PptChartKind.area;
    // ⚠️ إضافة حقيقية: c:scatterChart لم يكن مدعوماً إطلاقاً (لا في PPTX
    // ولا حتى في XLSX الأصلية). نُعامله كخط (line) بصرياً في الرسم النهائي
    // لأن جسرنا لا يملك راسماً مخصصاً للنقاط المبعثرة بعد — تقريب معقول
    // إذ غالب مخططات scatter في العروض التقديمية تُستخدَم لخط اتجاه مرسوم
    // كسلسلة بيانات ثانية محسوبة (Trendline)، وهي بطبيعتها نقاط متصلة.
    if (xml.contains('<c:scatterChart')) return PptChartKind.scatter;
    return PptChartKind.unknown;
  }

  String _extractTitle() {
    final titleBlock = _extractSection(xml, 'c:title');
    if (titleBlock.isEmpty) return '';
    final texts = RegExp(r'<a:t>([^<]*)<\/a:t>').allMatches(titleBlock);
    return texts.map((m) => _decodeXmlEntities(m.group(1) ?? '')).join();
  }

  List<PptChartSeries> _extractCartesianSeries() {
    final result = <PptChartSeries>[];
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
      // مخططات scatter تستخدم c:yVal للقيم وc:xVal للفئات (لا c:val/c:cat
      // كباقي الأنواع) — نتحقق من كليهما.
      final values = _extractNumCache(block, 'c:val').isNotEmpty
          ? _extractNumCache(block, 'c:val')
          : _extractNumCache(block, 'c:yVal');
      final rgb =
          _extractSeriesArgb(block) ?? _palette[colorIdx % _palette.length];
      colorIdx++;

      if (values.isNotEmpty) {
        result.add(PptChartSeries(
          name: name,
          categories: categories,
          values: values,
          colorArgb: rgb,
        ));
      }
    }
    return result;
  }

  List<PptChartSeries> _extractPieSeries() {
    final result = <PptChartSeries>[];
    final start = xml.indexOf('<c:ser>');
    if (start == -1) return result;
    final end = xml.indexOf('</c:ser>', start);
    if (end == -1) return result;
    final block = xml.substring(start, end + 8);

    final categories = _extractStrCache(block, 'c:cat');
    final values = _extractNumCache(block, 'c:val');
    final name = _extractSeriesName(block);

    if (values.isNotEmpty) {
      result.add(PptChartSeries(
        name: name,
        categories: categories,
        values: values,
        colorArgb: 0xFF4F81BD,
      ));
    }
    return result;
  }

  String _extractSeriesName(String serBlock) {
    final txBlock = _extractSection(serBlock, 'c:tx');
    final m = RegExp(r'<c:v>([^<]*)<\/c:v>').firstMatch(txBlock);
    return _decodeXmlEntities(m?.group(1) ?? '');
  }

  int? _extractSeriesArgb(String serBlock) {
    final spPr = _extractSection(serBlock, 'c:spPr');
    final m = RegExp(r'srgbClr val="([0-9A-Fa-f]{6})"').firstMatch(spPr);
    if (m == null) return null;
    return 0xFF000000 | int.parse(m.group(1)!, radix: 16);
  }

  List<String> _extractStrCache(String block, String tag) {
    final section = _extractSection(block, tag);
    if (section.isEmpty) return [];
    final pts = RegExp(r'<c:pt[^>]*idx="(\d+)"[^>]*>\s*<c:v>([^<]*)<\/c:v>')
        .allMatches(section)
        .toList();
    if (pts.isEmpty) return [];
    final maxIdx = pts.map((m) => int.parse(m.group(1)!)).reduce(math.max);
    final result = List<String>.filled(maxIdx + 1, '');
    for (final m in pts) {
      final idx = int.parse(m.group(1)!);
      result[idx] = _decodeXmlEntities(m.group(2) ?? '');
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

class _SlideShape {
  final double x, y, w, h;
  final _ShapeType type;
  final String? fillHex;
  final String? lineHex;
  final double lineWidth;
  final List<_TextParagraph> paragraphs;
  final _VAlign vAlign;
  final bool isTitle;
  final bool isSubtitle;
  // padding داخلي بوحدة EMU
  final double tIns, bIns, lIns, rIns;
  final Uint8List? imageBytes;
  final _TableData? tableData;
  final PptChartObject? chartData;
  // دوران (بـ 1/60000 درجة)
  final int rot;
  final bool flipH;
  final bool flipV;

  const _SlideShape({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.type = _ShapeType.rectangle,
    this.fillHex,
    this.lineHex,
    this.lineWidth = 0,
    this.paragraphs = const [],
    this.vAlign = _VAlign.top,
    this.isTitle = false,
    this.isSubtitle = false,
    this.tIns = 45720,
    this.bIns = 45720,
    this.lIns = 91440,
    this.rIns = 91440,
    this.imageBytes,
    this.tableData,
    this.chartData,
    this.rot = 0,
    this.flipH = false,
    this.flipV = false,
  });
}

class _SlideBackground {
  final String? colorHex;
  final Uint8List? imageBytes;
  final bool hasGradient;
  final List<_GradStop> gradStops;
  final bool isVerticalGrad;
  final bool isTransparent;

  const _SlideBackground({
    this.colorHex,
    this.imageBytes,
    this.hasGradient = false,
    this.gradStops = const [],
    this.isVerticalGrad = true,
    this.isTransparent = false,
  });
}

class _GradStop {
  final double pos;
  final String colorHex;
  const _GradStop(this.pos, this.colorHex);
}

class _Slide {
  final List<_SlideShape> shapes;
  final _SlideBackground background;
  final String? notes;
  final int slideIndex;

  const _Slide({
    required this.shapes,
    required this.background,
    this.notes,
    required this.slideIndex,
  });

  String get title {
    for (final s in shapes) {
      if (s.isTitle && s.paragraphs.isNotEmpty) {
        final t = s.paragraphs.first.fullText.trim();
        if (t.isNotEmpty) return t;
      }
    }
    for (final s in shapes) {
      for (final p in s.paragraphs) {
        if (!p.isEmpty) return p.fullText.trim();
      }
    }
    return 'شريحة $slideIndex';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  أبعاد الشريحة من ملف PPTX
// ─────────────────────────────────────────────────────────────────────────────

class _PresentationSize {
  final double cxEmu;
  final double cyEmu;

  const _PresentationSize(this.cxEmu, this.cyEmu);

  // 1 pt = 12700 EMU في Office Open XML
  // cx=عرض الشريحة (البُعد الأفقي)، cy=ارتفاع الشريحة (البُعد الرأسي)
  // Syncfusion PdfDocument.pageSettings.size = Size(width, height) — نمرّر cx→width، cy→height
  double get widthPt => cxEmu / 12700;
  double get heightPt => cyEmu / 12700;

  // وضع 16:9 الافتراضي: 10 بوصة × 7.5 بوصة بدقة 914400 EMU/بوصة
  static const _PresentationSize _default = _PresentationSize(9144000, 5143500);

  static _PresentationSize parse(_ArchiveCache cache) {
    final f = cache.findFile('ppt/presentation.xml');
    if (f == null) return _default;
    try {
      final doc = XmlDocument.parse(utf8.decode(f.content as List<int>));
      // البحث بالاسم المحلي لتجاوز اختلافات namespace prefixes
      final sldSz = doc.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'sldSz')
          .firstOrNull;
      if (sldSz != null) {
        final cx = double.tryParse(sldSz.getAttribute('cx') ?? '') ?? 9144000;
        final cy = double.tryParse(sldSz.getAttribute('cy') ?? '') ?? 5143500;
        if (cx > 0 && cy > 0) return _PresentationSize(cx, cy);
      }
    } catch (_) {}
    return _default;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  cache للـ archive لتسريع البحث (O(1) بدلاً من O(n))
// ─────────────────────────────────────────────────────────────────────────────

class _ArchiveCache {
  final Archive _archive;
  final Map<String, ArchiveFile?> _cache = {};

  _ArchiveCache(this._archive);

  ArchiveFile? findFile(String path) {
    return _cache.putIfAbsent(path, () {
      // بحث مباشر
      for (final f in _archive.files) {
        if (f.isFile && f.name == path) return f;
      }
      // بحث case-insensitive
      final lower = path.toLowerCase();
      for (final f in _archive.files) {
        if (f.isFile && f.name.toLowerCase() == lower) return f;
      }
      return null;
    });
  }

  Iterable<ArchiveFile> get files => _archive.files;
}

// ─────────────────────────────────────────────────────────────────────────────
//  دوال مساعدة
// ─────────────────────────────────────────────────────────────────────────────



bool _hasEmoji(String s) {
  for (final cu in s.runes) {
    if ((cu >= 0x1F300 && cu <= 0x1FAFF) ||
        (cu >= 0x2600 && cu <= 0x27BF) ||
        (cu >= 0x1F000 && cu <= 0x1F02F) ||
        (cu >= 0x1F0A0 && cu <= 0x1F0FF) ||
        (cu >= 0x1FA00 && cu <= 0x1FA6F)) {
      return true;
    }
  }
  return false;
}

String _attr(XmlElement el, String name, {String fallback = ''}) =>
    el.getAttribute(name) ?? fallback;

/// تحويل EMU → pt (1 pt = 12700 EMU)
double _emuToPt(double emu) => emu / 12700;

PdfColor _hexColor(String? hex, {PdfColor? fallback}) {
  if (hex == null || hex.isEmpty) return fallback ?? const PdfColor(0, 0, 0);
  final h = hex.replaceAll('#', '').trim();
  if (h.length < 6) return fallback ?? const PdfColor(0, 0, 0);
  try {
    // ⚠️ إصلاح: hex قد يصل بصيغة AARRGGBB (8 خانات) إن حملت شفافية صريحة
    // (راجع _extractColor) — يجب قراءة جزء RGB من الإزاحة الصحيحة (آخر 6
    // خانات)، لا أول 6 خانات دائماً (كان هذا يقرأ بايت الشفافية كجزء من
    // الأحمر فيُنتج لوناً تالفاً كلياً لأي لون فيه شفافية صريحة).
    final rgbPart =
        h.length >= 8 ? h.substring(h.length - 6) : h.substring(0, 6);
    final v = int.parse(rgbPart, radix: 16);
    return PdfColor((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
  } catch (_) {
    return fallback ?? const PdfColor(0, 0, 0);
  }
}

/// يستخرج بايت الشفافية (0-255) من hex بصيغة AARRGGBB (8 خانات)، أو 255
/// (معتم بالكامل) إن كان الـ hex بصيغة RRGGBB العادية (6 خانات، بلا
/// شفافية صريحة) أو null.
int _extractAlphaByte(String? hex) {
  if (hex == null) return 255;
  final h = hex.replaceAll('#', '').trim();
  if (h.length < 8) return 255;
  try {
    return int.parse(h.substring(0, 2), radix: 16);
  } catch (_) {
    return 255;
  }
}

/// تطبيق lumMod/lumOff: القيم بوحدة 100000 (100000 = 100%)
String _applyLumMod(String hex, int lumMod, int lumOff) {
  if (hex.length < 6) return hex;
  try {
    final v = int.parse(hex.substring(0, 6), radix: 16);
    int r = (v >> 16) & 0xFF;
    int g = (v >> 8) & 0xFF;
    int b = v & 0xFF;
    final mod = lumMod / 100000.0;
    final off = lumOff / 100000.0;
    r = (r * mod + off * 255).round().clamp(0, 255);
    g = (g * mod + off * 255).round().clamp(0, 255);
    b = (b * mod + off * 255).round().clamp(0, 255);
    return '${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
  } catch (_) {
    return hex;
  }
}

String _applyShade(String hex, int shade) {
  final factor = shade / 100000.0;
  return _applyLumMod(hex, (factor * 100000).round(), 0);
}

String _applyTint(String hex, int tint) {
  final factor = tint / 100000.0;
  if (hex.length < 6) return hex;
  try {
    final v = int.parse(hex.substring(0, 6), radix: 16);
    int r = (v >> 16) & 0xFF;
    int g = (v >> 8) & 0xFF;
    int b = v & 0xFF;
    r = (r + (255 - r) * factor).round().clamp(0, 255);
    g = (g + (255 - g) * factor).round().clamp(0, 255);
    b = (b + (255 - b) * factor).round().clamp(0, 255);
    return '${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
  } catch (_) {
    return hex;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  تطبيع الصور: PdfBitmap يقبل PNG/JPEG فقط — نحوّل بقية الصيغ النقطية إلى PNG
//  ونتخطى الصيغ المتجهة (EMF/WMF) التي لا يدعمها فك التشفير النقطي.
// ─────────────────────────────────────────────────────────────────────────────

/// كاش لتفادي إعادة فك تشفير نفس الصورة عدة مرات (مفتاح = identityHashCode للبايتات)
final Map<int, Uint8List?> _normalizedImageCache = {};

/// كشف نوع الصورة من الـ magic bytes (أكثر موثوقية من الامتداد)
String _detectImageFormat(Uint8List b) {
  if (b.length < 12) return 'unknown';
  // PNG: 89 50 4E 47
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return 'png';
  }
  // JPEG: FF D8 FF
  if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'jpeg';
  // GIF: 47 49 46
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return 'gif';
  // BMP: 42 4D
  if (b[0] == 0x42 && b[1] == 0x4D) return 'bmp';
  // WEBP: RIFF....WEBP
  if (b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'webp';
  }
  // TIFF: 49 49 2A 00  أو  4D 4D 00 2A
  if ((b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A) ||
      (b[0] == 0x4D && b[1] == 0x4D && b[3] == 0x2A)) {
    return 'tiff';
  }
  // EMF: 01 00 00 00 ... ' EMF' عند الإزاحة 40
  if (b.length > 43 &&
      b[40] == 0x20 &&
      b[41] == 0x45 &&
      b[42] == 0x4D &&
      b[43] == 0x46) {
    return 'emf';
  }
  // WMF: D7 CD C6 9A  أو  01 00 09 00
  if ((b[0] == 0xD7 && b[1] == 0xCD) ||
      (b[0] == 0x01 && b[1] == 0x00 && b[2] == 0x09 && b[3] == 0x00)) {
    return 'wmf';
  }
  return 'unknown';
}

/// يُرجع بايتات صورة مقبولة من PdfBitmap (PNG أو JPEG)، أو null إن تعذّر.
/// PNG/JPEG تمرّ كما هي؛ GIF/BMP/WEBP/TIFF تُفكّ وتُعاد ترميزها PNG؛ EMF/WMF تُتخطّى.
Uint8List? _normalizeImageForPdf(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  final key = identityHashCode(bytes);
  if (_normalizedImageCache.containsKey(key)) return _normalizedImageCache[key];

  Uint8List? result;
  final fmt = _detectImageFormat(bytes);
  switch (fmt) {
    case 'png':
    case 'jpeg':
      result = bytes; // مدعومة مباشرةً
      break;
    case 'emf':
    case 'wmf':
      result = null; // صيغ متجهة — لا يمكن تحويلها هنا، تُتخطّى بأمان
      break;
    case 'gif':
    case 'bmp':
    case 'webp':
    case 'tiff':
    default:
      // محاولة فك التشفير العام ثم إعادة الترميز PNG
      try {
        final decoded = img.decodeImage(bytes);
        if (decoded != null) {
          result = Uint8List.fromList(img.encodePng(decoded));
        }
      } catch (_) {
        result = null;
      }
  }

  _normalizedImageCache[key] = result;
  return result;
}

// ⚠️ ملاحظة تاريخية: كان هنا _loadFontBytes و _buildFont (بناء خطوط
// Syncfusion للرسم المباشر فقط). حُذفا بالكامل بعد الانتقال للجسر الأصلي
// (NativePdfRenderer.kt) الذي يرسم النص عبر StaticLayout/HarfBuzz — لا
// حاجة لبناء PdfFont/PdfTrueTypeFont إطلاقاً بعد الآن.

// ─────────────────────────────────────────────────────────────────────────────
//  ألوان Theme من theme1.xml
// ─────────────────────────────────────────────────────────────────────────────

class _PptThemeColors {
  final Map<String, String> _map;
  const _PptThemeColors(this._map);
  static _PptThemeColors empty() => const _PptThemeColors({});

  /// حل schemeClr مع تطبيق المعدِّلات كاملةً
  String? resolveWithMods(String? name, XmlElement? schemeClrEl) {
    if (name == null) return null;

    // دعم تعيين clrMap: dk1→tx1 وما إلى ذلك
    final mapped = _clrMapAliases[name] ?? name;
    String? base = _map[name] ?? _map[mapped];
    if (base == null) return null;
    if (schemeClrEl == null) return base;

    String result = base;
    int lumMod = 100000, lumOff = 0, shade = 100000, tint = 0;
    bool hasMod = false;

    for (final child in schemeClrEl.childElements) {
      final tag = child.name.local;
      final val = int.tryParse(_attr(child, 'val')) ?? 0;
      switch (tag) {
        case 'lumMod':
          lumMod = val;
          hasMod = true;
          break;
        case 'lumOff':
          lumOff = val;
          hasMod = true;
          break;
        case 'shade':
          shade = val;
          hasMod = true;
          break;
        case 'tint':
          tint = val;
          hasMod = true;
          break;
        // alpha لا يؤثر على اللون نفسه هنا
      }
    }

    if (!hasMod) return result;
    if (lumMod != 100000 || lumOff != 0) {
      result = _applyLumMod(result, lumMod, lumOff);
    }
    if (shade != 100000) result = _applyShade(result, shade);
    if (tint != 0) result = _applyTint(result, tint);
    return result;
  }

  String? resolve(String? name) {
    if (name == null) return null;
    return _map[name] ?? _map[_clrMapAliases[name] ?? name];
  }

  // خريطة الأسماء البديلة الشائعة في clrMap
  static const _clrMapAliases = <String, String>{
    'tx1': 'dk1',
    'tx2': 'dk2',
    'bg1': 'lt1',
    'bg2': 'lt2',
    'dk1': 'dk1',
    'dk2': 'dk2',
    'lt1': 'lt1',
    'lt2': 'lt2',
  };

  static _PptThemeColors parse(_ArchiveCache cache) {
    final f = cache.findFile('ppt/theme/theme1.xml');
    if (f == null) return empty();
    try {
      final doc = XmlDocument.parse(utf8.decode(f.content as List<int>));
      final map = <String, String>{};

      for (final clrScheme in doc.findAllElements('a:clrScheme')) {
        for (final child in clrScheme.childElements) {
          final name = child.name.local;
          for (final colorEl in child.childElements) {
            final tag = colorEl.name.local;
            if (tag == 'srgbClr') {
              map[name] = _attr(colorEl, 'val');
            } else if (tag == 'sysClr') {
              final lc = _attr(colorEl, 'lastClr');
              if (lc.isNotEmpty) map[name] = lc;
            }
          }
        }
      }
      return _PptThemeColors(map);
    } catch (_) {
      return empty();
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  المحلل (Parser) — PPTX
// ─────────────────────────────────────────────────────────────────────────────

class _PptxParser {
  final _ArchiveCache _cache;
  final Map<String, Uint8List> _images = {};
  late final _PptThemeColors _themeColors;
  late final _PresentationSize _presSize;

  final Map<String, _SlideBackground> _layoutBgCache = {};
  final Map<String, _SlideBackground> _masterBgCache = {};

  _PptxParser(this._cache);

  void _loadImages() {
    for (final f in _cache.files) {
      if (!f.isFile) continue;
      final name = f.name.toLowerCase();
      if (name.contains('media/') &&
          (name.endsWith('.png') ||
              name.endsWith('.jpg') ||
              name.endsWith('.jpeg') ||
              name.endsWith('.gif') ||
              name.endsWith('.bmp') ||
              name.endsWith('.webp') ||
              name.endsWith('.emf') ||
              name.endsWith('.wmf'))) {
        _images[f.name] = f.content as Uint8List;
      }
    }
  }

  Uint8List? _findImage(String path) {
    Uint8List? b = _images[path];
    if (b != null) return b;
    final lower = path.toLowerCase();
    for (final e in _images.entries) {
      if (e.key.toLowerCase() == lower) return e.value;
    }
    return null;
  }

  Map<String, String> _readRels(String filePath) {
    final parts = filePath.split('/');
    final dir =
        parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : '';
    final file = parts.last;
    final relPath =
        dir.isNotEmpty ? '$dir/_rels/$file.rels' : '_rels/$file.rels';

    final f = _cache.findFile(relPath);
    if (f == null) return {};
    try {
      final doc = XmlDocument.parse(utf8.decode(f.content as List<int>));
      final map = <String, String>{};
      for (final rel in doc.findAllElements('Relationship')) {
        final id = _attr(rel, 'Id');
        final target = _attr(rel, 'Target');
        final type = _attr(rel, 'Type');
        if (id.isEmpty) continue;

        String resolved;
        if (target.startsWith('/')) {
          resolved = target.substring(1);
        } else {
          resolved = _resolvePath(dir.isNotEmpty ? '$dir/$target' : target);
        }
        map[id] = resolved;
        map['__type__$id'] = type;
      }
      return map;
    } catch (_) {
      return {};
    }
  }

  String _resolvePath(String path) {
    final parts = path.split('/');
    final result = <String>[];
    for (final p in parts) {
      if (p == '..') {
        if (result.isNotEmpty) result.removeLast();
      } else if (p != '.' && p.isNotEmpty) {
        result.add(p);
      }
    }
    return result.join('/');
  }

  // ── استخراج لون مع دعم كل أنواع ألوان OOXML ──────────────────────────────
  String? _extractColor(XmlElement? container) {
    if (container == null) return null;

    // noFill ← لا لون
    if (container.findAllElements('a:noFill').isNotEmpty) return null;

    final srgb = container.findElements('a:srgbClr').firstOrNull;
    if (srgb != null) {
      final rgb = _attr(srgb, 'val');
      if (rgb.isEmpty) return null;
      // ⚠️ إضافة حقيقية: <a:alpha val="٪×1000"/> كعنصر فرعي لـ a:srgbClr
      // لم يكن يُقرأ إطلاقاً (الشفافية كانت تُفقَد كلياً — تأكيد فعلي:
      // ثلاث دوائر بشفافية 0%/50%/80% كانت تُعرَض جميعها بشفافية 0% أي
      // معتمة بالكامل). نُرجِع الآن hex بصيغة AARRGGBB (8 خانات) حين توجد
      // alpha صريحة بدل RRGGBB (6 خانات) فقط، حتى تصل قناة الشفافية لكل
      // مستهلكي fillHex/lineHex دون حاجة لحقل alpha منفصل عبر كل النماذج.
      final alphaEl = srgb.findElements('a:alpha').firstOrNull;
      if (alphaEl != null) {
        final alphaPermille = double.tryParse(_attr(alphaEl, 'val')) ?? 100000;
        final alphaByte = (alphaPermille / 100000 * 255).round().clamp(0, 255);
        return '${alphaByte.toRadixString(16).padLeft(2, '0').toUpperCase()}$rgb';
      }
      return rgb;
    }

    final scheme = container.findElements('a:schemeClr').firstOrNull;
    if (scheme != null) {
      return _themeColors.resolveWithMods(_attr(scheme, 'val'), scheme);
    }

    // ألوان CSS معيارية (preset)
    final prstClr = container.findElements('a:prstClr').firstOrNull;
    if (prstClr != null) {
      const presets = <String, String>{
        'black': '000000',
        'white': 'FFFFFF',
        'red': 'FF0000',
        'green': '008000',
        'blue': '0000FF',
        'yellow': 'FFFF00',
        'cyan': '00FFFF',
        'magenta': 'FF00FF',
        'orange': 'FFA500',
        'gray': '808080',
        'grey': '808080',
        'silver': 'C0C0C0',
        'navy': '000080',
        'purple': '800080',
        'maroon': '800000',
        'olive': '808000',
        'teal': '008080',
        'lime': '00FF00',
        'aqua': '00FFFF',
        'fuchsia': 'FF00FF',
      };
      return presets[_attr(prstClr, 'val')];
    }

    return null;
  }

  // ── تحليل خلفية من عنصر XML ──────────────────────────────────────────────
  _SlideBackground _parseBgFromEl(XmlElement? bgEl, Map<String, String>? rels) {
    if (bgEl == null) return const _SlideBackground(colorHex: 'FFFFFF');

    final bgPr = bgEl.children
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'bgPr')
        .firstOrNull;
    final bgRef = bgEl.children
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'bgRef')
        .firstOrNull;

    // noFill في bgPr
    if (bgPr != null) {
      final hasNoFill = bgPr.findAllElements('a:noFill').isNotEmpty;
      final hasSolidNoFill = bgPr.findAllElements('a:solidFill').isEmpty &&
          bgPr.findAllElements('a:gradFill').isEmpty &&
          bgPr.findAllElements('a:blipFill').isEmpty;
      if (hasNoFill || hasSolidNoFill) {
        return const _SlideBackground(isTransparent: true, colorHex: 'FFFFFF');
      }
    }

    // صورة خلفية
    if (bgPr != null) {
      final blipFill = bgPr.findAllElements('a:blipFill').firstOrNull;
      if (blipFill != null && rels != null) {
        final blip = blipFill.findAllElements('a:blip').firstOrNull;
        if (blip != null) {
          final rId =
              blip.getAttribute('r:embed') ?? blip.getAttribute('embed') ?? '';
          final imgPath = rels[rId];
          if (imgPath != null) {
            final bytes = _findImage(imgPath);
            if (bytes != null) return _SlideBackground(imageBytes: bytes);
          }
        }
      }

      // تدرج
      final gradFill = bgPr.findAllElements('a:gradFill').firstOrNull;
      if (gradFill != null) {
        final bg = _parseGradient(gradFill);
        if (bg != null) return bg;
      }

      // لون صلب
      final solidFill = bgPr.findAllElements('a:solidFill').firstOrNull;
      if (solidFill != null) {
        final color = _extractColor(solidFill);
        if (color != null) return _SlideBackground(colorHex: color);
      }
    }

    // لون صلب مباشر في bg
    final solidFill = bgEl.findAllElements('a:solidFill').firstOrNull;
    if (solidFill != null) {
      final color = _extractColor(solidFill);
      if (color != null) return _SlideBackground(colorHex: color);
    }

    // تدرج مباشر في bg
    final gradFill = bgEl.findAllElements('a:gradFill').firstOrNull;
    if (gradFill != null) {
      final bg = _parseGradient(gradFill);
      if (bg != null) return bg;
    }

    // bgRef → لون الثيم
    if (bgRef != null) {
      final color = _extractColor(bgRef);
      if (color != null) return _SlideBackground(colorHex: color);
    }

    return const _SlideBackground(colorHex: 'FFFFFF');
  }

  _SlideBackground? _parseGradient(XmlElement gradFill) {
    final stops = <_GradStop>[];
    for (final gs in gradFill.findAllElements('a:gs')) {
      final pos = (int.tryParse(_attr(gs, 'pos')) ?? 0) / 100000.0;
      final color = _extractColor(gs);
      if (color != null) stops.add(_GradStop(pos, color));
    }
    stops.sort((a, b) => a.pos.compareTo(b.pos));
    if (stops.length < 2) return null;

    final lin = gradFill.findAllElements('a:lin').firstOrNull;
    final angle =
        int.tryParse(_attr(lin ?? XmlElement(XmlName('')), 'ang')) ?? 5400000;
    return _SlideBackground(
      hasGradient: true,
      gradStops: stops,
      // زاوية 5400000 = 90 درجة (عمودي من أعلى لأسفل)
      isVerticalGrad: angle >= 2700000 && angle <= 8100000,
    );
  }

  // ── خلفية الشريحة مع وراثة Layout → Master ───────────────────────────────
  _SlideBackground _parseBackground(
    XmlElement slideEl,
    Map<String, String> slideRels,
  ) {
    // ① خلفية الشريحة نفسها
    final bgEl = slideEl.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'bg')
        .firstOrNull;

    if (bgEl != null) {
      final bg = _parseBgFromEl(bgEl, slideRels);
      // إذا كانت خلفية حقيقية (ليست FFFFFF الافتراضية) نستخدمها
      if (!bg.isTransparent ||
          bg.colorHex != 'FFFFFF' ||
          bg.hasGradient ||
          bg.imageBytes != null) {
        return bg;
      }
    }

    // ② وراثة من slideLayout
    final layoutPath = slideRels.entries
        .where((e) =>
            !e.key.startsWith('__type__') && e.value.contains('slideLayout'))
        .map((e) => e.value)
        .firstOrNull;

    if (layoutPath != null) {
      if (_layoutBgCache.containsKey(layoutPath)) {
        final cached = _layoutBgCache[layoutPath]!;
        if (cached.colorHex != 'FFFFFF' ||
            cached.hasGradient ||
            cached.imageBytes != null) {
          return cached;
        }
      } else {
        final lf = _cache.findFile(layoutPath);
        if (lf != null) {
          try {
            final lDoc =
                XmlDocument.parse(utf8.decode(lf.content as List<int>));
            final lRels = _readRels(layoutPath);
            final lBgEl = lDoc.descendants
                .whereType<XmlElement>()
                .where((e) => e.name.local == 'bg')
                .firstOrNull;
            final lBg = lBgEl != null
                ? _parseBgFromEl(lBgEl, lRels)
                : const _SlideBackground(colorHex: 'FFFFFF');
            _layoutBgCache[layoutPath] = lBg;

            if (lBg.colorHex != 'FFFFFF' ||
                lBg.hasGradient ||
                lBg.imageBytes != null) {
              return lBg;
            }

            // ③ وراثة من slideMaster
            final masterPath = lRels.entries
                .where((e) =>
                    !e.key.startsWith('__type__') &&
                    e.value.contains('slideMaster'))
                .map((e) => e.value)
                .firstOrNull;

            if (masterPath != null) {
              if (_masterBgCache.containsKey(masterPath)) {
                return _masterBgCache[masterPath]!;
              }
              final mf = _cache.findFile(masterPath);
              if (mf != null) {
                final mDoc =
                    XmlDocument.parse(utf8.decode(mf.content as List<int>));
                final mRels = _readRels(masterPath);
                final mBgEl = mDoc.descendants
                    .whereType<XmlElement>()
                    .where((e) => e.name.local == 'bg')
                    .firstOrNull;
                if (mBgEl != null) {
                  final mBg = _parseBgFromEl(mBgEl, mRels);
                  _masterBgCache[masterPath] = mBg;
                  return mBg;
                }
              }
            }
          } catch (_) {}
        }
      }
    }

    return const _SlideBackground(colorHex: 'FFFFFF');
  }

  // ── تحليل فقرة نصية ────────────────────────────────────────────────────────
  _TextParagraph _parseParagraph(XmlElement paraEl,
      {double defaultFontSize = 14}) {
    final pPr = paraEl.findElements('a:pPr').firstOrNull;

    _TextAlign align = _TextAlign.right;
    if (pPr != null) {
      switch (_attr(pPr, 'algn')) {
        case 'ctr':
          align = _TextAlign.center;
          break;
        case 'l':
          align = _TextAlign.left;
          break;
        case 'just':
          align = _TextAlign.justify;
          break;
        case 'r':
          align = _TextAlign.right;
          break;
      }
    }

    bool isBullet = false;
    String? bulletChar;
    bool isAutoNum = false;
    int indentLevel = 0;

    if (pPr != null) {
      indentLevel = int.tryParse(_attr(pPr, 'lvl')) ?? 0;

      final buChar = pPr.findAllElements('a:buChar').firstOrNull;
      if (buChar != null) {
        isBullet = true;
        bulletChar = _attr(buChar, 'char', fallback: '•');
      }
      if (pPr.findAllElements('a:buNone').isNotEmpty) {
        isBullet = false;
        bulletChar = null;
      }
      if (pPr.findAllElements('a:buAutoNum').isNotEmpty) {
        isBullet = true;
        isAutoNum = true;
        bulletChar = null;
      }
    }

    double spaceBefore = 0, spaceAfter = 0, lineSpacingPct = 100;
    if (pPr != null) {
      final spcBef = pPr.findElements('a:spcBef').firstOrNull;
      final spcBefPts = spcBef?.findAllElements('a:spcPts').firstOrNull;
      if (spcBefPts != null) {
        spaceBefore = (int.tryParse(_attr(spcBefPts, 'val')) ?? 0) / 100.0;
      }

      final spcAft = pPr.findElements('a:spcAft').firstOrNull;
      final spcAftPts = spcAft?.findAllElements('a:spcPts').firstOrNull;
      if (spcAftPts != null) {
        spaceAfter = (int.tryParse(_attr(spcAftPts, 'val')) ?? 0) / 100.0;
      }

      final lnSpc = pPr.findElements('a:lnSpc').firstOrNull;
      final lnSpcPct = lnSpc?.findAllElements('a:spcPct').firstOrNull;
      if (lnSpcPct != null) {
        lineSpacingPct =
            (int.tryParse(_attr(lnSpcPct, 'val')) ?? 100000) / 1000.0;
      }
    }

    final runs = <_TextRun>[];

    for (final r in paraEl.findElements('a:r')) {
      final rPr = r.findElements('a:rPr').firstOrNull;
      final text = r.findElements('a:t').firstOrNull?.innerText ?? '';
      if (text.isEmpty) continue;

      bool bold = false, italic = false, underline = false;
      double fontSize = defaultFontSize;
      String? colorHex;

      if (rPr != null) {
        bold = _attr(rPr, 'b') == '1' || _attr(rPr, 'b') == 'true';
        italic = _attr(rPr, 'i') == '1' || _attr(rPr, 'i') == 'true';
        underline = _attr(rPr, 'u').isNotEmpty && _attr(rPr, 'u') != 'none';
        final szStr = _attr(rPr, 'sz');
        if (szStr.isNotEmpty) fontSize = (int.tryParse(szStr) ?? 1400) / 100.0;

        colorHex = _extractColor(rPr.findElements('a:solidFill').firstOrNull);
      }

      final isEmoji = _hasEmoji(text);
      final isArabic = hasArabic(text);

      runs.add(_TextRun(
        text: text,
        bold: bold,
        italic: italic,
        underline: underline,
        fontSize: fontSize.clamp(6.0, 96.0),
        colorHex: colorHex,
        rtl: isArabic,
        isEmoji: isEmoji,
      ));
    }

    // line break
    if (runs.isEmpty && paraEl.findAllElements('a:br').isNotEmpty) {
      runs.add(const _TextRun(text: ' ', fontSize: 10));
    }

    return _TextParagraph(
      runs: runs,
      align: align,
      spaceBefore: spaceBefore,
      spaceAfter: spaceAfter,
      lineSpacingPct: lineSpacingPct,
      isBullet: isBullet,
      bulletChar: bulletChar,
      isAutoNum: isAutoNum,
      indentLevel: indentLevel,
    );
  }

  // ── تحليل جدول ───────────────────────────────────────────────────────────
  _TableData? _parseTable(XmlElement graphicFrame) {
    final tbl = graphicFrame.findAllElements('a:tbl').firstOrNull;
    if (tbl == null) return null;

    final colWidths = <double>[];
    final tblGrid = tbl.findAllElements('a:tblGrid').firstOrNull;
    if (tblGrid != null) {
      for (final gc in tblGrid.findAllElements('a:gridCol')) {
        final w = double.tryParse(_attr(gc, 'w')) ?? 914400;
        colWidths.add(w > 0 ? w : 914400);
      }
    }
    if (colWidths.isEmpty) return null;

    String? headerFillHex;
    final tblPr = tbl.findAllElements('a:tblPr').firstOrNull;
    final hasHeader = tblPr?.getAttribute('firstRow') == '1';

    final rows = <_TableRow>[];
    int rowIdx = 0;

    for (final tr in tbl.findAllElements('a:tr')) {
      final rowH = double.tryParse(_attr(tr, 'h')) ?? 457200;
      final isHeader = hasHeader && rowIdx == 0;
      final cells = <_TableCell>[];
      int colIdx = 0;

      for (final tc in tr.findAllElements('a:tc')) {
        final vMerge = tc.findAllElements('a:vMerge').isNotEmpty ||
            _attr(tc, 'vMerge') == '1';
        final hMerge = _attr(tc, 'hMerge') == '1';
        final gridSpan = math.max(1, int.tryParse(_attr(tc, 'gridSpan')) ?? 1);
        final rowSpan = math.max(1, int.tryParse(_attr(tc, 'rowSpan')) ?? 1);

        String? cellFill;
        String? borderHex;
        final tcPr = tc.findAllElements('a:tcPr').firstOrNull;
        if (tcPr != null) {
          cellFill =
              _extractColor(tcPr.findElements('a:solidFill').firstOrNull);
          // حدود اليسار كمرجع للون الحدود
          final lnL = tcPr.findElements('a:lnL').firstOrNull ??
              tcPr.findElements('a:lnT').firstOrNull;
          if (lnL != null) {
            borderHex =
                _extractColor(lnL.findAllElements('a:solidFill').firstOrNull);
          }
        }

        // لون خلفية صف الرأس
        if (isHeader && cellFill != null && colIdx == 0) {
          headerFillHex = cellFill;
        }

        final paragraphs = <_TextParagraph>[];
        final txBody = tc.findAllElements('a:txBody').firstOrNull;
        if (txBody != null) {
          for (final p in txBody.findAllElements('a:p')) {
            paragraphs.add(_parseParagraph(p));
          }
        }

        cells.add(_TableCell(
          paragraphs: paragraphs,
          fillHex: isHeader && cellFill == null ? headerFillHex : cellFill,
          gridSpan: gridSpan,
          rowSpan: rowSpan,
          hMerge: hMerge,
          vMerge: vMerge,
          borderHex: borderHex,
        ));
        colIdx += gridSpan;
      }

      rows.add(_TableRow(cells: cells, heightEmu: rowH, isHeader: isHeader));
      rowIdx++;
    }

    return _TableData(
      rows: rows,
      colWidthsEmu: colWidths,
      headerFillHex: headerFillHex,
    );
  }

  // ── تحليل شكل واحد ───────────────────────────────────────────────────────
  _SlideShape? _parseShape(XmlElement el, Map<String, String> rels) {
    // البحث عن xfrm في الأبناء المباشرة أو spPr
    final spPrEl = el.findElements('p:spPr').firstOrNull ??
        el.findElements('spPr').firstOrNull;
    // graphicFrame (جداول/رسوم) يستخدم <p:xfrm> مباشرةً، بينما الأشكال تستخدم <a:xfrm>.
    // نبحث عن الاثنين معاً حتى لا تُسقَط الجداول.
    final xfrm = el.findElements('p:xfrm').firstOrNull ??
        el.findElements('xfrm').firstOrNull ??
        el.findAllElements('a:xfrm').firstOrNull;
    if (xfrm == null) return null;

    final offEl = xfrm.findElements('a:off').firstOrNull;
    final extEl = xfrm.findElements('a:ext').firstOrNull;
    if (offEl == null || extEl == null) return null;

    final x = double.tryParse(_attr(offEl, 'x')) ?? 0;
    final y = double.tryParse(_attr(offEl, 'y')) ?? 0;
    final w = double.tryParse(_attr(extEl, 'cx')) ?? 0;
    final h = double.tryParse(_attr(extEl, 'cy')) ?? 0;
    if (w <= 0 || h <= 0) return null;

    final rot = int.tryParse(_attr(xfrm, 'rot')) ?? 0;
    final flipH = _attr(xfrm, 'flipH') == '1';
    final flipV = _attr(xfrm, 'flipV') == '1';

    // placeholder type
    final nvSpPr = el.findElements('p:nvSpPr').firstOrNull;
    final ph = nvSpPr?.findAllElements('p:ph').firstOrNull;
    final phType = ph != null ? _attr(ph, 'type') : '';
    final isTitle = phType == 'title' || phType == 'ctrTitle';
    final isSubtitle = phType == 'subTitle' || phType == 'body';

    // ── جدول ──────────────────────────────────────────────────────────────
    if (el.name.local == 'graphicFrame') {
      final tableData = _parseTable(el);
      if (tableData != null) {
        return _SlideShape(
          x: x,
          y: y,
          w: w,
          h: h,
          type: _ShapeType.table,
          tableData: tableData,
        );
      }
      // ── مخطط بياني أصلي (c:chart) ─────────────────────────────────────
      // ⚠️ إضافة حقيقية: كانت هذه الحالة تُسقَط بصمت تماماً سابقاً (لا
      // فحص لها إطلاقاً)، فأي شريحة فيها مخطط Bar/Line/Pie/Area/Scatter
      // كانت تُعرَض فارغة بلا أي أثر أو رسالة. الإصلاح: نبحث عن
      // <c:chart r:id="..."/> داخل a:graphicData، نحلّ rId عبر rels
      // (نفس آلية حلّ مسار الصور)، نقرأ ملف ppt/charts/chartN.xml الفعلي،
      // ونحلّله بـ PptChartXmlParser (منطق مُقتبَس من ChartXmlParser في
      // xlsx_to_pdf_converter.dart لأنه نفس معيار DrawingML Chart XML).
      final chartRef = el.findAllElements('c:chart').firstOrNull;
      if (chartRef != null) {
        final rId = chartRef.getAttribute('r:id') ?? '';
        final chartPath = rels[rId];
        if (chartPath != null) {
          final chartFile = _cache.findFile(chartPath);
          if (chartFile != null) {
            try {
              final chartXml = utf8.decode(chartFile.content as List<int>);
              final chartObj = PptChartXmlParser(chartXml).parse();
              if (chartObj != null) {
                return _SlideShape(
                  x: x,
                  y: y,
                  w: w,
                  h: h,
                  type: _ShapeType.chart,
                  chartData: chartObj,
                );
              }
            } catch (_) {
              // مخطط تالف أو غير متوقَّع البنية — تُتجاهَل بأمان كباقي
              // مسارات فشل العناصر الفردية في هذا الملف.
            }
          }
        }
      }
      return null;
    }

    // ── صورة (pic) ────────────────────────────────────────────────────────
    if (el.name.local == 'pic') {
      final blipFill = el.findElements('p:blipFill').firstOrNull;
      final blip = blipFill?.findAllElements('a:blip').firstOrNull;
      if (blip != null) {
        final rId =
            blip.getAttribute('r:embed') ?? blip.getAttribute('embed') ?? '';
        final imgPath = rels[rId];
        if (imgPath != null) {
          final bytes = _findImage(imgPath);
          if (bytes != null) {
            return _SlideShape(
              x: x,
              y: y,
              w: w,
              h: h,
              imageBytes: bytes,
              rot: rot,
              flipH: flipH,
              flipV: flipV,
            );
          }
        }
      }
      return null;
    }

    // ── شكل نصي/هندسي ─────────────────────────────────────────────────────
    String? fillHex;
    if (spPrEl != null) {
      if (spPrEl.findElements('a:noFill').isNotEmpty) {
        fillHex = null;
      } else {
        fillHex = _extractColor(spPrEl.findElements('a:solidFill').firstOrNull);
        // تدرج: استخدم أول لون من التدرج كـ fallback
        if (fillHex == null) {
          final grad = spPrEl.findElements('a:gradFill').firstOrNull;
          if (grad != null) {
            final firstGs = grad.findAllElements('a:gs').firstOrNull;
            if (firstGs != null) fillHex = _extractColor(firstGs);
          }
        }
      }
    }

    String? lineHex;
    double lineWidth = 0;
    final ln = spPrEl?.findElements('a:ln').firstOrNull;
    if (ln != null && ln.findElements('a:noFill').isEmpty) {
      final lw = double.tryParse(_attr(ln, 'w')) ?? 0;
      lineWidth = _emuToPt(lw).clamp(0.0, 6.0);
      lineHex = _extractColor(ln.findElements('a:solidFill').firstOrNull);
    }

    _ShapeType shapeType = _ShapeType.rectangle;
    final prstGeom = spPrEl?.findElements('a:prstGeom').firstOrNull;
    if (prstGeom != null) {
      final prst = _attr(prstGeom, 'prst');
      if (prst == 'ellipse' || prst == 'oval' || prst == 'circle') {
        shapeType = _ShapeType.oval;
      } else if (prst == 'line' ||
          prst.contains('Connector') ||
          prst == 'straightConnector1') {
        shapeType = _ShapeType.line;
      } else if (prst == 'triangle' ||
          prst == 'rtTriangle' ||
          prst == 'isoscelesTriangle') {
        shapeType = _ShapeType.triangle;
      } else if (prst == 'diamond' || prst == 'rhombus') {
        shapeType = _ShapeType.diamond;
      } else if (prst == 'rightArrow' ||
          prst == 'leftArrow' ||
          prst == 'upArrow' ||
          prst == 'downArrow') {
        shapeType = _ShapeType.rightArrow;
      } else if (prst == 'pentagon' || prst == 'homePlate') {
        shapeType = _ShapeType.pentagon;
      } else if (prst == 'hexagon') {
        shapeType = _ShapeType.hexagon;
      } else if (prst.startsWith('star') ||
          prst == 'star4' ||
          prst == 'star5' ||
          prst == 'star6' ||
          prst.contains('Star')) {
        shapeType = _ShapeType.star;
      } else if (prst == 'chevron') {
        shapeType = _ShapeType.chevron;
      } else if (prst.contains('round') || prst == 'roundRect') {
        shapeType = _ShapeType.roundedRectangle;
      } else if (prst.contains('Arrow')) {
        shapeType = _ShapeType.rightArrow;
      }
    }

    final txBody = el.findElements('p:txBody').firstOrNull ??
        el.findElements('txBody').firstOrNull;
    _VAlign vAlign = _VAlign.top;
    double tIns = 45720, bIns = 45720, lIns = 91440, rIns = 91440;

    if (txBody != null) {
      final bodyPr = txBody.findElements('a:bodyPr').firstOrNull ??
          txBody.findElements('bodyPr').firstOrNull;
      if (bodyPr != null) {
        switch (_attr(bodyPr, 'anchor')) {
          case 't':
            vAlign = _VAlign.top;
            break;
          case 'b':
            vAlign = _VAlign.bottom;
            break;
          case 'ctr':
            vAlign = _VAlign.middle;
            break;
        }
        tIns = double.tryParse(_attr(bodyPr, 'tIns')) ?? tIns;
        bIns = double.tryParse(_attr(bodyPr, 'bIns')) ?? bIns;
        lIns = double.tryParse(_attr(bodyPr, 'lIns')) ?? lIns;
        rIns = double.tryParse(_attr(bodyPr, 'rIns')) ?? rIns;
      }
    }

    final paragraphs = <_TextParagraph>[];
    if (txBody != null) {
      // حجم خط افتراضي حسب نوع العنصر النائب (عندما لا يحدّد الـ run حجماً)
      final double defSize = isTitle ? 32 : (isSubtitle ? 18 : 14);
      for (final p in txBody.findAllElements('a:p')) {
        paragraphs.add(_parseParagraph(p, defaultFontSize: defSize));
      }
    }

    return _SlideShape(
      x: x,
      y: y,
      w: w,
      h: h,
      type: shapeType,
      fillHex: fillHex,
      lineHex: lineHex,
      lineWidth: lineWidth,
      paragraphs: paragraphs,
      vAlign: vAlign,
      isTitle: isTitle,
      isSubtitle: isSubtitle,
      tIns: tIns,
      bIns: bIns,
      lIns: lIns,
      rIns: rIns,
      rot: rot,
      flipH: flipH,
      flipV: flipV,
    );
  }

  // ── تحليل الأشكال بشكل تكراري ─────────────────────────────────────────────
  void _parseShapesRecursive(
    XmlElement container,
    Map<String, String> rels,
    List<_SlideShape> shapes,
  ) {
    for (final sp in container.findElements('p:sp')) {
      try {
        final s = _parseShape(sp, rels);
        if (s != null) shapes.add(s);
      } catch (_) {}
    }
    for (final pic in container.findElements('p:pic')) {
      try {
        final s = _parseShape(pic, rels);
        if (s != null) shapes.add(s);
      } catch (_) {}
    }
    for (final gf in container.findElements('p:graphicFrame')) {
      try {
        final s = _parseShape(gf, rels);
        if (s != null) shapes.add(s);
      } catch (_) {}
    }
    for (final grp in container.findElements('p:grpSp')) {
      _parseShapesRecursive(grp, rels, shapes);
    }
  }

  // ── ملاحظات الشريحة ────────────────────────────────────────────────────────
  String? _parseNotes(Map<String, String> slideRels) {
    // البحث بنوع العلاقة (أكثر دقة من اسم الملف)
    final notesPath = slideRels.entries
            .where((e) =>
                e.key.startsWith('__type__') && e.value.contains('notesSlide'))
            .map((e) => slideRels[e.key.replaceFirst('__type__', '')])
            .whereType<String>()
            .firstOrNull ??
        slideRels.entries
            .where((e) =>
                !e.key.startsWith('__type__') && e.value.contains('notesSlide'))
            .map((e) => e.value)
            .firstOrNull;

    if (notesPath == null) return null;
    final f = _cache.findFile(notesPath);
    if (f == null) return null;

    try {
      final doc = XmlDocument.parse(utf8.decode(f.content as List<int>));
      final sb = StringBuffer();
      // تخطي أول txBody (عادةً يحتوي على رقم الشريحة)
      final txBodies = doc.findAllElements('p:txBody').toList();
      for (int i = 1; i < txBodies.length; i++) {
        for (final p in txBodies[i].findAllElements('a:p')) {
          final text = p.findAllElements('a:t').map((e) => e.innerText).join();
          if (text.trim().isNotEmpty) sb.writeln(text.trim());
        }
      }
      final result = sb.toString().trim();
      return result.isNotEmpty ? result : null;
    } catch (_) {
      return null;
    }
  }

  _Slide _parseSlide(ArchiveFile slideFile, int index) {
    final doc = XmlDocument.parse(utf8.decode(slideFile.content as List<int>));
    final slideEl = doc.rootElement;
    final rels = _readRels(slideFile.name);

    final background = _parseBackground(slideEl, rels);

    final shapes = <_SlideShape>[];
    final spTree = slideEl.findAllElements('p:spTree').firstOrNull ??
        slideEl.findAllElements('spTree').firstOrNull;
    if (spTree != null) _parseShapesRecursive(spTree, rels, shapes);

    return _Slide(
      shapes: shapes,
      background: background,
      notes: _parseNotes(rels),
      slideIndex: index,
    );
  }

  List<_Slide> parse() {
    _loadImages();
    _themeColors = _PptThemeColors.parse(_cache);
    _presSize = _PresentationSize.parse(_cache);

    // ترتيب الشرائح من presentation.xml
    final slideOrder = <String>[];
    final presFile = _cache.findFile('ppt/presentation.xml');
    if (presFile != null) {
      try {
        final doc =
            XmlDocument.parse(utf8.decode(presFile.content as List<int>));
        for (final sldId in doc.findAllElements('p:sldId')) {
          final id = _attr(sldId, 'r:id');
          if (id.isNotEmpty) slideOrder.add(id);
        }
      } catch (_) {}
    }

    final presRels = <String, String>{};
    final presRelFile = _cache.findFile('ppt/_rels/presentation.xml.rels');
    if (presRelFile != null) {
      try {
        final doc =
            XmlDocument.parse(utf8.decode(presRelFile.content as List<int>));
        for (final rel in doc.findAllElements('Relationship')) {
          final id = _attr(rel, 'Id');
          final target = _attr(rel, 'Target');
          if (id.isEmpty || target.isEmpty) continue;
          presRels[id] =
              target.startsWith('/') ? target.substring(1) : 'ppt/$target';
        }
      } catch (_) {}
    }

    var orderedPaths = slideOrder
        .map((id) => presRels[id])
        .whereType<String>()
        .where((p) =>
            p.contains('slides/slide') &&
            !p.contains('Layout') &&
            !p.contains('Master'))
        .toList();

    if (orderedPaths.isEmpty) {
      // fallback: فرز أبجدي (slide1, slide2, ...)
      orderedPaths = _cache.files
          .where((f) =>
              f.isFile &&
              f.name.startsWith('ppt/slides/slide') &&
              f.name.endsWith('.xml') &&
              !f.name.contains('Layout') &&
              !f.name.contains('Master'))
          .map((f) => f.name)
          .toList()
        ..sort((a, b) {
          // فرز رقمي: slide1 < slide2 < slide10
          final na = RegExp(r'\d+').stringMatch(a.split('/').last) ?? '0';
          final nb = RegExp(r'\d+').stringMatch(b.split('/').last) ?? '0';
          return int.parse(na).compareTo(int.parse(nb));
        });
    }

    final slides = <_Slide>[];
    for (int i = 0; i < orderedPaths.length; i++) {
      final f = _cache.findFile(orderedPaths[i]);
      if (f == null || !f.isFile) continue;
      try {
        slides.add(_parseSlide(f, i + 1));
      } catch (_) {} // تخطي الشرائح التالفة
    }
    return slides;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  محلل ODP (OpenDocument Presentation) — محسَّن
// ─────────────────────────────────────────────────────────────────────────────

class _OdpParser {
  final _ArchiveCache _cache;
  final Map<String, Uint8List> _images = {};

  _OdpParser(this._cache) {
    for (final f in _cache.files) {
      if (!f.isFile) continue;
      final name = f.name.toLowerCase();
      if (name.startsWith('pictures/') || name.startsWith('media/')) {
        _images[f.name] = f.content as Uint8List;
      }
    }
  }

  List<_Slide> parse() {
    final contentFile = _cache.findFile('content.xml');
    if (contentFile == null) return [];
    try {
      final doc =
          XmlDocument.parse(utf8.decode(contentFile.content as List<int>));
      final drawPages = doc.findAllElements('draw:page').toList();
      final slides = <_Slide>[];

      for (int i = 0; i < drawPages.length; i++) {
        final page = drawPages[i];
        final shapes = <_SlideShape>[];

        // عنوان الشريحة
        final titleEl = page.findAllElements('draw:title').firstOrNull;
        if (titleEl != null) {
          final text = titleEl.innerText.trim();
          if (text.isNotEmpty) {
            shapes.add(_SlideShape(
              x: 457200,
              y: 274638,
              w: 8229600,
              h: 1143000,
              paragraphs: [
                _TextParagraph(
                  runs: [
                    _TextRun(
                      text: text,
                      bold: true,
                      fontSize: 28,
                      rtl: hasArabic(text),
                    )
                  ],
                )
              ],
              isTitle: true,
            ));
          }
        }

        // عناصر draw:frame (نص وصور)
        for (final frame in page.findAllElements('draw:frame')) {
          final x = _parseOdpLength(frame.getAttribute('svg:x') ?? '0');
          final y = _parseOdpLength(frame.getAttribute('svg:y') ?? '0');
          final w = _parseOdpLength(frame.getAttribute('svg:width') ?? '0');
          final h = _parseOdpLength(frame.getAttribute('svg:height') ?? '0');
          if (w <= 0 || h <= 0) continue;
          final eX = x * 12700, eY = y * 12700, eW = w * 12700, eH = h * 12700;

          // صورة
          final imgEl = frame.findAllElements('draw:image').firstOrNull;
          if (imgEl != null) {
            final href = imgEl.getAttribute('xlink:href') ?? '';
            final bytes = _images[href] ?? _images[href.replaceFirst('./', '')];
            if (bytes != null) {
              shapes.add(
                  _SlideShape(x: eX, y: eY, w: eW, h: eH, imageBytes: bytes));
              continue;
            }
          }

          // نص
          final paragraphs = <_TextParagraph>[];
          for (final p in frame.findAllElements('text:p')) {
            final runs = <_TextRun>[];
            for (final span in p.findAllElements('text:span')) {
              final t = span.innerText.trim();
              if (t.isNotEmpty) {
                runs.add(_TextRun(text: t, fontSize: 14, rtl: hasArabic(t)));
              }
            }
            if (runs.isEmpty) {
              final t = p.innerText.trim();
              if (t.isNotEmpty) {
                runs.add(_TextRun(text: t, fontSize: 14, rtl: hasArabic(t)));
              }
            }
            if (runs.isNotEmpty) paragraphs.add(_TextParagraph(runs: runs));
          }
          if (paragraphs.isNotEmpty) {
            shapes.add(_SlideShape(
                x: eX, y: eY, w: eW, h: eH, paragraphs: paragraphs));
          }
        }

        // draw:custom-shape و draw:text-box
        for (final el in [
          ...page.findAllElements('draw:custom-shape'),
          ...page.findAllElements('draw:text-box')
        ]) {
          final x = _parseOdpLength(el.getAttribute('svg:x') ?? '0');
          final y = _parseOdpLength(el.getAttribute('svg:y') ?? '0');
          final w = _parseOdpLength(el.getAttribute('svg:width') ?? '0');
          final h = _parseOdpLength(el.getAttribute('svg:height') ?? '0');
          if (w <= 0 || h <= 0) continue;
          final eX = x * 12700, eY = y * 12700, eW = w * 12700, eH = h * 12700;

          final paragraphs = <_TextParagraph>[];
          for (final p in el.findAllElements('text:p')) {
            final t = p.innerText.trim();
            if (t.isNotEmpty) {
              paragraphs.add(_TextParagraph(
                runs: [_TextRun(text: t, fontSize: 14, rtl: hasArabic(t))],
              ));
            }
          }
          if (paragraphs.isNotEmpty) {
            shapes.add(_SlideShape(
                x: eX, y: eY, w: eW, h: eH, paragraphs: paragraphs));
          }
        }

        slides.add(_Slide(
          shapes: shapes,
          background: const _SlideBackground(colorHex: 'FFFFFF'),
          slideIndex: i + 1,
        ));
      }
      return slides;
    } catch (_) {
      return [];
    }
  }

  double _parseOdpLength(String s) {
    if (s.endsWith('cm')) {
      return (double.tryParse(s.replaceAll('cm', '')) ?? 0) * 28.3465;
    }
    if (s.endsWith('mm')) {
      return (double.tryParse(s.replaceAll('mm', '')) ?? 0) * 2.83465;
    }
    if (s.endsWith('in')) {
      return (double.tryParse(s.replaceAll('in', '')) ?? 0) * 72.0;
    }
    if (s.endsWith('pt')) return double.tryParse(s.replaceAll('pt', '')) ?? 0;
    return double.tryParse(s) ?? 0;
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  _mapSlidesToDocSpec — يستبدل _SlideRenderer بالكامل
//  ─────────────────────────────────────────────────────────────────────
//  يحوّل List<_Slide> (نتاج التحليل أعلاه، بلا أي تعديل) إلى PdfDocSpec
//  تصريحي. كل صفحة PDF تحوي شريحة واحدة أو أكثر (حسب slidesPerPage)،
//  كل شريحة كـ PdfBlockGroup (للخلفية) + قائمة overlayBlocks (للأشكال)
//  بإحداثيات مطلقة مُحجَّمة (scaled) إلى حجم خليتها في الشبكة.
// ═══════════════════════════════════════════════════════════════════════

int _argbFromPdfColorPpt(PdfColor c, {int alphaByte = 255}) =>
    ((alphaByte & 0xFF) << 24) |
    ((c.r & 0xFF) << 16) |
    ((c.g & 0xFF) << 8) |
    (c.b & 0xFF);

PdfTextAlign _mapPptHAlign(_TextAlign a) {
  switch (a) {
    case _TextAlign.center:
      return PdfTextAlign.center;
    case _TextAlign.right:
      return PdfTextAlign.right;
    case _TextAlign.justify:
      return PdfTextAlign.justify;
    case _TextAlign.left:
      return PdfTextAlign.left;
  }
}

/// PdfTextAlign مُعاد استخدامه كترميز عمودي: left=top، center=middle،
/// right=bottom (نفس الاتفاق المُستخدَم في xlsx_to_pdf_converter.dart).
PdfTextAlign _mapPptVAlign(_VAlign a) {
  switch (a) {
    case _VAlign.top:
      return PdfTextAlign.left;
    case _VAlign.bottom:
      return PdfTextAlign.right;
    case _VAlign.middle:
      return PdfTextAlign.center;
  }
}

PdfShapeKind _mapShapeKind(_ShapeType t) {
  switch (t) {
    case _ShapeType.roundedRectangle:
      return PdfShapeKind.roundedRectangle;
    case _ShapeType.oval:
      return PdfShapeKind.oval;
    case _ShapeType.line:
      return PdfShapeKind.line;
    case _ShapeType.triangle:
      return PdfShapeKind.triangle;
    case _ShapeType.diamond:
      return PdfShapeKind.diamond;
    case _ShapeType.rightArrow:
      return PdfShapeKind.rightArrow;
    case _ShapeType.pentagon:
      return PdfShapeKind.pentagon;
    case _ShapeType.hexagon:
      return PdfShapeKind.hexagon;
    case _ShapeType.star:
      return PdfShapeKind.star;
    case _ShapeType.chevron:
      return PdfShapeKind.chevron;
    case _ShapeType.rectangle:
    case _ShapeType.table:
    case _ShapeType.chart:
      // جدول/مخطط: لا تُستخدَم هذه الدالة فعلياً لهما (يُعالَجان عبر
      // tableData/chartData مباشرة في _mapPptShape قبل الوصول هنا) —
      // rectangle قيمة احتياطية آمنة فقط لإكمال exhaustiveness الفحص.
      return PdfShapeKind.rectangle;
  }
}

/// يحوّل نوع المخطط البياني المُستخرَج من DrawingML إلى السلسلة النصية
/// التي يتوقعها الجسر الأصلي (نفس الاتفاق المُستخدَم في XLSX).
String _mapPptChartKind(PptChartKind k) {
  switch (k) {
    case PptChartKind.pie:
      return 'pie';
    case PptChartKind.line:
      return 'line';
    case PptChartKind.area:
      return 'area';
    case PptChartKind.scatter:
      // لا راسم نقاط مبعثرة مخصّص في الجسر الأصلي بعد؛ نُقرِّبه كخط متصل
      // (انظر تعليق PptChartXmlParser._detectKind لتفصيل هذا القيد).
      return 'line';
    case PptChartKind.bar:
    case PptChartKind.unknown:
      return 'bar';
  }
}

/// توحيد رمز التعداد إلى رمز موثوق الرسم حسب مستوى التداخل — منقول بلا
/// تعديل من _SlideRenderer._normalizeBullet الأصلية.
String _normalizeBulletPpt(String raw, int level) {
  final c = raw.trim();
  if (c.isEmpty) return level == 0 ? '\u2022' : '\u25E6';
  const reliable = {'\u2022', '-', '\u25AA'};
  if (reliable.contains(c)) return c;
  return level == 0 ? '\u2022' : '\u2013';
}

/// يحوّل فقرة PPTX واحدة إلى PdfBlockParagraph، مع حساب علامة القائمة
/// (تعداد نقطي أو ترقيم تلقائي) — العدّادات تُمرَّر بالمرجع لتُحدَّث عبر
/// الفقرات المتتالية ضمن نفس الشكل (مطابق لـ autoNumCounters الأصلي).
/// [defaultColorArgb] لون افتراضي (من الثيم: عنوان أو نص عادي) يُستخدَم
/// فقط حين لا يحدّد الـ run الفعلي لونه الخاص (مطابق لـ defaultColor في
/// _drawShapeText الأصلية).
PdfBlockParagraph _mapPptParagraph(
  _TextParagraph para,
  Map<int, int> autoNumCounters,
  double fontScalePct,
  int defaultColorArgb,
) {
  final runs = <PdfTextRun>[];
  for (final r in para.runs) {
    runs.add(PdfTextRun(
      r.text,
      PdfFontSpec(
        family: r.rtl ? 'NotoNaskhArabic' : 'LiberationSans',
        sizePt: (r.fontSize * fontScalePct / 100).clamp(5.0, 96.0),
        bold: r.bold,
        italic: r.italic,
        underline: r.underline,
        colorArgb: r.colorHex != null
            ? _argbFromPdfColorPpt(_hexColor(r.colorHex))
            : defaultColorArgb,
      ),
    ));
  }

  String? marker;
  if (!para.isAutoNum) {
    autoNumCounters[para.indentLevel] = 0;
  }
  if (para.isAutoNum) {
    final n = (autoNumCounters[para.indentLevel] ?? 0) + 1;
    autoNumCounters[para.indentLevel] = n;
    marker = '$n.';
  } else if (para.isBullet && para.bulletChar != null) {
    marker = _normalizeBulletPpt(para.bulletChar!, para.indentLevel);
  }

  return PdfBlockParagraph(
    runs: runs,
    align: _mapPptHAlign(para.align),
    direction: para.isRtl ? PdfTextDirection.rtl : PdfTextDirection.ltr,
    spaceBeforePt: para.spaceBefore,
    spaceAfterPt: para.spaceAfter,
    lineSpacingMultiplier: para.lineSpacingPct / 100.0,
    indentStartPt: para.indentLevel * 12.0,
    listLevel: (para.isBullet || para.isAutoNum) ? para.indentLevel : null,
    listOrdered: para.isAutoNum,
    listMarkerOverride: marker,
  );
}

/// يحوّل جدول PPTX (_TableData) إلى PdfBlockTable، باستخدام نفس خوارزمية
/// شبكة الإشغال المُستخدَمة في XLSX (hMerge/vMerge في PPTX تقابل تماماً
/// خلايا "مغطاة بدمج" في XLSX، وgridSpan/rowSpan هنا تقابل colSpan/rowSpan
/// هناك مباشرة).
PdfBlockTable _mapPptTable(_TableData table, _ThemeColors colors) {
  final colWidthsEmu = table.colWidthsEmu;
  final totalEmu = colWidthsEmu.fold<double>(0, (s, w) => s + w);
  final colWidthsPt =
      totalEmu > 0 ? colWidthsEmu.map((w) => w / 12700.0).toList() : null;

  final rows = <List<PdfTableCell>>[];
  for (final row in table.rows) {
    final rowCells = <PdfTableCell>[];
    for (final cell in row.cells) {
      if (cell.hMerge || cell.vMerge) continue; // خلية امتداد — لا تُضاف مستقلة
      final autoNumCounters = <int, int>{};
      // أبيض على خلفية الترويسة الافتراضية الغامقة، وإلا لون نص الثيم —
      // مطابق تماماً لـ defaultTextColor الأصلية في _drawTable.
      final defaultTextColor = (row.isHeader && cell.fillHex == null)
          ? 0xFFFFFFFF
          : _argbFromPdfColorPpt(colors.text);
      final paragraphs = [
        for (final p in cell.paragraphs)
          _mapPptParagraph(p, autoNumCounters, 100, defaultTextColor),
      ];
      rowCells.add(PdfTableCell(
        blocks: paragraphs,
        colSpan: cell.gridSpan,
        rowSpan: cell.rowSpan,
        backgroundColorArgb: cell.fillHex != null
            ? _argbFromPdfColorPpt(_hexColor(cell.fillHex))
            : (row.isHeader
                ? _argbFromPdfColorPpt(_hexColor(table.headerFillHex,
                    fallback: const PdfColor(30, 58, 100)))
                : null),
        edgeBorders: PdfCellEdgeBorders(
          top: PdfBorderSpec(
              0.5,
              _argbFromPdfColorPpt(_hexColor(cell.borderHex,
                  fallback: const PdfColor(160, 160, 180)))),
          bottom: PdfBorderSpec(
              0.5,
              _argbFromPdfColorPpt(_hexColor(cell.borderHex,
                  fallback: const PdfColor(160, 160, 180)))),
          left: PdfBorderSpec(
              0.5,
              _argbFromPdfColorPpt(_hexColor(cell.borderHex,
                  fallback: const PdfColor(160, 160, 180)))),
          right: PdfBorderSpec(
              0.5,
              _argbFromPdfColorPpt(_hexColor(cell.borderHex,
                  fallback: const PdfColor(160, 160, 180)))),
        ),
        paddingPt: 3,
      ));
    }
    if (rowCells.isNotEmpty) rows.add(rowCells);
  }

  return PdfBlockTable(rows: rows, columnWidthsPt: colWidthsPt);
}

/// يحوّل شكلاً واحداً (_SlideShape) إلى PdfBlock مناسب (صورة/جدول/مجموعة
/// نص+خلفية)، بإحداثيات مُحجَّمة (EMU → نقاط الخلية الفعلية)، يُضاف كـ
/// overlay مطلق. يُعيد null إن لم يكن للشكل أي تمثيل بصري (نادر).
PdfAbsoluteOverlay? _mapPptShape(
  _SlideShape shape,
  double cellX,
  double cellY,
  double scX,
  double scY,
  _ThemeColors colors,
) {
  final rx = cellX + shape.x * scX;
  final ry = cellY + shape.y * scY;
  final rw = shape.w * scX;
  final rh = shape.h * scY;
  if (rw < 0.5 || rh < 0.5) return null;

  if (shape.tableData != null) {
    return PdfAbsoluteOverlay(
      xPt: rx,
      yPt: ry,
      block: _mapPptTable(shape.tableData!, colors),
    );
  }

  if (shape.chartData != null) {
    final chart = shape.chartData!;
    return PdfAbsoluteOverlay(
      xPt: rx,
      yPt: ry,
      block: PdfBlockChart(
        kind: _mapPptChartKind(chart.kind),
        title: chart.title,
        categories:
            chart.series.isNotEmpty ? chart.series.first.categories : const [],
        series: [
          for (final s in chart.series)
            PdfChartSeries(s.name, s.values, s.colorArgb),
        ],
        widthPt: rw.clamp(80.0, 2000.0),
        heightPt: rh.clamp(60.0, 1200.0),
      ),
    );
  }

  // fontScale: يطابق المعادلة الأصلية في _drawShapeText تماماً —
  // min(scX,scY) * 1270000 يُعطي ≈100 عند شريحة كاملة الصفحة (1pt=12700EMU)
  // فيصبح (fontSize*100/100)=fontSize كما هو متوقع.
  final fontScalePct = math.min(scX, scY) * 1270000.0;
  // اللون الافتراضي للنص حين لا يحدّد الـ run الخاص لونه — عنوان أو نص
  // عادي حسب الثيم، مطابق لـ defaultColor الأصلية في _drawShapeText.
  final defaultColorArgb =
      _argbFromPdfColorPpt(shape.isTitle ? colors.title : colors.text);

  if (shape.imageBytes != null) {
    final normalized = _normalizeImageForPdf(shape.imageBytes!);
    if (normalized == null) return null;
    final imageBlock =
        PdfBlockImage(bytes: normalized, widthPt: rw, heightPt: rh);
    final hasImgTransform = shape.rot != 0 || shape.flipH || shape.flipV;
    // ⚠️ إصلاح خلل حقيقي مؤكَّد على جهاز فعلي: صور مستقلة (بلا نص) كانت
    // تُرسَم دوماً بـ PdfBlockImage مباشرة دون أي تطبيق لـ rot/flipH/flipV
    // — تأكيد فعلي: شريحة "Image flipH/flipV/rotate 30" أظهرت 3 صور
    // متطابقة الاتجاه تماماً رغم اختلاف التحويلات المطلوبة لكل منها. كانت
    // بنية الدوران/الانعكاس (PdfBlockGroup) موجودة وتعمل لمجموعات النص+
    // الشكل، لكنها لم تكن مُستخدَمة إطلاقاً لحالة الصورة المستقلة. الإصلاح:
    // نُغلِّف الصورة بـ PdfBlockGroup عند وجود أي تحويل، مُعيدين استخدام
    // الآلية الموجودة بدل بناء منطق تحويل خاص بالصور من جديد.
    if (!hasImgTransform) {
      return PdfAbsoluteOverlay(xPt: rx, yPt: ry, block: imageBlock);
    }
    return PdfAbsoluteOverlay(
      xPt: rx,
      yPt: ry,
      block: PdfBlockGroup(
        children: [imageBlock],
        widthPt: rw,
        heightPt: rh,
        rotationDegrees: shape.rot / 60000.0,
        flipHorizontal: shape.flipH,
        flipVertical: shape.flipV,
      ),
    );
  }

  // مجموعة: خلفية هندسية (إن وُجد ملء/حد) + فقرات النص فوقها، كوحدة واحدة
  // يُطبَّق عليها الدوران/الانعكاس معاً (مطابق لـ hasTransform الأصلي الذي
  // كان يُطبَّق على الشكل والنص معاً بنفس save/restore).
  final children = <PdfBlock>[];
  final hasFillOrLine =
      shape.fillHex != null || (shape.lineHex != null && shape.lineWidth > 0);
  if (hasFillOrLine || shape.type != _ShapeType.rectangle) {
    children.add(PdfBlockShape(
      kind: _mapShapeKind(shape.type),
      widthPt: rw,
      heightPt: rh,
      fillColorArgb: shape.fillHex != null
          ? _argbFromPdfColorPpt(_hexColor(shape.fillHex),
              alphaByte: _extractAlphaByte(shape.fillHex))
          : null,
      lineColorArgb: shape.lineHex != null
          ? _argbFromPdfColorPpt(_hexColor(shape.lineHex),
              alphaByte: _extractAlphaByte(shape.lineHex))
          : null,
      lineWidthPt: shape.lineWidth,
    ));
  }

  if (shape.paragraphs.isNotEmpty) {
    final autoNumCounters = <int, int>{};
    for (final p in shape.paragraphs) {
      if (p.isEmpty) continue;
      children.add(
          _mapPptParagraph(p, autoNumCounters, fontScalePct, defaultColorArgb));
    }
  }

  if (children.isEmpty) return null;

  return PdfAbsoluteOverlay(
    xPt: rx,
    yPt: ry,
    block: PdfBlockGroup(
      children: children,
      widthPt: rw,
      heightPt: rh,
      rotationDegrees: shape.rot / 60000.0,
      flipHorizontal: shape.flipH,
      flipVertical: shape.flipV,
      paddingTopPt: shape.tIns / 12700.0,
      paddingBottomPt: shape.bIns / 12700.0,
      paddingLeftPt: shape.lIns / 12700.0,
      paddingRightPt: shape.rIns / 12700.0,
      verticalContentAlign: _mapPptVAlign(shape.vAlign),
    ),
  );
}

/// يحوّل خلفية الشريحة إلى مواصفات خلفية صفحة (لون صلب أو تدرّج حقيقي).
/// عند وجود تدرّج، يُبنى PdfGradientFill كامل (لا تقريب لون واحد) ليُرسَم
/// عبر LinearGradient أصلي في الجسر — أدق من تدرّج Syncfusion اليدوي.
({int? colorArgb, PdfGradientFill? gradient}) _mapPptBackground(
  _SlideBackground bg,
  _ThemeColors colors,
) {
  if (bg.isTransparent) return (colorArgb: 0xFFFFFFFF, gradient: null);
  if (bg.hasGradient && bg.gradStops.length >= 2) {
    final sorted = [...bg.gradStops]..sort((a, b) => a.pos.compareTo(b.pos));
    return (
      colorArgb: null,
      gradient: PdfGradientFill(
        stopPositions: [for (final s in sorted) s.pos.clamp(0.0, 1.0)],
        stopColorsArgb: [
          for (final s in sorted) _argbFromPdfColorPpt(_hexColor(s.colorHex))
        ],
        vertical: bg.isVerticalGrad,
      ),
    );
  }
  return (
    colorArgb:
        _argbFromPdfColorPpt(_hexColor(bg.colorHex, fallback: colors.bg)),
    gradient: null,
  );
}

(int cols, int rows) _pptGridLayout(int perPage) => switch (perPage) {
      1 => (1, 1),
      2 => (1, 2),
      3 => (1, 3),
      4 => (2, 2),
      6 => (2, 3),
      9 => (3, 3),
      _ => (1, perPage),
    };

/// يحوّل قائمة الشرائح كاملة إلى PdfDocSpec — نقطة الدخول الرئيسية لهذا
/// الملف، تستبدل حلقة الرسم في convert() الأصلية بالكامل.
/// خاصّة (private) عمداً: تأخذ أنواعاً خاصّة بهذا الملف (_Slide،
/// _ThemeColors) ولا تُستدعى إلا من convertPpt داخل هذا الملف نفسه — جعلها
/// عامة كان يُصدِّر واجهة برمجية غير قابلة للاستدعاء فعلياً من خارج هذا
/// الملف (محلِّل Dart يُصنِّف هذا كـ library_private_types_in_public_api).
PdfDocSpec _mapSlidesToDocSpec(
  List<_Slide> slides,
  PptConversionOptions options,
  double pageWidthPt,
  double pageHeightPt,
  double srcWidthEmu,
  double srcHeightEmu,
  _ThemeColors colors,
) {
  final perPage = options.slidesPerPage.clamp(1, 9);
  final (cols, rows) = _pptGridLayout(perPage);
  final cellW = pageWidthPt / cols;
  final cellH = pageHeightPt / rows;
  final gap = perPage > 1 ? 4.0 : 0.0;

  final groups = <List<_Slide>>[];
  for (int i = 0; i < slides.length; i += perPage) {
    groups.add(slides.sublist(i, math.min(i + perPage, slides.length)));
  }

  final pages = <PdfPageSpec>[];
  int slideNum = 0;

  for (final group in groups) {
    final overlays = <PdfAbsoluteOverlay>[];
    // خلفية الصفحة الكلية الفاتحة (pageBg من الثيم) تظهر فقط في الفراغ
    // بين خلايا الشبكة عند تعدد الشرائح لكل صفحة (مطابقة لمستطيل خلفية
    // الصفحة عند perPage>1 في الإصدار الأصلي).
    final wholePageBg =
        perPage > 1 ? _argbFromPdfColorPpt(colors.pageBg) : null;

    for (int si = 0; si < group.length; si++) {
      slideNum++;
      final col = si % cols;
      final row = si ~/ cols;
      final cx = col * cellW + gap / 2;
      final cy = row * cellH + gap / 2;
      final cw = cellW - gap;
      final ch = cellH - gap;

      // خلفية الشريحة نفسها (لون صلب أو تدرّج حقيقي) — تُرسم دوماً كـ
      // overlay مستطيل، بصرف النظر عن perPage، لضمان دعم التدرّج بشكل
      // موحَّد في كل الحالات (بخلاف الإصدار السابق الذي كان يُقصِر دعم
      // الخلفية الكاملة على perPage=1 فقط عبر حقل لون صفحة واحد).
      final bgResult = _mapPptBackground(group[si].background, colors);
      overlays.add(PdfAbsoluteOverlay(
        xPt: cx,
        yPt: cy,
        block: PdfBlockShape(
          kind: PdfShapeKind.rectangle,
          widthPt: cw,
          heightPt: ch,
          fillColorArgb: bgResult.colorArgb,
          gradientFill: bgResult.gradient,
          lineColorArgb: (perPage > 1 && options.showSlideThumbnailBorder)
              ? 0xFFC8C8DC
              : null,
          lineWidthPt:
              (perPage > 1 && options.showSlideThumbnailBorder) ? 0.5 : 0,
        ),
      ));

      final scX = cw / srcWidthEmu;
      final scY = ch / srcHeightEmu;
      for (final shape in group[si].shapes) {
        try {
          final overlay = _mapPptShape(shape, cx, cy, scX, scY, colors);
          if (overlay != null) overlays.add(overlay);
        } catch (_) {
          // شكل تالف — تخطِّه (مطابق لسلوك try/catch الأصلي في renderSlide)
        }
      }

      if (options.showSlideNumbers) {
        overlays.add(PdfAbsoluteOverlay(
          xPt: cx + cw - 22,
          yPt: cy + ch - 14,
          block: PdfBlockParagraph(
            runs: [
              PdfTextRun(
                  '$slideNum',
                  PdfFontSpec(
                      family: 'LiberationSans',
                      sizePt: 8,
                      colorArgb: _argbFromPdfColorPpt(colors.accent))),
            ],
            align: PdfTextAlign.right,
          ),
        ));
      }
    }

    pages.add(PdfPageSpec(
      widthPt: pageWidthPt,
      heightPt: pageHeightPt,
      backgroundColorArgb: wholePageBg,
      blocks: const [],
      overlayBlocks: overlays,
    ));

    // صفحات الملاحظات (إن طُلبت) — صفحة مستقلة بعد كل شريحة فيها ملاحظات.
    if (options.includeNotes) {
      for (final slide in group) {
        if (slide.notes != null && slide.notes!.isNotEmpty) {
          pages.add(
              _buildNotesPage(slide.notes!, pageWidthPt, pageHeightPt, colors));
        }
      }
    }
  }

  return PdfDocSpec(pages: pages, isPrecomposed: true);
}

/// صفحة ملاحظات مستقلة — مطابقة لـ renderNotesPage الأصلية (خلفية ثابتة
/// فاتحة (250,250,255) بصرف النظر عن الثيم + عنوان بلون accent الثيم +
/// نص بلون text الثيم).
PdfPageSpec _buildNotesPage(
    String notes, double pgW, double pgH, _ThemeColors colors) {
  final isRtl = hasArabic(notes);
  return PdfPageSpec(
    widthPt: pgW,
    heightPt: pgH,
    marginTopPt: 20,
    marginBottomPt: 20,
    marginLeftPt: 20,
    marginRightPt: 20,
    backgroundColorArgb: 0xFFFAFAFF, // PdfColor(250,250,255) — ثابت دوماً
    blocks: [
      PdfBlockParagraph(
        runs: [
          PdfTextRun(
              'ملاحظات الشريحة',
              PdfFontSpec(
                  family: 'NotoNaskhArabic',
                  sizePt: 10,
                  bold: true,
                  colorArgb: _argbFromPdfColorPpt(colors.accent))),
        ],
        align: PdfTextAlign.right,
        direction: PdfTextDirection.rtl,
        spaceAfterPt: 10,
      ),
      PdfBlockParagraph(
        runs: [
          PdfTextRun(
            notes,
            PdfFontSpec(
              family: isRtl ? 'NotoNaskhArabic' : 'LiberationSans',
              sizePt: 9,
              colorArgb: _argbFromPdfColorPpt(colors.text),
            ),
          ),
        ],
        align: isRtl ? PdfTextAlign.right : PdfTextAlign.left,
        direction: isRtl ? PdfTextDirection.rtl : PdfTextDirection.ltr,
      ),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
//  ألوان الثيم
// ─────────────────────────────────────────────────────────────────────────────

class _ThemeColors {
  final PdfColor bg;
  final PdfColor title;
  final PdfColor text;
  final PdfColor accent;
  final PdfColor pageBg;

  const _ThemeColors({
    required this.bg,
    required this.title,
    required this.text,
    required this.accent,
    required this.pageBg,
  });

  static _ThemeColors from(PptTheme t) => switch (t) {
        PptTheme.dark => const _ThemeColors(
            bg: PdfColor(20, 20, 40),
            title: PdfColor(255, 255, 255),
            text: PdfColor(200, 200, 220),
            accent: PdfColor(108, 99, 255),
            pageBg: PdfColor(14, 14, 28),
          ),
        PptTheme.minimal => const _ThemeColors(
            bg: PdfColor(255, 255, 255),
            title: PdfColor(30, 30, 30),
            text: PdfColor(80, 80, 80),
            accent: PdfColor(108, 99, 255),
            pageBg: PdfColor(248, 248, 248),
          ),
        PptTheme.corporate => const _ThemeColors(
            bg: PdfColor(240, 244, 255),
            title: PdfColor(15, 30, 80),
            text: PdfColor(40, 50, 90),
            accent: PdfColor(37, 99, 235),
            pageBg: PdfColor(230, 236, 255),
          ),
        PptTheme.light => const _ThemeColors(
            bg: PdfColor(255, 255, 255),
            title: PdfColor(26, 26, 46),
            text: PdfColor(60, 60, 80),
            accent: PdfColor(108, 99, 255),
            pageBg: PdfColor(245, 245, 250),
          ),
      };
}

// ─────────────────────────────────────────────────────────────────────────────
//  المحوّل الرئيسي — الواجهة العامة
// ─────────────────────────────────────────────────────────────────────────────

class PptToPdfConverter {
  PptToPdfConverter._();

  /// يحلّل ملف PPTX/ODP ويُعيد PdfDocSpec — نموذج تخطيط تصريحي بلا أي PDF
  /// مُولَّد بعد. لا يستدعي rootBundle أو أي MethodChannel، فهو آمن
  /// للاستدعاء من Worker Isolate. لتوليد بايتات PDF فعلية، مرّر النتيجة
  /// إلى NativePdfBridge.renderDocument() من Main Isolate.
  static Future<PdfDocSpec> parseToLayout(
    File pptFile, {
    PptConversionOptions options = const PptConversionOptions(),
    void Function(PptConversionProgress)? onProgress,
    PptCancelToken? cancelToken,
  }) async {
    void report(double p, String stage) {
      if (cancelToken?.isCancelled != true) {
        onProgress?.call(PptConversionProgress(p, stage));
      }
    }

    void checkCancelled() {
      if (cancelToken?.isCancelled == true) throw const PptCancelledException();
    }

    report(0.05, 'قراءة الملف...');
    final Uint8List fileBytes;
    try {
      fileBytes = await pptFile.readAsBytes();
    } catch (e) {
      throw const PptConversionException('تعذر قراءة ملف العرض التقديمي');
    }
    checkCancelled();

    report(0.12, 'فك ضغط الملف...');
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(fileBytes);
    } catch (_) {
      throw const PptConversionException(
          'الملف تالف أو لا يمكن فك ضغطه — تأكد أنه PPTX أو ODP صحيح');
    }
    checkCancelled();

    final cache = _ArchiveCache(archive);

    report(0.20, 'تحليل الشرائح...');
    final ext = pptFile.path.split('.').last.toLowerCase();
    _PptxParser? pptxParser;
    List<_Slide> slides;

    if (ext == 'odp') {
      slides = _OdpParser(cache).parse();
    } else {
      if (cache.findFile('ppt/presentation.xml') == null) {
        throw const PptConversionException(
            'صيغة .ppt القديمة غير مدعومة — احفظ الملف بصيغة .pptx ثم أعد المحاولة');
      }
      pptxParser = _PptxParser(cache);
      slides = pptxParser.parse();
    }

    if (slides.isEmpty) {
      throw const PptConversionException('لم يتم العثور على أي شرائح في الملف');
    }
    checkCancelled();

    report(0.40, 'تجهيز التخطيط...');

    final double pgW, pgH;
    if (options.slideLayout == PptSlideLayout.fromFile && pptxParser != null) {
      pgW = pptxParser._presSize.widthPt;
      pgH = pptxParser._presSize.heightPt;
    } else {
      (pgW, pgH) = switch (options.slideLayout) {
        PptSlideLayout.standard => (720.0, 540.0),
        PptSlideLayout.a4Portrait => (595.28, 841.89),
        _ => (960.0, 540.0),
      };
    }

    // اتجاه الصفحة: عند w > h (landscape) تبقى الأبعاد كما هي (width=w,
    // height=h) لأن PdfPageSpec لا يفترض دوماً portrait-base كما كان
    // يفترض Syncfusion's pageSettings.size — النموذج الجديد يرسم بالضبط
    // بالأبعاد المُمرَّرة بصرف النظر عن أيها أكبر.

    final srcW = pptxParser?._presSize.cxEmu ?? 9144000.0;
    final srcH = pptxParser?._presSize.cyEmu ?? 5143500.0;
    final colors = _ThemeColors.from(options.theme);

    checkCancelled();
    final spec =
        _mapSlidesToDocSpec(slides, options, pgW, pgH, srcW, srcH, colors);

    report(0.60, 'اكتمل تجهيز التخطيط');
    return spec;
  }
}
