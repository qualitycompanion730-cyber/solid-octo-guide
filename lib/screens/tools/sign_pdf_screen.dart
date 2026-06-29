// ═══════════════════════════════════════════════════════════════════════════
//  توقيع PDF — إعادة بناء كاملة: سير عمل خطي + سحب التوقيع فوق المستند
// ═══════════════════════════════════════════════════════════════════════════
//
//  الفرق الجوهري عن النسخة السابقة (التي كانت تستخدم 3 تبويبات متوازية
//  ونظام "اختر موضعاً جاهزاً ثم عاين"):
//
//  1. التنقل: سير عمل خطي بـ 3 مراحل واضحة (اختيار → رسم → وضع ومراجعة)
//     بدل TabBar. كل مرحلة لها زر "متابعة" واحد، ولا يمكن الوصول لمرحلة
//     لاحقة دون إكمال السابقة — هذا يطابق منطق العملية الفعلي (لا معنى
//     لضبط الموضع قبل وجود توقيع تضبط موضعه).
//
//  2. الوضع: التوقيع عنصر Stack حر فوق صورة حقيقية للصفحة (مُرمَّزة عبر
//     pdfx/PDFium بأبعاد دقيقة معروفة)، يُسحَب ويُحجَّم مباشرة بالإصبع —
//     لا قوائم "أسفل اليسار/الوسط/اليمين" جاهزة، ولا تبويب معاينة منفصل؛
//     ما تراه هو ما سيُحفَظ، بنفس منطق Adobe Fill & Sign/DocuSign.
//
//  راجع pdf_page_render_service.dart للشرح التقني الكامل لسبب الحاجة إلى
//  pdfx، وdraggable_signature_overlay.dart لمنطق السحب/التحجيم وكيف تُترجَم
//  حركة الإصبع إلى نسب مستقلة عن حجم الشاشة.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../../theme/app_theme.dart';
import '../../pdf_engine/pdf_page_render_service.dart';
import '../result_screen.dart';
import 'draggable_signature_overlay.dart';

class _SigPoint {
  final Offset? point;
  const _SigPoint(this.point);
}

/// مراحل سير العمل الخطي. الترتيب هنا هو ترتيب التنقل الفعلي — لا تُستخدَم
/// كفهارس TabBar، بل كحالة واحدة تتحكم بأي شاشة فرعية تُبنى.
enum _Step { pickFile, drawSignature, placeAndReview }

class SignPdfScreen extends StatefulWidget {
  const SignPdfScreen({super.key});
  @override
  State<SignPdfScreen> createState() => _SignPdfScreenState();
}

class _SignPdfScreenState extends State<SignPdfScreen> {
  _Step _step = _Step.pickFile;

  File? _file;
  int _pageCount = 0;

  // ── رسم التوقيع ──
  final List<_SigPoint> _sigPoints = [];
  Color _penColor = Colors.black;
  double _penWidth = 2.5;
  bool get _hasSignature => _sigPoints.isNotEmpty;
  final _sigDrawKey = GlobalKey();
  Uint8List? _signatureBytes;
  double _signatureAspect = 3.0; // احتياط قبل أول _captureSignature فعلي

  final _penColors = [
    Colors.black,
    const Color(0xFF1A365D),
    const Color(0xFF702459),
    const Color(0xFF1D4044),
    const Color(0xFF553C9A),
  ];
  final _penWidths = [1.5, 2.5, 4.0, 6.0];

  // ── الوضع والمراجعة ──
  final _renderService = PdfPageRenderService();
  int _displayedPage = 1;
  RenderedPdfPage? _renderedPage;
  bool _isRenderingPage = false;
  String? _renderError;
  SignaturePlacement? _placement;

  /// نطبّق التوقيع على هذه الصفحة فقط افتراضياً (آخر صفحة)، والمستخدم
  /// يستطيع التنقل لصفحة أخرى من شريط الصفحات في مرحلة الوضع — عند
  /// التنقل، نُطبَّق التوقيع على الصفحة المعروضة حالياً عند الحفظ.
  bool _applyToAllPages = false;

