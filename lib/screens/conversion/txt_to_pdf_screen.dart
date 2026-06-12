import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../../theme/app_theme.dart';
import '../result_screen.dart';

// ─── Template system ─────────────────────────────────────────────────────────

class _NoteTemplate {
  final String id;
  final String name;
  final Color bgColor;
  final Gradient? gradient;
  final Color textColor;
  final Color titleColor;
  final Color toolbarColor;
  final bool hasLines;
  final Color lineColor;

  const _NoteTemplate({
    required this.id,
    required this.name,
    required this.bgColor,
    this.gradient,
    this.textColor = const Color(0xFF2D2D2D),
    this.titleColor = const Color(0xFF1A1A2E),
    this.toolbarColor = const Color(0xFFF6A623),
    this.hasLines = false,
    this.lineColor = const Color(0xFFE0D9CC),
  });
}

const _kCategories = [
  'ألوان مائية', 'حب', 'تقنية', 'مينيمالست',
  'ورق', 'طبيعة', 'فن', 'هندسة', 'ألوان',
];

final _kTemplates = <String, List<_NoteTemplate>>{
  'ألوان مائية': [
    _NoteTemplate(id: 'wc1', name: 'زهري مائي',
        bgColor: const Color(0xFFFCE4EC),
        gradient: const LinearGradient(
            colors: [Color(0xFFFCE4EC), Color(0xFFE1BEE7)],
            begin: Alignment.topRight, end: Alignment.bottomLeft),
        toolbarColor: const Color(0xFFE91E63)),
    _NoteTemplate(id: 'wc2', name: 'أزرق مائي',
        bgColor: const Color(0xFFE3F2FD),
        gradient: const LinearGradient(
            colors: [Color(0xFFE3F2FD), Color(0xFFB3E5FC)],
            begin: Alignment.topRight, end: Alignment.bottomLeft),
        toolbarColor: const Color(0xFF1976D2)),
    _NoteTemplate(id: 'wc3', name: 'ذهبي مائي',
        bgColor: const Color(0xFFFFF8E1),
        gradient: const LinearGradient(
            colors: [Color(0xFFFFF8E1), Color(0xFFFFE082)],
            begin: Alignment.topRight, end: Alignment.bottomLeft),
        toolbarColor: const Color(0xFFF9A825)),
  ],
  'حب': [
    _NoteTemplate(id: 'lv1', name: 'وردي',
        bgColor: const Color(0xFFFCE4EC),
        gradient: const LinearGradient(
            colors: [Color(0xFFFCE4EC), Color(0xFFFFCDD2)],
            begin: Alignment.topCenter, end: Alignment.bottomCenter),
        toolbarColor: const Color(0xFFE91E63)),
    _NoteTemplate(id: 'lv2', name: 'زهري فاتح',
        bgColor: const Color(0xFFF8BBD0),
        toolbarColor: const Color(0xFFC2185B)),
    _NoteTemplate(id: 'lv3', name: 'بنفسجي',
        bgColor: const Color(0xFFEDE7F6),
        gradient: const LinearGradient(
            colors: [Color(0xFFEDE7F6), Color(0xFFE1BEE7)],
            begin: Alignment.topCenter, end: Alignment.bottomCenter),
        toolbarColor: const Color(0xFF7B1FA2)),
  ],
  'تقنية': [
    _NoteTemplate(id: 'tc1', name: 'أخضر داكن',
        bgColor: const Color(0xFF0D2818),
        textColor: const Color(0xFF00E676),
        titleColor: const Color(0xFF69F0AE),
        gradient: const LinearGradient(
            colors: [Color(0xFF0D2818), Color(0xFF1B5E20)],
            begin: Alignment.topCenter, end: Alignment.bottomCenter),
        toolbarColor: const Color(0xFF1B5E20)),
    _NoteTemplate(id: 'tc2', name: 'أزرق داكن',
        bgColor: const Color(0xFF0A1929),
        textColor: const Color(0xFF82B1FF),
        titleColor: const Color(0xFF82B1FF),
        gradient: const LinearGradient(
            colors: [Color(0xFF0A1929), Color(0xFF1A237E)],
            begin: Alignment.topCenter, end: Alignment.bottomCenter),
        toolbarColor: const Color(0xFF1A237E)),
    _NoteTemplate(id: 'tc3', name: 'فيروزي داكن',
        bgColor: const Color(0xFF00251A),
        textColor: const Color(0xFF64FFDA),
        titleColor: const Color(0xFF64FFDA),
        gradient: const LinearGradient(
            colors: [Color(0xFF00251A), Color(0xFF004D40)],
            begin: Alignment.topCenter, end: Alignment.bottomCenter),
        toolbarColor: const Color(0xFF00695C)),
  ],
  'مينيمالست': [
    _NoteTemplate(id: 'mn1', name: 'بيج دافئ',
        bgColor: const Color(0xFFF5F0E8),
        gradient: const LinearGradient(
            colors: [Color(0xFFF5F0E8), Color(0xFFEDE8DC)],
            begin: Alignment.topCenter, end: Alignment.bottomCenter),
        toolbarColor: const Color(0xFF8D6E63)),
    _NoteTemplate(id: 'mn2', name: 'رمادي ناعم',
        bgColor: const Color(0xFFF5F5F5),
        toolbarColor: const Color(0xFF616161)),
    _NoteTemplate(id: 'mn3', name: 'كريمي',
        bgColor: const Color(0xFFFFFBF5),
        gradient: const LinearGradient(
            colors: [Color(0xFFFFFBF5), Color(0xFFFFF8EE)],
            begin: Alignment.topCenter, end: Alignment.bottomCenter),
        toolbarColor: const Color(0xFFA1887F)),
  ],
  'ورق': [
    _NoteTemplate(id: 'pp1', name: 'ورق أصفر',
        bgColor: const Color(0xFFFFF9C4),
        hasLines: true,
        lineColor: const Color(0xFFE6D44A),
        toolbarColor: const Color(0xFFF9A825)),
    _NoteTemplate(id: 'pp2', name: 'ورق أبيض',
        bgColor: const Color(0xFFFAFAFA),
        hasLines: true,
        lineColor: const Color(0xFFD0D0D0),
        toolbarColor: const Color(0xFF616161)),
    _NoteTemplate(id: 'pp3', name: 'كرافت',
        bgColor: const Color(0xFFD4A76A),
        textColor: const Color(0xFF3E2723),
        titleColor: const Color(0xFF3E2723),
        toolbarColor: const Color(0xFF6D4C41)),
  ],
  'طبيعة': [
    _NoteTemplate(id: 'nt1', name: 'أخضر حرج',
        bgColor: const Color(0xFF1B5E20),
        textColor: const Color(0xFFE8F5E9),
        titleColor: Colors.white,
        gradient: const LinearGradient(
            colors: [Color(0xFF1B5E20), Color(0xFF2E7D32)],
            begin: Alignment.topCenter, end: Alignment.bottomCenter),
        toolbarColor: const Color(0xFF2E7D32)),
    _NoteTemplate(id: 'nt2', name: 'أخضر زيتي',
        bgColor: const Color(0xFF33691E),
        textColor: const Color(0xFFF9FBE7),
        titleColor: Colors.white,
        toolbarColor: const Color(0xFF558B2F)),
    _NoteTemplate(id: 'nt3', name: 'أخضر مريمية',
        bgColor: const Color(0xFFDCEDC8),
        toolbarColor: const Color(0xFF7CB342)),
  ],
  'فن': [
    _NoteTemplate(id: 'ar1', name: 'غروب',
        bgColor: const Color(0xFFFF7043),
        gradient: const LinearGradient(
            colors: [Color(0xFFFF7043), Color(0xFFFF8A65), Color(0xFFFFCC02)],
            begin: Alignment.topCenter, end: Alignment.bottomCenter),
        textColor: Colors.white,
        titleColor: Colors.white,
        toolbarColor: const Color(0xFFBF360C)),
    _NoteTemplate(id: 'ar2', name: 'شفق قطبي',
        bgColor: const Color(0xFF1A237E),
        gradient: const LinearGradient(
            colors: [Color(0xFF1A237E), Color(0xFF4A148C), Color(0xFF006064)],
            begin: Alignment.topCenter, end: Alignment.bottomCenter),
        textColor: const Color(0xFFE8EAF6),
        titleColor: Colors.white,
        toolbarColor: const Color(0xFF283593)),
    _NoteTemplate(id: 'ar3', name: 'وردي فني',
        bgColor: const Color(0xFFAD1457),
        gradient: const LinearGradient(
            colors: [Color(0xFFAD1457), Color(0xFFE91E63), Color(0xFFFF6090)],
            begin: Alignment.topLeft, end: Alignment.bottomRight),
        textColor: Colors.white,
        titleColor: Colors.white,
        toolbarColor: const Color(0xFF880E4F)),
  ],
  'هندسة': [
    _NoteTemplate(id: 'ac1', name: 'رمادي صخري',
        bgColor: const Color(0xFF37474F),
        gradient: const LinearGradient(
            colors: [Color(0xFF37474F), Color(0xFF546E7A)],
            begin: Alignment.topCenter, end: Alignment.bottomCenter),
        textColor: const Color(0xFFECEFF1),
        titleColor: Colors.white,
        toolbarColor: const Color(0xFF263238)),
    _NoteTemplate(id: 'ac2', name: 'رصاصي',
        bgColor: const Color(0xFF607D8B),
        textColor: Colors.white,
        titleColor: Colors.white,
        toolbarColor: const Color(0xFF37474F)),
    _NoteTemplate(id: 'ac3', name: 'فولاذي',
        bgColor: const Color(0xFF455A64),
        gradient: const LinearGradient(
            colors: [Color(0xFF455A64), Color(0xFF78909C)],
            begin: Alignment.topLeft, end: Alignment.bottomRight),
        textColor: const Color(0xFFECEFF1),
        titleColor: Colors.white,
        toolbarColor: const Color(0xFF263238)),
  ],
  'ألوان': [
    _NoteTemplate(id: 'cl1', name: 'أزرق سماوي',
        bgColor: const Color(0xFFBBDEFB),
        toolbarColor: const Color(0xFF1976D2)),
    _NoteTemplate(id: 'cl2', name: 'أخضر نعناعي',
        bgColor: const Color(0xFFC8E6C9),
        toolbarColor: const Color(0xFF388E3C)),
    _NoteTemplate(id: 'cl3', name: 'برتقالي دافئ',
        bgColor: const Color(0xFFFFE0B2),
        toolbarColor: const Color(0xFFE65100)),
  ],
};

