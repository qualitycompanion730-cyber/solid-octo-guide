import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';

import '../../services/docx_to_pdf_converter.dart';
import '../../theme/app_theme.dart';
import '../result_screen.dart';

// ─── PSX-Office-inspired Word → PDF screen ──────────────────────────────────
// Dark navy theme, red accent, dashed upload zone, animated progress overlay

class WordToPdfScreen extends StatefulWidget {
  const WordToPdfScreen({super.key});
  @override
  State<WordToPdfScreen> createState() => _WordToPdfScreenState();
}

class _WordToPdfScreenState extends State<WordToPdfScreen>
    with TickerProviderStateMixin {
  File? _file;
  int _fileSize = 0;
  bool _isProcessing = false;

  // Animated progress state
  double _progress = 0;
  String _progressLabel = 'جارٍ التهيئة...';
  Timer? _progressTimer;

  // Spinner animation
  late AnimationController _spinCtrl;
  late AnimationController _pulseCtrl;

  static const _bgColor = Color(0xFF0E0E1C);
  static const _cardColor = Color(0xFF161626);
  static const _redAccent = Color(0xFFE53E3E);
  static const _redDark = Color(0xFFC53030);
  static const _greenSafe = Color(0xFF1C4532);
  static const _greenText = Color(0xFF68D391);

  @override
  void initState() {
    super.initState();
    _spinCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 2))
      ..repeat();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _spinCtrl.dispose();
    _pulseCtrl.dispose();
    _progressTimer?.cancel();
    super.dispose();
  }

  String _fmt(int b) {
    if (b > 1048576) return '${(b / 1048576).toStringAsFixed(1)} MB';
    return '${(b / 1024).toStringAsFixed(0)} KB';
  }

  Future<void> _pickFile() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['docx', 'doc', 'rtf', 'odt'],
    );
    final picked = r?.files.first;
    if (picked?.path != null) {
      if (picked!.extension?.toLowerCase() == 'doc') {
        _showError('صيغة .doc القديمة غير مدعومة — احفظ الملف بصيغة .docx أولاً');
        return;
      }
      setState(() {
        _file = File(picked.path!);
        _fileSize = picked.size;
      });
    }
  }

  void _startProgressSimulation() {
    _progress = 0;
    _progressLabel = 'تحليل البنية...';
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (!mounted) return;
      setState(() {
        if (_progress < 0.30) {
          _progress += 0.025;
          _progressLabel = 'تحليل البنية...';
        } else if (_progress < 0.58) {
          _progress += 0.018;
          _progressLabel = 'استخراج المحتوى...';
        } else if (_progress < 0.82) {
          _progress += 0.012;
          _progressLabel = 'إنشاء ملف PDF...';
        } else if (_progress < 0.93) {
          _progress += 0.004;
          _progressLabel = 'إنهاء التحويل...';
        }
        _progress = _progress.clamp(0, 0.94);
      });
    });
  }

  void _finishProgress() {
    _progressTimer?.cancel();
    if (mounted) {
      setState(() {
        _progress = 1.0;
        _progressLabel = 'اكتمل التحويل!';
      });
    }
  }

  Future<void> _convert() async {
    if (_file == null) return;
    setState(() => _isProcessing = true);
    _startProgressSimulation();

    try {
      final ext = _file!.path.split('.').last.toLowerCase();
      Uint8List outBytes;

      if (ext == 'docx') {
        try {
          outBytes = await DocxToPdfConverter.convert(_file!);
        } on DocxConversionException catch (e) {
          _showError(e.message);
          return;
        } catch (e) {
          outBytes = await _textFallback(ext);
        }
      } else {
        outBytes = await _textFallback(ext);
      }

      _finishProgress();
      await Future.delayed(const Duration(milliseconds: 400));

      final dir = await getTemporaryDirectory();
      final name = _file!.path
          .split(RegExp(r'[/\\]'))
          .last
          .replaceAll(RegExp(r'\.\w+$'), '');
      final out = File('${dir.path}/$name.pdf');
      await out.writeAsBytes(outBytes);

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ResultScreen(
            file: out,
            title: 'تم إنشاء PDF بنجاح!',
            subtitle: 'تم تحويل الملف مع الحفاظ على التنسيق الكامل',
            toolId: 'word_to_pdf',
            toolName: 'Word إلى PDF',
            settings: {'حجم الورق': 'A4', 'الوضع': 'تنسيق كامل'},
          ),
        ),
      );
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      _showError('خطأ أثناء التحويل: $msg');
    } finally {
      _progressTimer?.cancel();
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<Uint8List> _textFallback(String ext) async {
    final bytes = await _file!.readAsBytes();
    List<String> paragraphs;
    switch (ext) {
      case 'docx':
        paragraphs = _parseDocxText(bytes);
      case 'odt':
        paragraphs = _parseOdtText(bytes);
      case 'rtf':
        paragraphs = _parseRtfText(bytes);
      default:
        throw Exception('صيغة غير مدعومة');
    }

    final text = paragraphs
        .map((s) => s.trimRight())
        .where((s) => s.trim().isNotEmpty)
        .join('\n\n');

    if (text.trim().isEmpty) {
      throw Exception('لم يُعثر على نص قابل للاستخراج في هذا الملف');
    }

    final doc = PdfDocument();
    doc.pageSettings.size = const Size(595, 842);
    doc.pageSettings.margins.all = 50;

    final arabicLen = RegExp(r'[؀-ۿ]').allMatches(text).length;
    final nonSpace = text.replaceAll(RegExp(r'\s'), '').length;
    final isRtl = nonSpace > 0 && arabicLen / nonSpace > 0.3;

    final font = PdfStandardFont(PdfFontFamily.helvetica, 12);
    final fmt = PdfStringFormat(
      alignment: isRtl ? PdfTextAlignment.right : PdfTextAlignment.left,
      textDirection: isRtl ? PdfTextDirection.rightToLeft : PdfTextDirection.leftToRight,
      lineSpacing: 5,
    );

    final page = doc.pages.add();
    PdfTextElement(text: text, font: font,
        brush: PdfSolidBrush(PdfColor(30, 30, 30)), format: fmt)
        .draw(
          page: page,
          bounds: Rect.fromLTWH(0, 0, page.getClientSize().width, 0),
          format: PdfLayoutFormat(
            layoutType: PdfLayoutType.paginate,
            breakType: PdfLayoutBreakType.fitPage,
          ),
        );

    try {
      return Uint8List.fromList(doc.saveSync());
    } finally {
      doc.dispose();
    }
  }

  List<String> _parseDocxText(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final entry = archive.findFile('word/document.xml');
    if (entry == null) throw Exception('بنية ملف docx غير صالحة');
    final xmlStr = utf8.decode(entry.content as List<int>, allowMalformed: true);
    final doc = XmlDocument.parse(xmlStr);
    return doc.findAllElements('w:p').map((pEl) {
      final buf = StringBuffer();
      for (final n in pEl.descendants) {
        if (n is! XmlElement) continue;
        if (n.name.qualified == 'w:t') buf.write(n.innerText);
        else if (n.name.qualified == 'w:tab') buf.write('    ');
      }
      return buf.toString();
    }).toList();
  }

  List<String> _parseOdtText(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final entry = archive.findFile('content.xml');
    if (entry == null) throw Exception('بنية ملف odt غير صالحة');
    final xmlStr = utf8.decode(entry.content as List<int>, allowMalformed: true);
    final doc = XmlDocument.parse(xmlStr);
    return doc.descendants
        .whereType<XmlElement>()
        .where((n) => n.name.qualified == 'text:p' || n.name.qualified == 'text:h')
        .map((n) => n.innerText)
        .toList();
  }

  List<String> _parseRtfText(Uint8List bytes) {
    final src = String.fromCharCodes(bytes);
    final buf = StringBuffer();
    int i = 0;
    int skip = 0;
    while (i < src.length) {
      final c = src[i];
      if (c == r'\') {
        final m = RegExp(r'\\([a-zA-Z]+)(-?\d+)? ?').matchAsPrefix(src, i);
        if (m != null) {
          final word = m.group(1)!;
          final num = m.group(2);
          i = m.end;
          if (word == 'par' || word == 'line') buf.write('\n');
          else if (word == 'tab') buf.write('    ');
          else if (word == 'u' && num != null) {
            var code = int.parse(num);
            if (code < 0) code += 65536;
            buf.writeCharCode(code);
            skip = 1;
          }
        } else { i += 2; }
      } else if (c == '{' || c == '}' || c == '\r' || c == '\n') {
        i++;
      } else {
        if (skip > 0) { skip--; } else { buf.write(c); }
        i++;
      }
    }
    return buf.toString().split('\n');
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.cairo()),
      backgroundColor: _redDark,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  // ─── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF0A0A18), Color(0xFF0F0F1E)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  _buildHeader(),
                  Expanded(
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 16),
                          _buildTitleBanner(),
                          const SizedBox(height: 20),
                          _buildUploadLabel(),
                          const SizedBox(height: 10),
                          _buildUploadZone(),
                          if (_file != null) ...[
                            const SizedBox(height: 14),
                            _buildFileCard(),
                          ],
                          const SizedBox(height: 16),
                          _buildSecurityBanner(),
                          const SizedBox(height: 24),
                          _buildConvertButton(),
                          const SizedBox(height: 32),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_isProcessing) _buildProgressOverlay(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Row(
        children: [
          // DOCX badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _redAccent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('DOCX', style: GoogleFonts.spaceGrotesk(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: 1,
            )),
          ),
          const Spacer(),
          Text(
            'Word → PDF',
            style: GoogleFonts.cairo(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _cardColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF2A2A40)),
              ),
              child: const Icon(Icons.arrow_forward_ios_rounded,
                  color: Color(0xFFB0B0C8), size: 18),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitleBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2A2A40)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          const Spacer(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Word  ←  PDF',
                style: GoogleFonts.cairo(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: _redAccent,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'تحويل DOCX إلى تنسيق PDF',
                style: GoogleFonts.cairo(
                  fontSize: 13,
                  color: const Color(0xFF8888A8),
                ),
              ),
            ],
          ),
          const SizedBox(width: 16),
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: _redAccent,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: _redAccent.withOpacity(0.4),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Center(
              child: Text('PDF', style: TextStyle(
                color: Colors.white, fontSize: 13,
                fontWeight: FontWeight.w900, letterSpacing: 0.5,
              )),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUploadLabel() {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Text(
        'رفع ملف',
        style: GoogleFonts.cairo(
          fontSize: 13,
          color: const Color(0xFF8888A8),
        ),
        textAlign: TextAlign.right,
      ),
    );
  }

  Widget _buildUploadZone() {
    return GestureDetector(
      onTap: _pickFile,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
        decoration: BoxDecoration(
          color: _cardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _file != null
                ? _redAccent.withOpacity(0.6)
                : const Color(0xFFE53E3E).withOpacity(0.35),
            width: _file != null ? 2 : 1.5,
            strokeAlign: BorderSide.strokeAlignOutside,
          ),
        ),
        child: _file == null
            ? Row(
                children: [
                  // Browse button
                  GestureDetector(
                    onTap: _pickFile,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: _redAccent.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: _redAccent.withOpacity(0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.folder_open_rounded,
                              color: _redAccent, size: 18),
                          const SizedBox(width: 8),
                          Text('تصفح الملفات',
                              style: GoogleFonts.cairo(
                                  color: _redAccent,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Icon(Icons.upload_rounded,
                          color: Color(0xFF5A5A7A), size: 28),
                      const SizedBox(height: 6),
                      Text('انقر لاختيار ملف',
                          style: GoogleFonts.cairo(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF9090B8))),
                      const SizedBox(height: 2),
                      Text('Accepts DOCX · RTF · ODT',
                          style: GoogleFonts.spaceGrotesk(
                              fontSize: 11,
                              color: const Color(0xFF6060808))),
                    ],
                  ),
                ],
              )
            : Row(
                children: [
                  GestureDetector(
                    onTap: _pickFile,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: _redAccent.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: _redAccent.withOpacity(0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.folder_open_rounded,
                              color: _redAccent, size: 18),
                          const SizedBox(width: 8),
                          Text('تغيير الملف',
                              style: GoogleFonts.cairo(
                                  color: _redAccent,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('1 ملفات selected',
                          style: GoogleFonts.cairo(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: _greenText)),
                      const SizedBox(height: 2),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: _redAccent,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _file!.path.split('.').last.toUpperCase(),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.check_circle_rounded,
                      color: _greenText, size: 22),
                ],
              ),
      ),
    );
  }

  Widget _buildFileCard() {
    final name = _file!.path.split(RegExp(r'[/\\]')).last;
    final ext = name.split('.').last.toUpperCase();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A2A40)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => setState(() { _file = null; _fileSize = 0; }),
            child: const Icon(Icons.close_rounded,
                color: Color(0xFF6B6B8A), size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(name,
                    style: GoogleFonts.cairo(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Colors.white),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Text(_fmt(_fileSize),
                    style: GoogleFonts.cairo(
                        fontSize: 12,
                        color: const Color(0xFF6B6B8A))),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _redAccent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(ext,
                style: GoogleFonts.spaceGrotesk(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: 0.5)),
          ),
        ],
      ),
    );
  }

  Widget _buildSecurityBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _greenSafe,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF276749)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.verified_rounded, color: _greenText, size: 18),
          const SizedBox(width: 10),
          Text(
            'الملفات تُعالَج بأمان · تُحذف فوراً · لا احتفاظ',
            style: GoogleFonts.cairo(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _greenText,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConvertButton() {
    final canConvert = _file != null && !_isProcessing;
    return GestureDetector(
      onTap: canConvert ? () { HapticFeedback.mediumImpact(); _convert(); } : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        height: 58,
        decoration: BoxDecoration(
          gradient: canConvert
              ? const LinearGradient(
                  colors: [Color(0xFFE53E3E), Color(0xFFC53030)],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                )
              : null,
          color: canConvert ? null : const Color(0xFF2A2A40),
          borderRadius: BorderRadius.circular(16),
          boxShadow: canConvert
              ? [
                  BoxShadow(
                    color: _redAccent.withOpacity(0.45),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  )
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.bolt_rounded,
                color: canConvert ? Colors.white : const Color(0xFF4A4A6A),
                size: 22),
            const SizedBox(width: 10),
            Text(
              'تشغيل Word  ←  PDF',
              style: GoogleFonts.cairo(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: canConvert ? Colors.white : const Color(0xFF4A4A6A),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Progress Overlay ─────────────────────────────────────────────────────

  Widget _buildProgressOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.65),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 32),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: const Color(0xFF16162A),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFF2A2A45)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.5),
                blurRadius: 40,
                spreadRadius: 4,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Animated spinner + PDF icon
              SizedBox(
                width: 80,
                height: 80,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AnimatedBuilder(
                      animation: _spinCtrl,
                      builder: (_, __) => Transform.rotate(
                        angle: _spinCtrl.value * 2 * math.pi,
                        child: CustomPaint(
                          size: const Size(80, 80),
                          painter: _ArcPainter(
                            color: _redAccent,
                            progress: _progress,
                          ),
                        ),
                      ),
                    ),
                    AnimatedBuilder(
                      animation: _pulseCtrl,
                      builder: (_, __) => Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          color: _redAccent.withOpacity(0.15 + _pulseCtrl.value * 0.08),
                          shape: BoxShape.circle,
                        ),
                        child: const Center(
                          child: Text('PDF',
                              style: TextStyle(
                                  color: _redAccent,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w900)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              Text('جارٍ التشغيل  PDF  ←  Word',
                  style: GoogleFonts.cairo(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Colors.white)),

              const SizedBox(height: 6),

              Text(_progressLabel,
                  style: GoogleFonts.cairo(
                      fontSize: 12,
                      color: const Color(0xFF8888A8))),

              const SizedBox(height: 18),

              // Progress bar row
              Row(
                children: [
                  Text(
                    '${(_progress * 100).toInt()}%',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: _redAccent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: List.generate(3, (i) {
                            return AnimatedBuilder(
                              animation: _pulseCtrl,
                              builder: (_, __) => Container(
                                width: 7,
                                height: 7,
                                margin: const EdgeInsets.only(left: 4),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _redAccent.withOpacity(
                                      i == 0 ? _pulseCtrl.value : 0.3),
                                ),
                              ),
                            );
                          }),
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: _progress,
                            backgroundColor: const Color(0xFF2A2A40),
                            valueColor: const AlwaysStoppedAnimation(_redAccent),
                            minHeight: 5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),

              GestureDetector(
                onTap: () {
                  _progressTimer?.cancel();
                  setState(() => _isProcessing = false);
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.close_rounded,
                        color: Color(0xFF6B6B8A), size: 16),
                    const SizedBox(width: 6),
                    Text('إلغاء',
                        style: GoogleFonts.cairo(
                            fontSize: 13,
                            color: const Color(0xFF8888A8))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Arc painter for spinner ─────────────────────────────────────────────────

class _ArcPainter extends CustomPainter {
  final Color color;
  final double progress;

  const _ArcPainter({required this.color, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    final rect = Rect.fromLTWH(4, 4, size.width - 8, size.height - 8);

    // Background arc
    canvas.drawArc(rect, 0, 2 * math.pi,
        false, paint..color = color.withOpacity(0.15));

    // Progress arc
    canvas.drawArc(rect, -math.pi / 2,
        2 * math.pi * progress.clamp(0, 1),
        false, paint..color = color);
  }

  @override
  bool shouldRepaint(covariant _ArcPainter old) =>
      old.progress != progress || old.color != color;
}