  bool _isProcessing = false;

  String _formatSize(int b) {
    if (b > 1048576) return '${(b / 1048576).toStringAsFixed(1)} MB';
    return '${(b / 1024).toStringAsFixed(0)} KB';
  }

  // ─────────────────────────────────────────────────────────────────────
  // المرحلة 1: اختيار الملف
  // ─────────────────────────────────────────────────────────────────────

  Future<void> _pickFile() async {
    final r = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (r?.files.first.path == null) return;
    final f = File(r!.files.first.path!);
    try {
      final doc = PdfDocument(inputBytes: await f.readAsBytes());
      final count = doc.pages.count;
      doc.dispose();
      setState(() {
        _file = f;
        _pageCount = count;
        _displayedPage = count; // آخر صفحة كافتراضي، كالنسخة السابقة
      });
    } catch (_) {
      _err('تعذّر قراءة الملف — تأكد أنه PDF صالح.');
    }
  }

  void _goToDrawStep() {
    if (_file == null) {
      _err('اختر ملف PDF أولاً');
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() => _step = _Step.drawSignature);
  }

  // ─────────────────────────────────────────────────────────────────────
  // المرحلة 2: رسم التوقيع
  // ─────────────────────────────────────────────────────────────────────

  Rect? _signatureBoundingBox() {
    double? minX, minY, maxX, maxY;
    for (final p in _sigPoints) {
      final pt = p.point;
      if (pt == null) continue;
      minX = (minX == null) ? pt.dx : math.min(minX, pt.dx);
      minY = (minY == null) ? pt.dy : math.min(minY, pt.dy);
      maxX = (maxX == null) ? pt.dx : math.max(maxX, pt.dx);
      maxY = (maxY == null) ? pt.dy : math.max(maxY, pt.dy);
    }
    if (minX == null || minY == null || maxX == null || maxY == null) {
      return null;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// يرسم ضربات القلم مباشرة على قماش شفاف جديد (لا يُصوِّر RepaintBoundary
  /// بخلفيته البيضاء — نفس الإصلاح الجذري من النسخة السابقة، محفوظ هنا
  /// لأنه يحل مشكلة حقيقية موثّقة: التقاط RepaintBoundary بالكامل يجلب
  /// خلفية بيضاء صلدة تُغطّي محتوى الصفحة عند الرسم).
  Future<Uint8List?> _captureSignature() async {
    final bbox = _signatureBoundingBox();
    if (bbox == null || bbox.width <= 0 || bbox.height <= 0) return null;

    const margin = 12.0;
    const pixelRatio = 3.0;
    final originX = bbox.left - margin;
    final originY = bbox.top - margin;
    final w = bbox.width + margin * 2;
    final h = bbox.height + margin * 2;
    if (w <= 0 || h <= 0) return null;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, w * pixelRatio, h * pixelRatio),
    );
    canvas.scale(pixelRatio);
    canvas.translate(-originX, -originY);

    final paint = Paint()
      ..color = _penColor
      ..strokeWidth = _penWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (int i = 0; i < _sigPoints.length - 1; i++) {
      final cur = _sigPoints[i];
      final nxt = _sigPoints[i + 1];
      if (cur.point != null && nxt.point != null) {
        canvas.drawLine(cur.point!, nxt.point!, paint);
      }
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(
      (w * pixelRatio).round(),
      (h * pixelRatio).round(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return null;
    setState(() => _signatureAspect = w / h);
    return data.buffer.asUint8List();
  }

  Future<void> _goToPlaceStep() async {
    if (!_hasSignature) {
      _err('ارسم توقيعك أولاً');
      return;
    }
    final bytes = await _captureSignature();
    if (bytes == null) {
      _err('تعذّر معالجة التوقيع، حاول الرسم مجدداً');
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() {
      _signatureBytes = bytes;
      _step = _Step.placeAndReview;
    });
    await _loadPageForDisplay(_displayedPage);
  }

  void _clearSignature() {
    setState(() {
      _sigPoints.clear();
      _signatureBytes = null;
    });
  }

  // ─────────────────────────────────────────────────────────────────────
  // المرحلة 3: الوضع والمراجعة
  // ─────────────────────────────────────────────────────────────────────

  Future<void> _loadPageForDisplay(int pageNumber) async {
    if (_file == null) return;
    setState(() {
      _isRenderingPage = true;
      _renderError = null;
    });
    try {
      final rendered = await _renderService.renderPage(
        filePath: _file!.path,
        pageNumber: pageNumber,
      );
      if (!mounted) return;
      setState(() {
        _renderedPage = rendered;
        _isRenderingPage = false;
        // موضع افتراضي منطقي: أسفل يمين الصفحة (متّسق مع اتجاه RTL)، بعرض
        // 28% من عرض الصفحة — فقط عند أول عرض لكل صفحة، لا نُعيد ضبطه إن
        // كان المستخدم قد ضبطه بالفعل في هذه الجلسة لهذه الصفحة بعينها.
        _placement ??= const SignaturePlacement(
          xRatio: 0.62,
          yRatio: 0.82,
          widthRatio: 0.28,
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isRenderingPage = false;
        _renderError = 'تعذّر عرض الصفحة: $e';
      });
    }
  }

  Future<void> _changeDisplayedPage(int newPage) async {
    if (newPage < 1 || newPage > _pageCount || newPage == _displayedPage) {
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _displayedPage = newPage);
    await _loadPageForDisplay(newPage);
  }

  /// المنطق المشترك بين الحفظ النهائي: يرسم صورة التوقيع على صفحة/صفحات
  /// المستند الحقيقي عبر Syncfusion، باستخدام نسب _placement المضروبة في
  /// أبعاد الصفحة الحقيقية بالنقاط — لا حاجة لأي تحويل وحدات وسيط لأن
  /// pdfx وSyncfusion يستخدمان كلاهما النقطة (1/72 إنش) كوحدة أساس.
  Future<List<int>?> _renderSigned() async {
    if (_file == null || _signatureBytes == null || _placement == null) {
      return null;
    }
    final placement = _placement!;
    final pdfBytes = await _file!.readAsBytes();
    final doc = PdfDocument(inputBytes: pdfBytes);

    final pagesToSign = _applyToAllPages
        ? List.generate(doc.pages.count, (i) => i)
        : [(_displayedPage - 1).clamp(0, doc.pages.count - 1)];

    final sigBitmap = PdfBitmap(_signatureBytes!);

    for (final pi in pagesToSign) {
      if (pi >= doc.pages.count) continue;
      final page = doc.pages[pi];
      final size = page.size;
      final w = placement.widthRatio * size.width;
      final h = w / _signatureAspect;
      final x = placement.xRatio * size.width;
      final y = placement.yRatio * size.height;
      page.graphics.drawImage(sigBitmap, Rect.fromLTWH(x, y, w, h));
    }

    final outBytes = doc.saveSync();
    doc.dispose();
    return outBytes;
  }

  Future<void> _confirmSign() async {
    setState(() => _isProcessing = true);
    try {
      final outBytes = await _renderSigned();
      if (outBytes == null) {
        _err('تعذّر إنشاء الملف الموقَّع');
        return;
      }
      final dir = await getTemporaryDirectory();
      final name = _file!.path.split('/').last.replaceAll('.pdf', '');
      final out = File('${dir.path}/${name}_موقّع.pdf');
      await out.writeAsBytes(outBytes);

      if (!mounted) return;
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ResultScreen(
                    file: out,
                    title: 'تم التوقيع!',
                    subtitle: 'تم إضافة التوقيع إلى الملف بنجاح',
                    toolId: 'sign_pdf',
                    toolName: 'توقيع PDF',
                    settings: {
                      'الصفحات':
                          _applyToAllPages ? 'جميع الصفحات' : 'صفحة $_displayedPage',
                    },
                  )));
    } catch (e) {
      _err('خطأ: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _err(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.cairo()),
      backgroundColor: Colors.red.shade700,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ─────────────────────────────────────────────────────────────────────
  // البناء العام: شريط علوي ثابت (عنوان + مؤشر خطوات) فوق محتوى المرحلة
  // الحالية، مطابقاً لأسلوب التنقل الخطي في تطبيقات التوقيع الاحترافية.
  // ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const accentDark = Color(0xFF2D3748);

    return Scaffold(
      backgroundColor: isDark ? AppTheme.bgDark : const Color(0xFFF5F5FF),
      body: Container(
        decoration: BoxDecoration(
          gradient: isDark
              ? AppTheme.bgGradient
              : const LinearGradient(
                  colors: [Color(0xFFF5F5FF), Color(0xFFEEEEFF)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(isDark, accentDark),
              _buildStepIndicator(accentDark),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  child: switch (_step) {
                    _Step.pickFile =>
                      _buildPickFileStep(isDark, accentDark),
                    _Step.drawSignature =>
                      _buildDrawStep(isDark, accentDark),
                    _Step.placeAndReview =>
                      _buildPlaceStep(isDark, accentDark),
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(bool isDark, Color accentDark) {
    final canGoBack = _step != _Step.pickFile;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(children: [
        GestureDetector(
          onTap: () {
            HapticFeedback.lightImpact();
            if (canGoBack) {
              setState(() {
                _step = _Step.values[_step.index - 1];
              });
            } else {
              Navigator.pop(context);
            }
          },
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: isDark ? AppTheme.bgCardLight : Colors.white,
              border: Border.all(color: AppTheme.divider),
            ),
            child: const Icon(Icons.arrow_back_ios_new_rounded,
                size: 18, color: AppTheme.textSecondary),
          ),
        ),
        const SizedBox(width: 14),
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient:
                LinearGradient(colors: [accentDark, const Color(0xFF4A5568)]),
          ),
          child: const Icon(Icons.draw_rounded, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 10),
        Text('توقيع PDF',
            style: GoogleFonts.cairo(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
      ]),
    );
  }

  /// مؤشر خطوات أفقي بسيط (1 → 2 → 3) يوضّح للمستخدم أين هو في العملية
  /// وكم خطوة تبقّت — عنصر أساسي في أي سير عمل خطي محترف، غائب تماماً عن
  /// تصميم التبويبات القديم.
  Widget _buildStepIndicator(Color accentDark) {
    const labels = ['الملف', 'التوقيع', 'الوضع والحفظ'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
      child: Row(
        children: List.generate(labels.length * 2 - 1, (i) {
          if (i.isOdd) {
            final leftDone = (i - 1) ~/ 2 < _step.index;
            return Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: leftDone
                    ? accentDark
                    : accentDark.withValues(alpha: 0.15),
              ),
            );
          }
          final stepIdx = i ~/ 2;
          final isDone = stepIdx < _step.index;
          final isCurrent = stepIdx == _step.index;
          return Column(children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isDone || isCurrent
                    ? accentDark
                    : accentDark.withValues(alpha: 0.12),
              ),
              child: Center(
                child: isDone
                    ? const Icon(Icons.check_rounded,
                        color: Colors.white, size: 15)
                    : Text('${stepIdx + 1}',
                        style: GoogleFonts.cairo(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: isCurrent
                                ? Colors.white
                                : accentDark.withValues(alpha: 0.5))),
              ),
            ),
            const SizedBox(height: 4),
            Text(labels[stepIdx],
                style: GoogleFonts.cairo(
                    fontSize: 9.5,
                    fontWeight: isCurrent ? FontWeight.w800 : FontWeight.w500,
                    color: isCurrent
                        ? accentDark
                        : AppTheme.textMuted)),
          ]);
        }),
      ),
    );
  }

  // ── المرحلة 1 ──

  Widget _buildPickFileStep(bool isDark, Color accentDark) {
    return Padding(
      key: const ValueKey('step1'),
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: Center(
            child: GestureDetector(
              onTap: _pickFile,
              child: Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: isDark ? AppTheme.bgCardLight : Colors.white,
                  border: Border.all(
                    color: _file != null
                        ? accentDark.withValues(alpha: 0.6)
                        : AppTheme.divider,
                    width: _file != null ? 2 : 1,
                  ),
                ),
                child: _file == null
                    ? Column(mainAxisSize: MainAxisSize.min, children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                  colors: [accentDark, const Color(0xFF4A5568)])),
                          child: const Icon(Icons.upload_file_rounded,
                              color: Colors.white, size: 30),
                        ),
                        const SizedBox(height: 16),
                        Text('اختر ملف PDF',
                            style: GoogleFonts.cairo(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: isDark
                                    ? AppTheme.textPrimary
                                    : const Color(0xFF1A1A2E))),
                        const SizedBox(height: 4),
                        Text('اضغط لاختيار الملف المطلوب توقيعه',
                            style: GoogleFonts.cairo(
                                fontSize: 12.5, color: AppTheme.textMuted)),
                      ])
                    : Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.picture_as_pdf_rounded,
                            color: Color(0xFF4A5568), size: 46),
                        const SizedBox(height: 12),
                        Text(_file!.path.split('/').last,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.cairo(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: isDark
                                    ? AppTheme.textPrimary
                                    : const Color(0xFF1A1A2E))),
                        const SizedBox(height: 4),
                        Text(
                            '$_pageCount صفحة • ${_formatSize(_file!.lengthSync())}',
                            style: GoogleFonts.cairo(
                                fontSize: 12, color: AppTheme.textMuted)),
                        const SizedBox(height: 14),
                        Text('اضغط لاختيار ملف آخر',
                            style: GoogleFonts.cairo(
                                fontSize: 11.5,
                                color: accentDark,
                                fontWeight: FontWeight.w700)),
                      ]),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _primaryButton(
          label: 'متابعة لرسم التوقيع',
          icon: Icons.arrow_forward_rounded,
          enabled: _file != null,
          onTap: _goToDrawStep,
          accentDark: accentDark,
        ),
      ]),
    );
  }

  // ── المرحلة 2 ──

  Widget _buildDrawStep(bool isDark, Color accentDark) {
    return Padding(
      key: const ValueKey('step2'),
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text('ارسم توقيعك',
              style: GoogleFonts.cairo(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
          const Spacer(),
          if (_hasSignature)
            TextButton.icon(
              onPressed: _clearSignature,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: Text('مسح', style: GoogleFonts.cairo(fontSize: 12)),
              style: TextButton.styleFrom(
                  foregroundColor: Colors.red.shade400,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4)),
            ),
        ]),
        const SizedBox(height: 10),
        Expanded(
          child: RepaintBoundary(
            key: _sigDrawKey,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: Colors.white,
                border: Border.all(
                  color: _hasSignature
                      ? accentDark.withValues(alpha: 0.5)
                      : AppTheme.divider,
                  width: _hasSignature ? 2 : 1,
                ),
              ),
              child: Stack(children: [
                if (!_hasSignature)
                  Center(
                      child: Text('ارسم توقيعك هنا',
                          style: GoogleFonts.cairo(
                              fontSize: 14, color: Colors.grey.shade400))),
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: GestureDetector(
                    onPanStart: (d) {
                      setState(() => _sigPoints.add(_SigPoint(d.localPosition)));
                    },
                    onPanUpdate: (d) {
                      setState(() => _sigPoints.add(_SigPoint(d.localPosition)));
                    },
                    onPanEnd: (_) {
                      setState(() => _sigPoints.add(const _SigPoint(null)));
                    },
                    child: CustomPaint(
                      painter: _SigPainter(_sigPoints, _penColor, _penWidth),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('لون التوقيع',
            style: GoogleFonts.cairo(
                fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
        const SizedBox(height: 8),
        Row(
          children: _penColors
              .map((c) => GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _penColor = c);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.only(right: 10),
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: c,
                        border: Border.all(
                            color: _penColor == c
                                ? accentDark
                                : Colors.transparent,
                            width: 3),
                        boxShadow: [
                          BoxShadow(color: c.withValues(alpha: 0.4), blurRadius: 8)
                        ],
                      ),
                    ),
                  ))
              .toList(),
        ),
        const SizedBox(height: 14),
        Text('سماكة التوقيع',
            style: GoogleFonts.cairo(
                fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
        const SizedBox(height: 8),
        Row(
          children: _penWidths
              .map((w) => GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _penWidth = w);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.only(right: 10),
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: _penWidth == w
                            ? accentDark.withValues(alpha: 0.15)
                            : isDark
                                ? AppTheme.bgCardLight
                                : Colors.white,
                        border: Border.all(
                            color: _penWidth == w
                                ? accentDark
                                : AppTheme.divider.withValues(alpha: 0.5)),
                      ),
                      child: Center(
                        child: Container(
                          width: w * 3,
                          height: w * 3,
                          decoration:
                              BoxDecoration(shape: BoxShape.circle, color: _penColor),
                        ),
                      ),
                    ),
                  ))
              .toList(),
        ),
        const SizedBox(height: 18),
        _primaryButton(
          label: 'متابعة لوضع التوقيع على المستند',
          icon: Icons.arrow_forward_rounded,
          enabled: _hasSignature,
          onTap: _goToPlaceStep,
          accentDark: accentDark,
        ),
      ]),
    );
  }

  // ── المرحلة 3 ──

  Widget _buildPlaceStep(bool isDark, Color accentDark) {
    return Column(
      key: const ValueKey('step3'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('اسحب التوقيع وحدّد حجمه فوق الصفحة',
                      style: GoogleFonts.cairo(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? AppTheme.textPrimary
                              : const Color(0xFF1A1A2E))),
                  if (_pageCount > 1 && !_applyToAllPages)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                          'سيُحفَظ التوقيع على الصفحة المعروضة حالياً فقط',
                          style: GoogleFonts.cairo(
                              fontSize: 11, color: AppTheme.textMuted)),
                    ),
                ],
              ),
            ),
            if (_pageCount > 1) ...[
              IconButton(
                icon: const Icon(Icons.chevron_right_rounded, size: 22),
                color: accentDark,
                onPressed: _displayedPage < _pageCount
                    ? () => _changeDisplayedPage(_displayedPage + 1)
                    : null,
              ),
              Text('$_displayedPage / $_pageCount',
                  style: GoogleFonts.cairo(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
              IconButton(
                icon: const Icon(Icons.chevron_left_rounded, size: 22),
                color: accentDark,
                onPressed: _displayedPage > 1
                    ? () => _changeDisplayedPage(_displayedPage - 1)
                    : null,
              ),
            ],
          ]),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _buildPageCanvas(isDark, accentDark),
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _applyToAllPages = !_applyToAllPages);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: isDark ? AppTheme.bgCardLight : Colors.white,
                border: Border.all(color: AppTheme.divider.withValues(alpha: 0.5)),
              ),
              child: Row(children: [
                Icon(
                    _applyToAllPages
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    color: accentDark,
                    size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                      'تطبيق نفس الموضع على جميع صفحات المستند ($_pageCount صفحة)',
                      style: GoogleFonts.cairo(
                          fontSize: 12.5,
                          color: isDark
                              ? AppTheme.textPrimary
                              : const Color(0xFF1A1A2E))),
                ),
              ]),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
          child: _primaryButton(
            label: _isProcessing ? 'جارٍ الحفظ...' : 'تأكيد وحفظ الملف الموقَّع',
            icon: Icons.check_circle_rounded,
            enabled: !_isProcessing && _placement != null,
            onTap: _confirmSign,
            accentDark: accentDark,
            isLoading: _isProcessing,
          ),
        ),
      ],
    );
  }

  Widget _buildPageCanvas(bool isDark, Color accentDark) {
    if (_isRenderingPage) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_renderError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(_renderError!,
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(fontSize: 13, color: Colors.red.shade400)),
        ),
      );
    }
    final rendered = _renderedPage;
    final sigBytes = _signatureBytes;
    if (rendered == null || sigBytes == null) {
      return const SizedBox.shrink();
    }

    // نحسب حجم العرض المنطقي للصفحة بحيث تملأ المساحة المتاحة عرضياً مع
    // الحفاظ على نسبة العرض/الارتفاع الحقيقية — هذا الحجم هو بالضبط ما
    // يُمرَّر لـ DraggableSignatureOverlay كـ "نظام الإحداثيات".
    return LayoutBuilder(builder: (context, constraints) {
      final pageAspect = rendered.pageWidthPt / rendered.pageHeightPt;
      double displayWidth = constraints.maxWidth;
      double displayHeight = displayWidth / pageAspect;
      if (displayHeight > constraints.maxHeight) {
        displayHeight = constraints.maxHeight;
        displayWidth = displayHeight * pageAspect;
      }
      final displaySize = Size(displayWidth, displayHeight);

      return Center(
        child: SizedBox(
          width: displaySize.width,
          height: displaySize.height,
          // ⚠️ محدودية معروفة: ClipRRect هنا يقصّ أي عنصر يتجاوز حدود
          // الصفحة، بما في ذلك مقبض التحجيم الدائري الذي يبرز 10px خارج
          // إطار التوقيع نفسه (انظر draggable_signature_overlay.dart).
          // إن سحب المستخدم التوقيع قريباً جداً من حافة الصفحة، قد يصعب
          // الإمساك بالمقبض المرئي جزئياً فقط — لكن إيماءة القرص بإصبعين
          // (onScaleUpdate) تبقى تعمل بلا أي قيد لأنها مرتبطة بكامل صندوق
          // التوقيع لا بالمقبض وحده. القيود في _emitChange (انظر الملف
          // المذكور) تمنع أصلاً سحب التوقيع خارج الصفحة بالكامل، فهذه
          // الحالة الحدّية نادرة عملياً.
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: Container(
                    color: Colors.white,
                    child: Image.memory(rendered.imageBytes, fit: BoxFit.fill),
                  ),
                ),
                if (_placement != null)
                  DraggableSignatureOverlay(
                    pageDisplaySize: displaySize,
                    signatureBytes: sigBytes,
                    signatureAspectRatio: _signatureAspect,
                    initialPlacement: _placement!,
                    accentColor: accentDark,
                    onPlacementChanged: (p) => setState(() => _placement = p),
                  ),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _primaryButton({
    required String label,
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
    required Color accentDark,
    bool isLoading = false,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: enabled ? onTap : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: accentDark,
          disabledBackgroundColor: AppTheme.bgCardLight,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        child: isLoading
            ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
                const SizedBox(width: 12),
                Text(label,
                    style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.w700)),
              ])
            : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Text(label,
                    style: GoogleFonts.cairo(
                        color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
              ]),
      ),
    );
  }
}

class _SigPainter extends CustomPainter {
  final List<_SigPoint> points;
  final Color color;
  final double width;

  const _SigPainter(this.points, this.color, this.width);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (int i = 0; i < points.length - 1; i++) {
      final cur = points[i];
      final nxt = points[i + 1];
      if (cur.point != null && nxt.point != null) {
        canvas.drawLine(cur.point!, nxt.point!, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SigPainter old) =>
      old.points.length != points.length ||
      old.color != color ||
      old.width != width;
}