// ─── Paragraph block ─────────────────────────────────────────────────────────

enum _ParaType { normal, bullet, numbered, h1, h2 }

class _Block {
  final TextEditingController ctrl;
  final FocusNode focus;
  bool bold;
  bool italic;
  bool underline;
  bool strike;
  double fontSize;
  Color textColor;
  TextAlign align;
  _ParaType type;

  _Block({
    String text = '',
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.fontSize = 14,
    this.textColor = const Color(0xFF2D2D2D),
    this.align = TextAlign.right,
    this.type = _ParaType.normal,
  })  : ctrl = TextEditingController(text: text),
        focus = FocusNode();

  TextStyle get style => TextStyle(
        fontFamily: 'Cairo',
        fontSize: fontSize,
        fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        fontStyle: italic ? FontStyle.italic : FontStyle.normal,
        decoration: TextDecoration.combine([
          if (underline) TextDecoration.underline,
          if (strike) TextDecoration.lineThrough,
        ]),
        color: textColor,
        height: 1.6,
      );

  void dispose() {
    ctrl.dispose();
    focus.dispose();
  }
}

// ─── Screen ──────────────────────────────────────────────────────────────────

class TxtToPdfScreen extends StatefulWidget {
  const TxtToPdfScreen({super.key});
  @override
  State<TxtToPdfScreen> createState() => _TxtToPdfScreenState();
}

class _TxtToPdfScreenState extends State<TxtToPdfScreen>
    with SingleTickerProviderStateMixin {
  final _titleCtrl = TextEditingController(text: '');
  final _titleFocus = FocusNode();

  final List<_Block> _blocks = [];
  int _activeBlockIdx = 0;

  _NoteTemplate? _template;
  bool _isProcessing = false;
  String _currentCategory = 'ألوان';

  // Current formatting state (mirrors active block)
  bool _bold = false, _italic = false, _underline = false, _strike = false;
  double _fontSize = 14;
  Color _textColor = const Color(0xFF2D2D2D);
  TextAlign _align = TextAlign.right;
  _ParaType _paraType = _ParaType.normal;

  // Bottom toolbar visibility
  bool _showFormatBar = false;

  // Default toolbar color
  Color get _toolbarColor => _template?.toolbarColor ?? const Color(0xFFF6A623);
  Color get _bgColor => _template?.bgColor ?? const Color(0xFFFFF9F0);
  Color get _bodyTextColor => _template?.textColor ?? const Color(0xFF2D2D2D);

  @override
  void initState() {
    super.initState();
    // Start with one empty block
    _addBlock();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _titleFocus.dispose();
    for (final b in _blocks) b.dispose();
    super.dispose();
  }

  void _addBlock({String text = '', int? afterIdx}) {
    final block = _Block(
      text: text,
      fontSize: _fontSize,
      textColor: _bodyTextColor,
      bold: _bold,
      italic: _italic,
      underline: _underline,
      strike: _strike,
      align: _align,
      type: _paraType,
    );
    setState(() {
      if (afterIdx != null) {
        _blocks.insert(afterIdx + 1, block);
        _activeBlockIdx = afterIdx + 1;
      } else {
        _blocks.add(block);
        _activeBlockIdx = _blocks.length - 1;
      }
    });
    Future.microtask(() => block.focus.requestFocus());
  }

  void _syncFormattingFrom(_Block b) {
    setState(() {
      _bold = b.bold;
      _italic = b.italic;
      _underline = b.underline;
      _strike = b.strike;
      _fontSize = b.fontSize;
      _textColor = b.textColor;
      _align = b.align;
      _paraType = b.type;
    });
  }

  void _applyFormat(void Function(_Block b) mutate) {
    if (_activeBlockIdx < _blocks.length) {
      setState(() => mutate(_blocks[_activeBlockIdx]));
      _syncFormattingFrom(_blocks[_activeBlockIdx]);
    }
  }

  // ─── File import ───────────────────────────────────────────────────────────

  Future<void> _importTxt() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'text'],
    );
    if (r?.files.first.path == null) return;
    final content = await File(r!.files.first.path!).readAsString();
    final lines = content.split('\n');

    setState(() {
      for (final b in _blocks) b.dispose();
      _blocks.clear();
    });

    // First non-empty line → title
    bool titleSet = false;
    for (final line in lines) {
      if (!titleSet && line.trim().isNotEmpty) {
        _titleCtrl.text = line.trim();
        titleSet = true;
        continue;
      }
      _addBlock(text: line);
    }
    if (_blocks.isEmpty) _addBlock();
  }

  // ─── PDF export ────────────────────────────────────────────────────────────

  Future<void> _exportPdf() async {
    final allEmpty = _blocks.every((b) => b.ctrl.text.trim().isEmpty)
        && _titleCtrl.text.trim().isEmpty;
    if (allEmpty) {
      _showError('المستند فارغ — أضف نصاً أولاً');
      return;
    }

    setState(() => _isProcessing = true);
    try {
      final bytes = await _buildPdf();
      final dir = await getTemporaryDirectory();
      final title = _titleCtrl.text.trim().isEmpty
          ? 'مستند_${DateTime.now().millisecondsSinceEpoch}'
          : _titleCtrl.text.trim().replaceAll(RegExp(r'[^\w\s؀-ۿ]'), '_');
      final out = File('${dir.path}/$title.pdf');
      await out.writeAsBytes(bytes);

      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => ResultScreen(
          file: out,
          title: 'تم إنشاء PDF بنجاح!',
          subtitle: 'تم تصدير المستند النصي إلى PDF',
          toolId: 'txt_to_pdf',
          toolName: 'نص إلى PDF',
          settings: {
            'القالب': _template?.name ?? 'افتراضي',
            'عدد الفقرات': '${_blocks.length}',
          },
        ),
      ));
    } catch (e) {
      _showError('خطأ في التصدير: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<Uint8List> _buildPdf() async {
    const pageW = 595.0, pageH = 842.0;
    const mL = 55.0, mR = 55.0, mT = 60.0, mB = 60.0;
    final cW = pageW - mL - mR;

    final doc = PdfDocument();
    doc.pageSettings.size = const Size(pageW, pageH);
    doc.pageSettings.margins.all = 0;
    doc.compressionLevel = PdfCompressionLevel.best;

    PdfPage page = doc.pages.add();
    double y = mT;

    void _drawBg(PdfPage p) {
      final bg = _template;
      if (bg?.gradient != null) {
        final grad = bg!.gradient!;
        final colors = (grad as LinearGradient).colors;
        for (int i = 0; i < colors.length - 1; i++) {
          final segH = pageH / (colors.length - 1);
          final c1 = colors[i];
          final c2 = colors[i + 1];
          // Approximate gradient with bands
          for (double dy = 0; dy < segH; dy += 2) {
            final t = dy / segH;
            final r = (c1.r + (c2.r - c1.r) * t).round().clamp(0, 255);
            final g = (c1.g + (c2.g - c1.g) * t).round().clamp(0, 255);
            final b = (c1.b + (c2.b - c1.b) * t).round().clamp(0, 255);
            p.graphics.drawRectangle(
              brush: PdfSolidBrush(PdfColor(r, g, b)),
              bounds: Rect.fromLTWH(0, i * segH + dy, pageW, 2.5),
            );
          }
        }
      } else {
        final c = bg?.bgColor ?? Colors.white;
        p.graphics.drawRectangle(
          brush: PdfSolidBrush(PdfColor(
              (c.r * 255).round().clamp(0, 255),
              (c.g * 255).round().clamp(0, 255),
              (c.b * 255).round().clamp(0, 255))),
          bounds: Rect.fromLTWH(0, 0, pageW, pageH),
        );
      }

      // Lined paper effect
      if (bg?.hasLines == true) {
        final lc = bg!.lineColor;
        final pen = PdfPen(PdfColor(
            (lc.r * 255).round().clamp(0, 255),
            (lc.g * 255).round().clamp(0, 255),
            (lc.b * 255).round().clamp(0, 255)), width: 0.4);
        for (double ly = mT; ly < pageH - mB; ly += 24) {
          p.graphics.drawLine(pen,
              Offset(mL - 10, ly), Offset(pageW - mR + 10, ly));
        }
      }
    }

    _drawBg(page);

    void newPage() {
      page = doc.pages.add();
      _drawBg(page);
      y = mT;
    }

    void ensureSpace(double h) {
      if (y + h > pageH - mB) newPage();
    }

    PdfFont _font(double size, bool bold, bool italic) {
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

    Color _resolveTextColor(_Block b) =>
        b.textColor == const Color(0xFF2D2D2D) && _template != null
            ? _template!.textColor
            : b.textColor;

    // Render title
    if (_titleCtrl.text.trim().isNotEmpty) {
      final titleText = _titleCtrl.text.trim();
      final titleFont = _font(22, true, false);
      final tc = _template?.titleColor ?? const Color(0xFF1A1A2E);
      final titleBrush = PdfSolidBrush(PdfColor(
          (tc.r * 255).round().clamp(0, 255),
          (tc.g * 255).round().clamp(0, 255),
          (tc.b * 255).round().clamp(0, 255)));

      final isRtl = RegExp(r'[؀-ۿ]').hasMatch(titleText);
      final fmt = PdfStringFormat(
        alignment: isRtl ? PdfTextAlignment.right : PdfTextAlignment.left,
        textDirection: isRtl ? PdfTextDirection.rightToLeft : PdfTextDirection.leftToRight,
        lineSpacing: 6,
      );
      final m = titleFont.measureString(titleText,
          layoutArea: Size(cW, double.infinity), format: fmt);
      final h = m.height + 8;
      ensureSpace(h + 16);
      page.graphics.drawString(titleText, titleFont,
          brush: titleBrush,
          bounds: Rect.fromLTWH(mL, y, cW, h + 4),
          format: fmt);
      y += h + 16;

      // Divider line below title
      final lc = _template?.lineColor ?? const Color(0xFFCCCCCC);
      page.graphics.drawLine(
        PdfPen(PdfColor((lc.r * 255).round().clamp(0, 255),
            (lc.g * 255).round().clamp(0, 255),
            (lc.b * 255).round().clamp(0, 255)), width: 0.8),
        Offset(mL, y),
        Offset(mL + cW, y),
      );
      y += 12;
    }

    // Render blocks
    for (int i = 0; i < _blocks.length; i++) {
      final b = _blocks[i];
      String rawText = b.ctrl.text;
      if (rawText.isEmpty) { y += b.fontSize * 0.5; continue; }

      // Prefix for lists
      String prefix = '';
      if (b.type == _ParaType.bullet) prefix = '• ';
      else if (b.type == _ParaType.numbered) prefix = '${i + 1}. ';
      else if (b.type == _ParaType.h1) { /* larger font */ }
      else if (b.type == _ParaType.h2) { /* medium font */ }

      final text = '$prefix$rawText';
      final fs = b.type == _ParaType.h1 ? b.fontSize * 1.6
          : b.type == _ParaType.h2 ? b.fontSize * 1.3
          : b.fontSize;
      final font = _font(fs, b.bold || b.type == _ParaType.h1 || b.type == _ParaType.h2, b.italic);

      final isRtl = RegExp(r'[؀-ۿ]').hasMatch(rawText);
      PdfTextAlignment pdfAlign;
      switch (b.align) {
        case TextAlign.center: pdfAlign = PdfTextAlignment.center;
        case TextAlign.left: pdfAlign = PdfTextAlignment.left;
        case TextAlign.justify: pdfAlign = PdfTextAlignment.justify;
        default: pdfAlign = PdfTextAlignment.right;
      }

      final fmt = PdfStringFormat(
        alignment: pdfAlign,
        textDirection: isRtl ? PdfTextDirection.rightToLeft : PdfTextDirection.leftToRight,
        lineSpacing: fs * 0.4,
      );

      final tc = _resolveTextColor(b);
      final brush = PdfSolidBrush(PdfColor(
          (tc.r * 255).round().clamp(0, 255),
          (tc.g * 255).round().clamp(0, 255),
          (tc.b * 255).round().clamp(0, 255)));

      final m = font.measureString(text,
          layoutArea: Size(cW, double.infinity), format: fmt);
      final lineH = m.height + fs * 0.4;
      ensureSpace(lineH);

      page.graphics.drawString(text, font,
          brush: brush,
          bounds: Rect.fromLTWH(mL, y, cW, lineH + 6),
          format: fmt);

      // Underline/strikethrough approximation
      if (b.underline) {
        page.graphics.drawLine(
          PdfPen(brush.color, width: 0.6),
          Offset(mL, y + lineH - 2),
          Offset(mL + cW, y + lineH - 2),
        );
      }
      if (b.strike) {
        page.graphics.drawLine(
          PdfPen(brush.color, width: 0.6),
          Offset(mL, y + lineH / 2),
          Offset(mL + cW, y + lineH / 2),
        );
      }

      y += lineH + 4;
    }

    try {
      return Uint8List.fromList(doc.saveSync());
    } finally {
      doc.dispose();
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.cairo()),
      backgroundColor: Colors.red.shade700,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  // ─── Theme picker ──────────────────────────────────────────────────────────

  void _openThemePicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ThemePickerSheet(
        currentCategory: _currentCategory,
        selectedTemplate: _template,
        onSelect: (t) => setState(() {
          _template = t;
          // Update active block text colors if using default
          for (final b in _blocks) {
            if (b.textColor == const Color(0xFF2D2D2D)) {
              b.textColor = t?.textColor ?? const Color(0xFF2D2D2D);
            }
          }
        }),
        onCategoryChange: (c) => setState(() => _currentCategory = c),
      ),
    );
  }

  // ─── Color picker ──────────────────────────────────────────────────────────

  void _openColorPicker() {
    const colors = [
      Color(0xFFE91E63), Color(0xFF9C27B0), Colors.black,
      Color(0xFF424242), Color(0xFF757575), Color(0xFF9E9E9E),
      Color(0xFFBDBDBD), Colors.white,
      Color(0xFF1A237E), Color(0xFF1565C0), Color(0xFF0288D1),
      Color(0xFF00BCD4), Color(0xFF4CAF50), Color(0xFFFDD835),
      Color(0xFFFF6F00), Color(0xFFE53935),
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A2E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: const Icon(Icons.close_rounded,
                      color: Color(0xFF8888A8)),
                ),
                const Spacer(),
                Text('Text Color',
                    style: GoogleFonts.spaceGrotesk(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16)),
                const Spacer(),
                const SizedBox(width: 24),
              ],
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: colors.map((c) {
                final sel = _textColor == c;
                return GestureDetector(
                  onTap: () {
                    _applyFormat((b) => b.textColor = c);
                    setState(() => _textColor = c);
                    Navigator.pop(context);
                  },
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: sel ? Colors.white : Colors.transparent,
                        width: 3,
                      ),
                      boxShadow: sel
                          ? [BoxShadow(color: c.withOpacity(0.5), blurRadius: 8)]
                          : null,
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      body: Stack(
        children: [
          // Background (template)
          if (_template?.gradient != null)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(gradient: _template!.gradient),
              ),
            )
          else
            Positioned.fill(child: Container(color: _bgColor)),

          // Lined paper overlay
          if (_template?.hasLines == true)
            Positioned.fill(child: CustomPaint(
              painter: _LinedPaperPainter(
                lineColor: _template!.lineColor,
                topPadding: 100,
              ),
            )),

          // Main content
          SafeArea(
            child: Column(
              children: [
                _buildToolbar(),
                _buildDateBar(),
                Expanded(child: _buildEditor()),
                _buildBottomBar(),
              ],
            ),
          ),

          if (_isProcessing)
            Container(
              color: Colors.black54,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      color: _toolbarColor,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          // Menu
          _ToolbarBtn(
            icon: Icons.more_vert_rounded,
            color: Colors.white,
            onTap: () {},
          ),

          const SizedBox(width: 4),

          // Save button
          GestureDetector(
            onTap: _exportPdf,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(0.5)),
              ),
              child: Text('Save',
                  style: GoogleFonts.spaceGrotesk(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13)),
            ),
          ),

          const SizedBox(width: 8),

          // PDF export icon
          _ToolbarBtn(
            icon: Icons.picture_as_pdf_rounded,
            color: Colors.white,
            onTap: _exportPdf,
          ),

          // Import TXT
          _ToolbarBtn(
            icon: Icons.upload_file_rounded,
            color: Colors.white,
            onTap: _importTxt,
          ),

          const Spacer(),

          // Back
          _ToolbarBtn(
            icon: Icons.arrow_forward_ios_rounded,
            color: Colors.white,
            onTap: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildDateBar() {
    final now = DateTime.now();
    final dateStr = '${now.day.toString().padLeft(2, '0')}.'
        '${now.month.toString().padLeft(2, '0')}.${now.year}';
    return Container(
      color: _bgColor.withOpacity(0.6),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(dateStr,
              style: GoogleFonts.spaceGrotesk(
                  fontSize: 12,
                  color: _bodyTextColor.withOpacity(0.6))),
          const Spacer(),
          GestureDetector(
            onTap: _openThemePicker,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('All',
                    style: GoogleFonts.spaceGrotesk(
                        fontSize: 12,
                        color: _bodyTextColor.withOpacity(0.6))),
                Icon(Icons.expand_more_rounded,
                    color: _bodyTextColor.withOpacity(0.6), size: 18),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditor() {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Title field
          TextField(
            controller: _titleCtrl,
            focusNode: _titleFocus,
            onTap: () => setState(() => _showFormatBar = false),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: _template?.titleColor ?? const Color(0xFF1A1A2E),
              height: 1.4,
            ),
            decoration: InputDecoration(
              hintText: 'Edit title...',
              hintStyle: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: (_template?.titleColor ?? const Color(0xFF1A1A2E))
                    .withOpacity(0.35),
              ),
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
            textDirection: TextDirection.ltr,
            maxLines: null,
          ),

          const SizedBox(height: 12),

          // Paragraph blocks
          ...List.generate(_blocks.length, (i) {
            final b = _blocks[i];
            return Padding(
              padding: EdgeInsets.only(
                bottom: 2,
                left: b.type == _ParaType.bullet || b.type == _ParaType.numbered
                    ? 16 : 0,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (b.type == _ParaType.bullet)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, right: 4),
                      child: Text('•',
                          style: TextStyle(
                              color: _template?.textColor ?? const Color(0xFF2D2D2D),
                              fontSize: b.fontSize)),
                    )
                  else if (b.type == _ParaType.numbered)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, right: 4),
                      child: Text('${i + 1}.',
                          style: TextStyle(
                              color: _template?.textColor ?? const Color(0xFF2D2D2D),
                              fontSize: b.fontSize)),
                    ),
                  Expanded(
                    child: TextField(
                      controller: b.ctrl,
                      focusNode: b.focus,
                      style: b.style.copyWith(
                        color: b.textColor == const Color(0xFF2D2D2D) && _template != null
                            ? _template!.textColor
                            : b.textColor,
                      ),
                      maxLines: null,
                      keyboardType: TextInputType.multiline,
                      textAlign: b.align,
                      decoration: InputDecoration(
                        hintText: i == 0 ? 'ابدأ الكتابة هنا...' : '',
                        hintStyle: TextStyle(
                          color: (_template?.textColor ?? const Color(0xFF2D2D2D))
                              .withOpacity(0.35),
                          fontSize: b.fontSize,
                        ),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        isDense: true,
                      ),
                      onTap: () {
                        setState(() {
                          _activeBlockIdx = i;
                          _showFormatBar = true;
                        });
                        _syncFormattingFrom(b);
                      },
                      onSubmitted: (_) => _addBlock(afterIdx: i),
                    ),
                  ),
                ],
              ),
            );
          }),

          // Add block button
          GestureDetector(
            onTap: () => _addBlock(afterIdx: _blocks.length - 1),
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_circle_outline_rounded,
                      color: _toolbarColor.withOpacity(0.5), size: 20),
                  const SizedBox(width: 8),
                  Text('إضافة فقرة جديدة',
                      style: GoogleFonts.cairo(
                          fontSize: 13,
                          color: _toolbarColor.withOpacity(0.5))),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      color: const Color(0xFF1E1E30).withOpacity(0.95),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Style buttons row (S U I B)
            if (_showFormatBar) ...[
              Container(
                color: const Color(0xFF252540),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _FormatBtn(
                      label: 'S',
                      decoration: TextDecoration.lineThrough,
                      active: _strike,
                      color: _toolbarColor,
                      onTap: () => _applyFormat((b) => b.strike = !b.strike),
                    ),
                    _FormatBtn(
                      label: 'U',
                      decoration: TextDecoration.underline,
                      active: _underline,
                      color: _toolbarColor,
                      onTap: () => _applyFormat((b) => b.underline = !b.underline),
                    ),
                    _FormatBtn(
                      label: 'I',
                      italic: true,
                      active: _italic,
                      color: _toolbarColor,
                      onTap: () => _applyFormat((b) => b.italic = !b.italic),
                    ),
                    _FormatBtn(
                      label: 'B',
                      bold: true,
                      active: _bold,
                      color: _toolbarColor,
                      onTap: () => _applyFormat((b) => b.bold = !b.bold),
                    ),
                  ],
                ),
              ),
            ],

            // Main bottom toolbar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  // Font size
                  GestureDetector(
                    onTap: _showFontSizePicker,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2A40),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF3A3A50)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.expand_more_rounded,
                              color: const Color(0xFF9090C0), size: 16),
                          Text('${_fontSize.toInt()}',
                              style: GoogleFonts.spaceGrotesk(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(width: 2),
                          const Icon(Icons.text_fields_rounded,
                              color: Color(0xFF9090C0), size: 16),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(width: 8),

                  // Numbered list
                  _BottomBarBtn(
                    icon: Icons.format_list_numbered_rounded,
                    active: _paraType == _ParaType.numbered,
                    color: _toolbarColor,
                    onTap: () => _applyFormat((b) {
                      b.type = b.type == _ParaType.numbered
                          ? _ParaType.normal : _ParaType.numbered;
                    }),
                  ),

                  // Bullet list
                  _BottomBarBtn(
                    icon: Icons.format_list_bulleted_rounded,
                    active: _paraType == _ParaType.bullet,
                    color: _toolbarColor,
                    onTap: () => _applyFormat((b) {
                      b.type = b.type == _ParaType.bullet
                          ? _ParaType.normal : _ParaType.bullet;
                    }),
                  ),

                  // Highlight/pen
                  _BottomBarBtn(
                    icon: Icons.draw_rounded,
                    active: false,
                    color: _toolbarColor,
                    onTap: () {},
                  ),

                  // Text color (A)
                  GestureDetector(
                    onTap: _openColorPicker,
                    child: Container(
                      width: 36,
                      height: 36,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF3A3A50)),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('A',
                              style: TextStyle(
                                  color: _textColor,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800)),
                          Container(
                              height: 3,
                              width: 18,
                              color: _textColor),
                        ],
                      ),
                    ),
                  ),

                  // Text format (T - heading)
                  _BottomBarBtn(
                    icon: Icons.title_rounded,
                    active: _paraType == _ParaType.h1,
                    color: _toolbarColor,
                    onTap: () => _applyFormat((b) {
                      b.type = b.type == _ParaType.h1
                          ? _ParaType.normal : _ParaType.h1;
                    }),
                  ),

                  // Theme palette
                  _BottomBarBtn(
                    icon: Icons.palette_rounded,
                    active: _template != null,
                    color: _template?.toolbarColor ?? _toolbarColor,
                    onTap: _openThemePicker,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showFontSizePicker() {
    final sizes = [8.0, 10.0, 12.0, 14.0, 16.0, 18.0, 20.0, 24.0, 28.0, 32.0, 36.0];
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A2E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('حجم الخط',
                style: GoogleFonts.cairo(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 16)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: sizes.map((s) {
                final sel = _fontSize == s;
                return GestureDetector(
                  onTap: () {
                    _applyFormat((b) => b.fontSize = s);
                    setState(() => _fontSize = s);
                    Navigator.pop(context);
                  },
                  child: Container(
                    width: 54,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: sel ? _toolbarColor : const Color(0xFF2A2A40),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: sel ? _toolbarColor : const Color(0xFF3A3A50)),
                    ),
                    child: Text('${s.toInt()}',
                        style: GoogleFonts.spaceGrotesk(
                            color: sel ? Colors.white : const Color(0xFFB0B0C8),
                            fontWeight: FontWeight.w700,
                            fontSize: 14)),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

// ─── Theme picker bottom sheet ────────────────────────────────────────────────

class _ThemePickerSheet extends StatefulWidget {
  final String currentCategory;
  final _NoteTemplate? selectedTemplate;
  final void Function(_NoteTemplate?) onSelect;
  final void Function(String) onCategoryChange;

  const _ThemePickerSheet({
    required this.currentCategory,
    required this.selectedTemplate,
    required this.onSelect,
    required this.onCategoryChange,
  });

  @override
  State<_ThemePickerSheet> createState() => _ThemePickerSheetState();
}

class _ThemePickerSheetState extends State<_ThemePickerSheet> {
  late String _cat;

  @override
  void initState() {
    super.initState();
    _cat = widget.currentCategory;
  }

  @override
  Widget build(BuildContext context) {
    final templates = _kTemplates[_cat] ?? [];

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A2E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFF3A3A50),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 8),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: const Icon(Icons.close_rounded,
                      color: Color(0xFF8888A8)),
                ),
                const Spacer(),
                Text('Theme & Color',
                    style: GoogleFonts.spaceGrotesk(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16)),
                const Spacer(),
                const SizedBox(width: 24),
              ],
            ),
          ),

          // Category tabs (scrollable)
          SizedBox(
            height: 36,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _kCategories.length,
              itemBuilder: (_, i) {
                final cat = _kCategories[i];
                final sel = _cat == cat;
                return GestureDetector(
                  onTap: () {
                    setState(() => _cat = cat);
                    widget.onCategoryChange(cat);
                  },
                  child: Container(
                    margin: const EdgeInsets.only(left: 8),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: sel
                              ? const Color(0xFF4A90D9)
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Dot indicator if has purchased templates
                        if (_kTemplates[cat]?.any((t) => t.id.startsWith('pp') || t.id.startsWith('ar') || t.id.startsWith('wc')) == true)
                          Container(
                            width: 6,
                            height: 6,
                            margin: const EdgeInsets.only(left: 4),
                            decoration: const BoxDecoration(
                              color: Color(0xFF4A90D9),
                              shape: BoxShape.circle,
                            ),
                          ),
                        Text(cat,
                            style: GoogleFonts.cairo(
                              color: sel ? Colors.white : const Color(0xFF8888A8),
                              fontSize: 13,
                              fontWeight: sel ? FontWeight.w700 : FontWeight.normal,
                            )),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 16),

          // Template grid
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                // NONE option
                GestureDetector(
                  onTap: () {
                    widget.onSelect(null);
                    Navigator.pop(context);
                  },
                  child: Container(
                    width: 80,
                    height: 110,
                    margin: const EdgeInsets.only(left: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: widget.selectedTemplate == null
                            ? const Color(0xFF4A90D9)
                            : const Color(0xFF2A2A40),
                        width: widget.selectedTemplate == null ? 2.5 : 1,
                      ),
                    ),
                    child: Center(
                      child: Text('NONE',
                          style: GoogleFonts.spaceGrotesk(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFF9090B0))),
                    ),
                  ),
                ),

                // Template cards
                ...templates.map((t) {
                  final sel = widget.selectedTemplate?.id == t.id;
                  return GestureDetector(
                    onTap: () {
                      widget.onSelect(t);
                      Navigator.pop(context);
                    },
                    child: Container(
                      width: 80,
                      height: 110,
                      margin: const EdgeInsets.only(left: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        gradient: t.gradient as Gradient?,
                        color: t.gradient == null ? t.bgColor : null,
                        border: Border.all(
                          color: sel
                              ? const Color(0xFF4A90D9)
                              : Colors.transparent,
                          width: 2.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.2),
                            blurRadius: 8,
                          )
                        ],
                      ),
                      child: Stack(
                        children: [
                          // Lines for paper templates
                          if (t.hasLines)
                            CustomPaint(
                              size: const Size(80, 110),
                              painter: _LinedPaperPainter(
                                  lineColor: t.lineColor, topPadding: 20),
                            ),
                          // Mini header bar
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: Container(
                              height: 18,
                              decoration: BoxDecoration(
                                color: t.toolbarColor,
                                borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(12)),
                              ),
                            ),
                          ),
                          // Selected checkmark
                          if (sel)
                            Positioned(
                              top: 4,
                              right: 4,
                              child: Container(
                                width: 18,
                                height: 18,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF4A90D9),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.check_rounded,
                                    color: Colors.white, size: 12),
                              ),
                            ),
                          // Template name
                          Positioned(
                            bottom: 6,
                            left: 4,
                            right: 4,
                            child: Text(t.name,
                                style: TextStyle(
                                  fontSize: 9,
                                  color: t.textColor.withOpacity(0.8),
                                  fontWeight: FontWeight.w600,
                                ),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),

          const SizedBox(height: 28),
        ],
      ),
    );
  }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

class _ToolbarBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _ToolbarBtn({required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: color, size: 22),
        ),
      );
}

class _BottomBarBtn extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color color;
  final VoidCallback onTap;
  const _BottomBarBtn(
      {required this.icon, required this.active, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: active ? color.withOpacity(0.2) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon,
              color: active ? color : const Color(0xFF9090C0), size: 20),
        ),
      );
}

class _FormatBtn extends StatelessWidget {
  final String label;
  final bool active;
  final Color color;
  final VoidCallback onTap;
  final bool bold;
  final bool italic;
  final TextDecoration? decoration;

  const _FormatBtn({
    required this.label,
    required this.active,
    required this.color,
    required this.onTap,
    this.bold = false,
    this.italic = false,
    this.decoration,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? color.withOpacity(0.2) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? color.withOpacity(0.5) : Colors.transparent,
            ),
          ),
          child: Text(label,
              style: TextStyle(
                color: active ? color : const Color(0xFF9090C0),
                fontSize: 15,
                fontWeight: bold ? FontWeight.w900 : FontWeight.w500,
                fontStyle: italic ? FontStyle.italic : FontStyle.normal,
                decoration: decoration,
                decorationColor: active ? color : const Color(0xFF9090C0),
              )),
        ),
      );
}

class _LinedPaperPainter extends CustomPainter {
  final Color lineColor;
  final double topPadding;

  const _LinedPaperPainter({required this.lineColor, required this.topPadding});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 0.5;
    for (double y = topPadding; y < size.height; y += 24) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LinedPaperPainter old) =>
      old.lineColor != lineColor || old.topPadding != topPadding;
}
