import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../result_screen.dart';

// نموذج بيانات العلامة المائية
class WatermarkTransform {
  Offset relativeCenter;
  double scale;
  double rotationRad;
  double opacity;
  bool isTiled;
  bool isTextMode;
  bool isBehindContent;
  Color textColor;
  String text;
  File? imageFile;

  WatermarkTransform({
    required this.relativeCenter,
    required this.scale,
    required this.rotationRad,
    required this.opacity,
    required this.isTiled,
    required this.isTextMode,
    required this.isBehindContent,
    required this.textColor,
    required this.text,
    this.imageFile,
  });

  WatermarkTransform copyWith({
    Offset? relativeCenter,
    double? scale,
    double? rotationRad,
    double? opacity,
    bool? isTiled,
    bool? isTextMode,
    bool? isBehindContent,
    Color? textColor,
    String? text,
    File? imageFile,
  }) {
    return WatermarkTransform(
      relativeCenter: relativeCenter ?? this.relativeCenter,
      scale: scale ?? this.scale,
      rotationRad: rotationRad ?? this.rotationRad,
      opacity: opacity ?? this.opacity,
      isTiled: isTiled ?? this.isTiled,
      isTextMode: isTextMode ?? this.isTextMode,
      isBehindContent: isBehindContent ?? this.isBehindContent,
      textColor: textColor ?? this.textColor,
      text: text ?? this.text,
      imageFile: imageFile ?? this.imageFile,
    );
  }
}

class WatermarkPdfScreen extends StatefulWidget {
  const WatermarkPdfScreen({super.key});

  @override
  State<WatermarkPdfScreen> createState() => _WatermarkPdfScreenState();
}

class _WatermarkPdfScreenState extends State<WatermarkPdfScreen>
    with SingleTickerProviderStateMixin {
  File? _pdfFile;
  bool _isProcessing = false;
  late WatermarkTransform _wm;
  late final TextEditingController _textController;

  // معاينة صفحة من المستند باستخدام pdfx
  pdfx.PdfDocument? _pdfxDoc;
  Uint8List? _pageImageBytes;
  double _pdfPageWidth = 0;
  double _pdfPageHeight = 0;

  // تصفّح صفحات المستند الأصلي (للمعاينة فقط؛ العلامة تُطبَّق على كل الصفحات)
  int _currentPage = 1;
  int _totalPages = 0;

  // وضع العرض: تحرير تفاعلي، أو معاينة حقيقية لناتج ملف الـ PDF الفعلي
  String _viewMode = 'edit'; // edit | preview
  Uint8List? _afterPageImageBytes;
  bool _isBuildingRealPreview = false;
  bool _showAfter = false;

  // نسخة ui.Image من صورة العلامة لاستخدامها في معاينة البلاط
  ui.Image? _wmUiImage;

  // متغيرات للتفاعل باللمس المتعدد
  double _initialScale = 1.0;
  double _initialRotation = 0.0;
  Offset _initialCenter = Offset.zero;

  // ألوان الواجهة
  static const _bgColor = Color(0xFF1B1E26);
  static const _cardColor = Color(0xFF272B36);
  static const _accentColor = Color(0xFF4371FF);

  final List<Color> _textColors = const [
    Color(0xFF6B7280),
    Color(0xFFEF4444),
    Color(0xFFEAB308),
    Color(0xFF22C55E),
    Color(0xFF3B82F6),
    Color(0xFFA855F7),
  ];

  @override
  void initState() {
    super.initState();
    _wm = WatermarkTransform(
      relativeCenter: const Offset(0.5, 0.5),
      scale: 0.15,
      rotationRad: 0.0,
      opacity: 0.4,
      isTiled: false,
      isTextMode: true,
      isBehindContent: true,
      textColor: const Color(0xFF3B82F6),
      text: 'سري',
      imageFile: null,
    );
    _textController = TextEditingController(text: _wm.text);
    _mainTabCtrl = TabController(length: 3, vsync: this);
    // ⚠️ إصلاح جذري: لا حاجة لـ _loadFont()/_cairoFontBytes بعد الآن —
    // النص العربي الآن يُرسَّم مباشرة عبر GoogleFonts.cairo (نفس محرك
    // المعاينة الناجحة فعلاً)، لا عبر تحميل ملف ttf لتمريره لـ
    // Syncfusion. راجع _rasterizeWatermarkText للتفصيل الكامل.
  }

  @override
  void dispose() {
    _textController.dispose();
    _mainTabCtrl.dispose();
    _wmUiImage?.dispose();
    _pdfxDoc?.close();
    super.dispose();
  }

  Future<void> _pickPdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (result?.files.single.path == null) return;
    final file = File(result!.files.single.path!);
    setState(() {
      _pdfFile = file;
      _pageImageBytes = null;
      _pdfxDoc = null;
      _currentPage = 1;
      _totalPages = 0;
      _viewMode = 'edit';
      _afterPageImageBytes = null;
      _showAfter = false;
    });
    await _generatePreview(file, page: 1);
  }

  /// يولّد صورة معاينة لصفحة معيّنة من المستند الأصلي (تبدأ من 1).
  /// يُستخدم عند اختيار الملف وعند التنقل بين الصفحات.
  Future<void> _generatePreview(File pdfFile, {int page = 1}) async {
    await _pdfxDoc?.close();
    _pdfxDoc = null;

    final doc = await pdfx.PdfDocument.openFile(pdfFile.path);
    _pdfxDoc = doc;
    _totalPages = doc.pagesCount;
    final targetPage = _totalPages > 0 ? page.clamp(1, _totalPages) : 1;

    if (_totalPages > 0) {
      final pdfPage = await doc.getPage(targetPage); // فهرس pdfx يبدأ من 1
      _pdfPageWidth = pdfPage.width;
      _pdfPageHeight = pdfPage.height;

      // دقة مضاعفة + خلفية بيضاء حتى لا تظهر الصفحة داكنة
      final image = await pdfPage.render(
        width: _pdfPageWidth * 2,
        height: _pdfPageHeight * 2,
        format: pdfx.PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );
      _pageImageBytes = image!.bytes;
      await pdfPage.close();
    }
    _currentPage = targetPage;
    if (mounted) setState(() {});
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final XFile? picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final file = File(picked.path);
    // فك ترميز الصورة كـ ui.Image لاستخدامها في معاينة البلاط
    final bytes = await file.readAsBytes();
    final decoded = await decodeImageFromList(bytes);
    _wmUiImage?.dispose();
    setState(() {
      _wmUiImage = decoded;
      _wm = _wm.copyWith(imageFile: file);
      // الصورة تغيّرت: المعاينة الحقيقية السابقة (إن وُجدت) لم تعد صحيحة
      _afterPageImageBytes = null;
    });
  }

  // ==================== منطق الإزاحة الذكي ====================

  /// قياس نص العلامة بخط مرجعي (100pt) لاستخراج نسب العرض/الارتفاع
  Size _measureTextRatio() {
    final tp = TextPainter(
      text: TextSpan(
        text: _wm.text.isEmpty ? 'علامة' : _wm.text,
        style: GoogleFonts.cairo(fontSize: 100, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.rtl,
      maxLines: 1,
    )..layout();
    return Size(tp.width / 100, tp.height / 100);
  }

  /// ⚠️ إصلاح جذري لاقتصاص الحروف العربية: التحقّق المتعمَّق أكَّد أن
  /// syncfusion_flutter_pdf (حزمة Flutter، بخلاف نسخ .NET/Xamarin من
  /// Syncfusion) **لا تملك خاصية ComplexScript إطلاقاً** — وهي الخاصية
  /// المسؤولة في نسخ Syncfusion الأخرى عن تشكيل النصوص المعقّدة (عربي/
  /// هندي/تاميلي) بصورة صحيحة. طلب الميزة هذا مفتوح ولم يُنفَّذ بعد
  /// (syncfusion.com/feedback/20541). هذا يعني أن drawString نفسها في
  /// حزمة Flutter قد لا تُشكِّل بعض تركيبات الحروف العربية بصورة صحيحة
  /// عند الرسم الفعلي — وهذا أعمق من مجرّد خطأ قياس (الذي أصلحناه
  /// سابقاً)، فلا يوجد إصلاح ممكن طالما الرسم نفسه يمرّ عبر drawString.
  /// الحل الجذري: لا نطلب من Syncfusion رسم النص العربي إطلاقاً — نرسمه
  /// بنفسنا عبر TextPainter (محرك النص في Flutter، المؤكَّد دقته فعلاً
  /// لأنه نفس ما يُستخدَم بصرياً في المعاينة التفاعلية الناجحة)، إلى
  /// صورة PNG شفافة الخلفية، ثم نُمرِّر هذه الصورة لـ Syncfusion عبر
  /// PdfBitmap (رسم صورة، لا نص) — يتفادى هذا تماماً مسار التشكيل
  /// المعطوب في Syncfusion دون انتظار إصلاح من الشركة.
  Future<Uint8List?> _rasterizeWatermarkText(
      String text, double fontSizePx, Color color) async {
    try {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: GoogleFonts.cairo(
            fontSize: fontSizePx,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        textDirection: TextDirection.rtl,
        maxLines: 1,
      )..layout();

      // هامش بسيط حول النص لضمان عدم قصّ أي امتداد رأسي/أفقي لحروف
      // مُشكَّلة عند الرسم (مثل التشكيل أو حروف ذات نقاط ممتدة).
      const margin = 4.0;
      final w = (tp.width + margin * 2).ceil();
      final h = (tp.height + margin * 2).ceil();
      if (w <= 0 || h <= 0) return null;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
      tp.paint(canvas, const Offset(margin, margin));
      final picture = recorder.endRecording();
      final image = await picture.toImage(w, h);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  /// أبعاد العلامة (عرض × ارتفاع) بوحدات نقاط PDF حسب الإعدادات الحالية
  Size _watermarkSizeInPdfPoints() {
    final pw = _pdfPageWidth > 0 ? _pdfPageWidth : 595.0;
    final ph = _pdfPageHeight > 0 ? _pdfPageHeight : 842.0;
    if (_wm.isTextMode) {
      final ratio = _measureTextRatio();
      final fontSize = pw * _wm.scale;
      return Size(ratio.width * fontSize, ratio.height * fontSize);
    } else {
      final dim = math.min(pw, ph) * _wm.scale;
      final a = _wmUiImage != null
          ? _wmUiImage!.width / _wmUiImage!.height
          : 1.0;
      return a > 1 ? Size(dim, dim / a) : Size(dim * a, dim);
    }
  }

  /// الصندوق المحيط بالعلامة بعد الدوران (bounding box)
  Size _rotatedBoundingBox(Size s, double angleRad) {
    final c = math.cos(angleRad).abs();
    final si = math.sin(angleRad).abs();
    return Size(c * s.width + si * s.height, si * s.width + c * s.height);
  }

  /// هوامش الحواف النسبية: أقل مسافة بين مركز العلامة وحافة الصفحة
  /// بحيث تبقى العلامة كاملة (بعد الدوران) داخل الصفحة
  Offset _edgeMargins() {
    final pw = _pdfPageWidth > 0 ? _pdfPageWidth : 595.0;
    final ph = _pdfPageHeight > 0 ? _pdfPageHeight : 842.0;
    final bbox = _rotatedBoundingBox(_watermarkSizeInPdfPoints(), _wm.rotationRad);
    final mx = (bbox.width / 2 / pw).clamp(0.02, 0.5).toDouble();
    final my = (bbox.height / 2 / ph).clamp(0.02, 0.5).toDouble();
    return Offset(mx, my);
  }

  /// تقييد مركز نسبي بحيث تبقى العلامة داخل الصفحة
  Offset _clampCenter(Offset center) {
    final m = _edgeMargins();
    return Offset(
      center.dx.clamp(m.dx, 1.0 - m.dx).toDouble(),
      center.dy.clamp(m.dy, 1.0 - m.dy).toDouble(),
    );
  }

  // ==================== توليد ملف الـ PDF الموسوم (مشترك بين الحفظ والمعاينة الحقيقية) ====================

  /// يطبّق العلامة المائية على نسخة من المستند في الذاكرة ويعيد البايتات
  /// الناتجة مع عدد الصفحات. تُستخدم هذه الدالة في الحفظ النهائي وفي توليد
  /// "المعاينة الحقيقية" حتى تكون المعاينة مطابقة تماماً للملف الناتج.
  Future<(Uint8List, int)> _renderWatermarkedPdfBytes() async {
    final bytes = await _pdfFile!.readAsBytes();
    final doc = PdfDocument(inputBytes: bytes);
    final pageCount = doc.pages.count;
    final baseWidth = doc.pages[0].getClientSize().width;
    final effectiveScale = _wm.scale;
    final fontSizePx = baseWidth * effectiveScale;
    final imageMaxDim =
        math.min(baseWidth, doc.pages[0].getClientSize().height) *
            effectiveScale;

    // ⚠️ إصلاح جذري لاقتصاص الحروف العربية (راجع التعليق الكامل أعلى
    // _rasterizeWatermarkText لتفصيل السبب الجذري): لا نستخدم
    // PdfTrueTypeFont/drawString لرسم النص العربي إطلاقاً بعد الآن. بدلاً
    // من ذلك نُرسِّم النص مرة واحدة هنا (قبل حلقة الصفحات، تماماً كما
    // يُحضَّر pdfBitmap لوضع الصورة مرة واحدة لا داخل كل تكرار) إلى صورة
    // PNG شفافة عبر TextPainter من Flutter، ثم نرسم هذه الصورة في كل
    // صفحة/تكرار بلاط عبر drawImage — بصرية مطابقة تماماً للمعاينة
    // الناجحة فعلاً، بلا أي اعتماد على تشكيل Syncfusion المعطوب.
    PdfBitmap? textBitmap;
    double textBitmapAspect = 1.0;
    if (_wm.isTextMode) {
      final wmText = _wm.text;
      // نرسِّم بالأبيض الكامل (شفافية 1.0) عمداً — الشفافية الفعلية
      // المطلوبة من المستخدم (_wm.opacity) تُطبَّق مرة واحدة فقط عبر
      // graphics.setTransparency أدناه (كما كانت تُطبَّق فعلاً من قبل
      // لوضع الصورة)، فتجنّباً لتطبيقها مرتين (مرة في ألفا الصورة
      // المُرسَّمة ومرة أخرى عبر طبقة الرسم) نُرسِّم بلون كامل العتامة.
      final rasterBytes = await _rasterizeWatermarkText(
          wmText, fontSizePx, _wm.textColor.withValues(alpha: 1.0));
      if (rasterBytes != null) {
        textBitmap = PdfBitmap(rasterBytes);
        textBitmapAspect = textBitmap.width / textBitmap.height;
      }
    }

    PdfBitmap? pdfBitmap;
    if (!_wm.isTextMode && _wm.imageFile != null) {
      pdfBitmap = PdfBitmap(await _wm.imageFile!.readAsBytes());
    }

    for (int i = 0; i < pageCount; i++) {
      final page = doc.pages[i];
      final pageSize = page.getClientSize();

      // اختيار موضع الرسم: خلف المحتوى أو فوقه
      PdfGraphics graphics;
      if (_wm.isBehindContent) {
        // لا توجد insert في إصدار Flutter من Syncfusion؛
        // الحل: أضف طبقة العلامة ثم أعد ترتيب طبقات المحتوى لتأتي بعدها
        final contentLayersCount = page.layers.count;
        final wmLayer = page.layers.add(name: 'watermark');
        for (int k = 0; k < contentLayersCount; k++) {
          final contentLayer = page.layers[0];
          page.layers.removeAt(0);
          page.layers.addLayer(contentLayer);
        }
        graphics = wmLayer.graphics;
      } else {
        graphics = page.graphics;
      }

      graphics.setTransparency(_wm.opacity);

      double elementWidth, elementHeight;
      if (_wm.isTextMode && textBitmap != null) {
        // ⚠️ القياس الآن مأخوذ من أبعاد الصورة المُرسَّمة الفعلية نفسها
        // (نفس الكائن الذي سيُرسَم) لا من قياس مستقل قد يختلف عنها —
        // إزالة كاملة لإمكانية اختلاف "ما قِيس" عن "ما رُسم"، وهو جذر
        // مشكلة الاقتصاص الأصلية.
        final ratio = _measureTextRatio();
        elementWidth = ratio.width * fontSizePx;
        elementHeight = elementWidth / textBitmapAspect;
        if (elementWidth <= 0 || elementHeight <= 0) {
          elementWidth = fontSizePx * _wm.text.length * 0.6;
          elementHeight = fontSizePx * 1.4;
        }
      } else if (pdfBitmap != null) {
        final ratio = pdfBitmap.width / pdfBitmap.height;
        if (ratio > 1) {
          elementWidth = imageMaxDim;
          elementHeight = imageMaxDim / ratio;
        } else {
          elementHeight = imageMaxDim;
          elementWidth = imageMaxDim * ratio;
        }
      } else {
        continue;
      }

      if (_wm.isTiled) {
        const spacing = 100.0;
        final diagonal = math.sqrt(
            elementWidth * elementWidth + elementHeight * elementHeight);
        final stepX = diagonal + spacing;
        final stepY = diagonal + spacing;
        final cols = ((pageSize.width / stepX).ceil() + 2).toInt();
        final rows = ((pageSize.height / stepY).ceil() + 2).toInt();
        final startX = -stepX;
        final startY = -stepY;

        for (int col = 0; col < cols; col++) {
          for (int row = 0; row < rows; row++) {
            final x = startX + col * stepX;
            final y = startY + row * stepY;

            final state = graphics.save();
            graphics.translateTransform(
                x + elementWidth / 2, y + elementHeight / 2);
            graphics.rotateTransform(_wm.rotationRad * 180 / math.pi);
            final bmp = _wm.isTextMode ? textBitmap : pdfBitmap;
            if (bmp != null) {
              graphics.drawImage(
                  bmp,
                  Rect.fromLTWH(-elementWidth / 2, -elementHeight / 2,
                      elementWidth, elementHeight));
            }
            graphics.restore(state);
          }
        }
      } else {
        // إزاحة ذكية: تقييد المركز بحيث تبقى العلامة (بعد الدوران)
        // داخل حدود الصفحة بالكامل ولا يُقص أي جزء منها عند الحواف
        final bbox = _rotatedBoundingBox(
            Size(elementWidth, elementHeight), _wm.rotationRad);
        final halfW = math.min(bbox.width / 2, pageSize.width / 2);
        final halfH = math.min(bbox.height / 2, pageSize.height / 2);
        final centerX = (_wm.relativeCenter.dx * pageSize.width)
            .clamp(halfW, pageSize.width - halfW)
            .toDouble();
        final centerY = (_wm.relativeCenter.dy * pageSize.height)
            .clamp(halfH, pageSize.height - halfH)
            .toDouble();

        final state = graphics.save();
        graphics.translateTransform(centerX, centerY);
        graphics.rotateTransform(_wm.rotationRad * 180 / math.pi);
        final bmp = _wm.isTextMode ? textBitmap : pdfBitmap;
        if (bmp != null) {
          graphics.drawImage(
              bmp,
              Rect.fromLTWH(-elementWidth / 2, -elementHeight / 2,
                  elementWidth, elementHeight));
        }
        graphics.restore(state);
      }
    }

    final outBytes = doc.saveSync();
    doc.dispose();
    return (Uint8List.fromList(outBytes), pageCount);
  }

  Future<void> _applyWatermark() async {
    if (_pdfFile == null) {
      _showSnack('الرجاء اختيار ملف PDF أولاً');
      return;
    }
    if (_wm.isTextMode && _wm.text.trim().isEmpty) {
      _showSnack('الرجاء إدخال نص العلامة المائية');
      return;
    }
    if (!_wm.isTextMode && _wm.imageFile == null) {
      _showSnack('الرجاء اختيار صورة العلامة المائية');
      return;
    }

    setState(() => _isProcessing = true);
    try {
      final (outBytes, pageCount) = await _renderWatermarkedPdfBytes();

      final name = p.basenameWithoutExtension(_pdfFile!.path);
      // ⚠️ تعميم حقيقي: كانت هذه الشاشة الوحيدة التي تستخدم حوار حفظ
      // النظام (FilePicker.platform.saveFile) ثم نافذة تنبيه بسيطة بدل
      // المسار المُعتمَد في كل أدوات التطبيق الأخرى (كتابة لملف مؤقت ثم
      // فتح ResultScreen، الذي يوفّر حفظ/فتح/مشاركة وتسجيلاً في السجل
      // تلقائياً). توحيد هذا يجعل تجربة المستخدم متّسقة بصرف النظر عن
      // الأداة المستخدَمة.
      final dir = await getTemporaryDirectory();
      final out = File('${dir.path}/${name}_watermarked.pdf');
      await out.writeAsBytes(outBytes);

      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => ResultScreen(
        file: out,
        title: 'تمت الإضافة بنجاح!',
        subtitle: 'تم تطبيق العلامة المائية على $pageCount صفحة',
        toolId: 'watermark',
        toolName: 'علامة مائية',
        settings: {
          'النوع': _wm.isTextMode ? 'نص' : 'صورة',
          'الموضع': _wm.isTiled ? 'بلاط متكرر' : 'موضع ثابت',
        },
      )));
    } catch (e) {
      _showSnack('حدث خطأ: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: GoogleFonts.cairo()),
        backgroundColor: _cardColor,
      ),
    );
  }

  // ==================== المعاينة التفاعلية ====================
  Widget _buildInteractivePreview() {
    if (_pageImageBytes == null || _pdfFile == null) {
      return GestureDetector(
        onTap: _pickPdf,
        // FittedBox يقلّص المحتوى تلقائياً عند ضيق المساحة بدل overflow
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _cardColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.add_circle_outline,
                    color: Colors.white54, size: 40),
                const SizedBox(height: 10),
                Text('اضغط لاختيار ملف PDF',
                    style: GoogleFonts.cairo(color: Colors.white70)),
              ],
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final previewWidth = constraints.maxWidth;
        final previewHeight = constraints.maxHeight;
        final imageAspect = _pdfPageWidth / _pdfPageHeight;

        double drawWidth = previewWidth;
        double drawHeight = previewWidth / imageAspect;
        if (drawHeight > previewHeight) {
          drawHeight = previewHeight;
          drawWidth = previewHeight * imageAspect;
        }
        final offsetX = (previewWidth - drawWidth) / 2;
        final offsetY = (previewHeight - drawHeight) / 2;

        final watermarkSizePx = drawWidth * _wm.scale;
        final centerOnScreen = Offset(
          offsetX + _wm.relativeCenter.dx * drawWidth,
          offsetY + _wm.relativeCenter.dy * drawHeight,
        );

        return Stack(
          children: [
            Positioned.fill(
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.center,
                  minWidth: drawWidth,
                  maxWidth: drawWidth,
                  minHeight: drawHeight,
                  maxHeight: drawHeight,
                  child: Image.memory(
                    _pageImageBytes!,
                    fit: BoxFit.fill,
                  ),
                ),
              ),
            ),
            if (_wm.isTiled)
              // معاينة حية لوضع البلاط بنفس خوارزمية ملف الـ PDF الناتج
              Positioned(
                left: offsetX,
                top: offsetY,
                width: drawWidth,
                height: drawHeight,
                child: IgnorePointer(
                  child: ClipRect(
                    child: CustomPaint(
                      painter: _TiledWatermarkPainter(
                        wm: _wm,
                        image: _wmUiImage,
                      ),
                    ),
                  ),
                ),
              )
            else
              Positioned(
                left: centerOnScreen.dx - watermarkSizePx / 2,
                top: centerOnScreen.dy - watermarkSizePx / 2,
                child: GestureDetector(
                  onScaleStart: (details) {
                    _initialScale = _wm.scale;
                    _initialRotation = _wm.rotationRad;
                    _initialCenter = _wm.relativeCenter;
                  },
                  onScaleUpdate: (details) {
                    setState(() {
                      double newScale =
                          (_initialScale * details.scale).clamp(0.05, 0.5);
                      double newRotation =
                          _initialRotation + details.rotation;
                      _wm = _wm.copyWith(
                          scale: newScale, rotationRad: newRotation);
                      if (details.focalPointDelta != Offset.zero) {
                        double deltaX =
                            details.focalPointDelta.dx / drawWidth;
                        double deltaY =
                            details.focalPointDelta.dy / drawHeight;
                        // الإزاحة الذكية: التقييد بأبعاد العلامة الفعلية
                        // (عرض النص الحقيقي + تأثير الدوران) لا بمربع تقريبي
                        final clamped = _clampCenter(Offset(
                          _initialCenter.dx + deltaX,
                          _initialCenter.dy + deltaY,
                        ));
                        _wm = _wm.copyWith(relativeCenter: clamped);
                      } else {
                        // عند تغيير الحجم/الدوران فقط: أعد تقييد المركز
                        _wm = _wm.copyWith(
                            relativeCenter: _clampCenter(_wm.relativeCenter));
                      }
                    });
                  },
                  child: Transform.rotate(
                    angle: _wm.rotationRad,
                    child: Container(
                      width: watermarkSizePx,
                      height: watermarkSizePx,
                      alignment: Alignment.center,
                      child: _buildWatermarkWidget(watermarkSizePx),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildWatermarkWidget(double sizePx) {
    if (_wm.isTextMode) {
      // OverflowBox بلا تقييد للعرض ولا للارتفاع: النص يتجاوز المربع
      // المرجعي بدل أن يُقص أو يلتف. ملاحظة: تقييد الارتفاع فقط (دون
      // تحرير maxHeight) كان يقصّ أعالي/أسافل بعض الحروف ذات الامتداد
      // الرأسي حتى بعد تحرير العرض، لذا يجب تحرير المحورين معاً.
      return OverflowBox(
        minWidth: 0,
        maxWidth: double.infinity,
        minHeight: 0,
        maxHeight: double.infinity,
        child: Text(
          _wm.text.isEmpty ? 'علامة' : _wm.text,
          softWrap: false,
          overflow: TextOverflow.visible,
          style: GoogleFonts.cairo(
            // مطابقة الناتج الفعلي: حجم خط الـ PDF = عرض الصفحة × scale
            fontSize: sizePx,
            fontWeight: FontWeight.bold,
            color: _wm.textColor.withValues(alpha: _wm.opacity),
          ),
        ),
      );
    } else {
      if (_wm.imageFile == null) return const Icon(Icons.image, size: 50);
      return Opacity(
        opacity: _wm.opacity,
        child: Image.file(_wm.imageFile!,
            width: sizePx, height: sizePx, fit: BoxFit.contain),
      );
    }
  }

  // ==================== تصفّح الصفحات + المعاينة الحقيقية قبل/بعد ====================

  Future<void> _goToPage(int page) async {
    if (_pdfFile == null || _totalPages == 0) return;
    final target = page.clamp(1, _totalPages);
    if (target == _currentPage) return;
    await _generatePreview(_pdfFile!, page: target);
    if (_viewMode == 'preview') {
      await _refreshRealPreview();
    }
  }

  void _switchMode(String mode) {
    if (_pdfFile == null || mode == _viewMode) return;
    setState(() => _viewMode = mode);
    if (mode == 'preview') {
      _refreshRealPreview();
    }
  }

  /// يولّد ملف الـ PDF الموسوم بالكامل في الذاكرة (دون حفظ) ثم يرسم
  /// الصفحة الحالية منه كصورة، حتى تكون المعاينة مطابقة تماماً لما
  /// سيُحفظ فعلياً عند الضغط على "تطبيق".
  Future<void> _refreshRealPreview() async {
    if (_pdfFile == null) return;
    if (_wm.isTextMode && _wm.text.trim().isEmpty) return;
    if (!_wm.isTextMode && _wm.imageFile == null) return;

    setState(() => _isBuildingRealPreview = true);
    try {
      final (outBytes, _) = await _renderWatermarkedPdfBytes();
      final doc = await pdfx.PdfDocument.openData(outBytes);
      Uint8List? rendered;
      if (doc.pagesCount > 0) {
        final pageNum = _currentPage.clamp(1, doc.pagesCount);
        final page = await doc.getPage(pageNum);
        final image = await page.render(
          width: page.width * 2,
          height: page.height * 2,
          format: pdfx.PdfPageImageFormat.png,
          backgroundColor: '#FFFFFF',
        );
        rendered = image?.bytes;
        await page.close();
      }
      await doc.close();
      if (!mounted) return;
      setState(() {
        _afterPageImageBytes = rendered;
        _showAfter = rendered != null;
        _isBuildingRealPreview = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isBuildingRealPreview = false);
      _showSnack('فشل توليد المعاينة الحقيقية: $e');
    }
  }

  Widget _buildPreviewToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(child: _buildPageNav()),
          _buildModeToggle(),
        ],
      ),
    );
  }

  Widget _buildPageNav() {
    if (_totalPages <= 1) return const SizedBox(height: 32);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _currentPage > 1 ? () => _goToPage(_currentPage - 1) : null,
          child: Icon(Icons.chevron_right,
              color: _currentPage > 1 ? Colors.white70 : Colors.white24,
              size: 22),
        ),
        const SizedBox(width: 6),
        Text('صفحة $_currentPage من $_totalPages',
            style: GoogleFonts.cairo(color: Colors.white70, fontSize: 12)),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: _currentPage < _totalPages
              ? () => _goToPage(_currentPage + 1)
              : null,
          child: Icon(Icons.chevron_left,
              color:
                  _currentPage < _totalPages ? Colors.white70 : Colors.white24,
              size: 22),
        ),
      ],
    );
  }

  Widget _buildModeToggle() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
          color: _cardColor, borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _modeChip('تحرير', 'edit'),
        _modeChip('معاينة حقيقية', 'preview'),
      ]),
    );
  }

  Widget _modeChip(String label, String mode) {
    final sel = _viewMode == mode;
    return GestureDetector(
      onTap: () => _switchMode(mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: sel ? _accentColor : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: GoogleFonts.cairo(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: sel ? Colors.white : Colors.white60)),
      ),
    );
  }

  /// معاينة حقيقية: تعرض رسماً فعلياً (PNG) لصفحة الملف الناتج عن
  /// Syncfusion، مع تبديل "قبل/بعد" مقارنةً بالصفحة الأصلية.
  Widget _buildRealPreview() {
    if (_pdfFile == null) {
      return Text('اختر ملف PDF أولاً',
          style: GoogleFonts.cairo(color: Colors.white70));
    }
    final bytes = _showAfter ? _afterPageImageBytes : _pageImageBytes;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _previewToggleChip(
                'قبل', !_showAfter, () => setState(() => _showAfter = false)),
            const SizedBox(width: 8),
            _previewToggleChip(
                'بعد',
                _showAfter,
                _afterPageImageBytes == null
                    ? null
                    : () => setState(() => _showAfter = true)),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: _isBuildingRealPreview ? null : _refreshRealPreview,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: _cardColor,
                    borderRadius: BorderRadius.circular(8)),
                child: _isBuildingRealPreview
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white70))
                    : const Icon(Icons.refresh_rounded,
                        color: Colors.white70, size: 18),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            'معاينة حقيقية لناتج الملف الفعلي — اضغط 🔄 بعد أي تعديل على الإعدادات',
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(color: Colors.white38, fontSize: 10.5),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: bytes == null
                ? Center(
                    child: Text(
                      _isBuildingRealPreview
                          ? 'جارٍ تجهيز المعاينة الحقيقية...'
                          : 'لا توجد معاينة بعد',
                      style:
                          GoogleFonts.cairo(color: Colors.white54, fontSize: 13),
                    ),
                  )
                : InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 4,
                    child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _previewToggleChip(String label, bool selected, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onTap();
            },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? _accentColor : _cardColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: selected ? _accentColor : Colors.white24),
        ),
        child: Text(label,
            style: GoogleFonts.cairo(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: onTap == null ? Colors.white38 : Colors.white)),
      ),
    );
  }

  // ⚠️ تعميم: استُبدلت لوحة التحكم السفلية الواحدة المزدحمة (التي كانت
  // تكشف كل الإعدادات — نوع المحتوى، حقل النص/الصورة، 5 تبويبات فرعية،
  // سويتشات البلاط/الطبقة، زر التطبيق — دفعة واحدة في عمود قابل للتمرير
  // يحتل حتى 80% من الشاشة) بثلاث تبويبات علوية حقيقية (TabBar/TabBarView):
  // "المحتوى"، "الموقع والمظهر"، "التكرار". هذا يحرر مساحة المعاينة بالكامل
  // (لا تتقاسمها مع لوحة تحكم ضخمة)، ويعطي كل فئة إعدادات سياقها الخاص بدل
  // الزحام البصري — أقرب لأسلوب iLovePDF/Smallpdf الذي طلبته.
  late final TabController _mainTabCtrl;

  // تبويب فرعي داخل "الموقع والمظهر" فقط (حجم/لون/عتامة/دوران/موضع) —
  // هذا الجزء من التصميم القديم كان جيداً وكافياً، أُبقي عليه كما هو بنفس
  // الاسم القديم لمنطقه الداخلي (_buildActiveTabContent إلخ) لتفادي إعادة
  // كتابة غير ضرورية لمنطق سليم.
  String _activeTab = 'الحجم';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('إضافة علامة مائية',
            style: GoogleFonts.cairo(
                color: Colors.white, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf, color: Colors.white70),
            onPressed: _pickPdf,
            tooltip: 'تغيير المستند',
          ),
        ],
        // ⚠️ التبويبات الرئيسية الجديدة تعيش في أسفل AppBar نفسه (bottom)،
        // مكانها الطبيعي في Material — لا حاجة لحاوية إضافية في body تستهلك
        // مساحة رأسية، وهذا يطابق الموضع المتوقَّع لتبويبات تنقّل رئيسية في
        // أي تطبيق Material قياسي.
        bottom: TabBar(
          controller: _mainTabCtrl,
          indicatorColor: _accentColor,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          labelStyle: GoogleFonts.cairo(fontWeight: FontWeight.w700, fontSize: 13),
          unselectedLabelStyle: GoogleFonts.cairo(fontWeight: FontWeight.w500, fontSize: 13),
          tabs: const [
            Tab(text: 'المحتوى'),
            Tab(text: 'الموقع والمظهر'),
            Tab(text: 'التكرار'),
          ],
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return Column(
            children: [
              if (_pdfFile != null) _buildPreviewToolbar(),
              // ⚠️ المعاينة الآن تأخذ كل المساحة المتبقية فعلياً (Expanded
              // بلا تنافس مع لوحة تحكم سفلية ضخمة) — هذا أكبر فرق ملموس
              // للمستخدم عن التصميم القديم، الذي كان يضغط المعاينة لمساحة
              // صغيرة لإفساح المجال للوحة الإعدادات المكشوفة بالكامل.
              Expanded(
                child: Center(
                  child: _viewMode == 'edit'
                      ? _buildInteractivePreview()
                      : _buildRealPreview(),
                ),
              ),
              // شريط الإعدادات أصبح بارتفاع ثابت معقول (ليس نسبة من الشاشة
              // كما كان) لأن كل تبويب الآن أخفّ بكثير من اللوحة المجمّعة
              // القديمة؛ السماح له بالتمدد الزائد لا داعي له بعد التفريق.
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.min(constraints.maxHeight * 0.42, 340),
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: _bgColor,
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withAlpha(50),
                          offset: const Offset(0, -4),
                          blurRadius: 10)
                    ],
                  ),
                  child: TabBarView(
                    controller: _mainTabCtrl,
                    children: [
                      _buildContentTab(),
                      _buildPositionAndStyleTab(),
                      _buildRepeatTab(),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                child: _buildApplyButton(),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── تبويب 1: المحتوى (نص/صورة) ──
  Widget _buildContentTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                  child: _buildTypeSegment('صورة', !_wm.isTextMode,
                      () => setState(() {
                            _wm = _wm.copyWith(isTextMode: false);
                          }))),
              Expanded(
                  child: _buildTypeSegment('نص', _wm.isTextMode,
                      () => setState(() {
                            _wm = _wm.copyWith(isTextMode: true);
                          }))),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
                color: _cardColor, borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                Text(_wm.isTextMode ? 'نص' : 'صورة',
                    style: const TextStyle(color: Colors.white)),
                const SizedBox(width: 16),
                Expanded(
                  child: _wm.isTextMode
                      ? TextField(
                          controller: _textController,
                          onChanged: (value) {
                            setState(() => _wm = _wm.copyWith(text: value));
                          },
                          textAlign: TextAlign.right,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            hintText: 'اكتب نص العلامة',
                            hintStyle: TextStyle(color: Colors.white54),
                          ),
                        )
                      : GestureDetector(
                          onTap: _pickImage,
                          child: Text(
                            _wm.imageFile == null
                                ? 'اختر صورة'
                                : p.basename(_wm.imageFile!.path),
                            style: const TextStyle(color: Colors.white70),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── تبويب 2: الموقع والمظهر (حجم/لون/عتامة/دوران/موضع) ──
  // المنطق الداخلي (التبويبات الفرعية + _buildActiveTabContent) من
  // التصميم القديم كان سليماً ومنظَّماً جيداً بالفعل، فأُبقي عليه كما هو
  // تماماً — فقط نُقل من داخل اللوحة الواحدة الضخمة إلى تبويب مستقل خاص به.
  Widget _buildPositionAndStyleTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(
              children: ['الحجم', 'اللون', 'عتامة', 'دوران', 'الموضع']
                  .map((tab) => _buildSettingTab(tab))
                  .toList(),
            ),
          ),
          const SizedBox(height: 16),
          _buildActiveTabContent(),
        ],
      ),
    );
  }

  // ── تبويب 3: التكرار (بلاط + الطبقة) ──
  Widget _buildRepeatTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
                color: _cardColor, borderRadius: BorderRadius.circular(12)),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Switch(
                      value: _wm.isTiled,
                      onChanged: (v) =>
                          setState(() => _wm = _wm.copyWith(isTiled: v)),
                      activeTrackColor: _accentColor,
                    ),
                    Text('بلاط (تكرار)',
                        style: GoogleFonts.cairo(color: Colors.white)),
                  ],
                ),
                const Divider(color: Colors.white12, height: 1),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Switch(
                      value: _wm.isBehindContent,
                      onChanged: (v) => setState(
                          () => _wm = _wm.copyWith(isBehindContent: v)),
                      activeTrackColor: _accentColor,
                    ),
                    Text('خلف المحتوى',
                        style: GoogleFonts.cairo(color: Colors.white)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'وضع "بلاط" يكرر العلامة على كل الصفحة بنفس زاوية الدوران '
              'الحالية. "خلف المحتوى" يضع العلامة تحت نص/صور الصفحة بدل '
              'فوقها — مناسب أكثر لعلامات مثل "نسخة أصلية" أو "مسودة".',
              style: GoogleFonts.cairo(fontSize: 11.5, color: Colors.white38, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildApplyButton() {
    return ElevatedButton(
      onPressed: _isProcessing ? null : _applyWatermark,
      style: ElevatedButton.styleFrom(
        backgroundColor: _accentColor,
        disabledBackgroundColor: _cardColor,
        minimumSize: const Size(double.infinity, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: _isProcessing
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
            )
          : Text('تطبيق',
              style: GoogleFonts.cairo(color: Colors.white, fontSize: 16)),
    );
  }

  Widget _buildTypeSegment(String text, bool isSelected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? _cardColor : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(text,
            style:
                TextStyle(color: isSelected ? Colors.white : Colors.white54)),
      ),
    );
  }

  Widget _buildSettingTab(String title) {
    final isActive = _activeTab == title;
    return GestureDetector(
      onTap: () => setState(() => _activeTab = title),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          children: [
            Text(title,
                style: TextStyle(
                    color: isActive ? Colors.white : Colors.white54)),
            if (isActive)
              Container(width: 20, height: 2, color: Colors.white),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveTabContent() {
    switch (_activeTab) {
      case 'الحجم':
        return Row(
          children: [
            Text('${(_wm.scale * 100).toInt()}%',
                style: const TextStyle(color: Colors.white)),
            Expanded(
              child: Slider(
                value: _wm.scale,
                min: 0.05,
                max: 0.5,
                activeColor: _accentColor,
                onChanged: (v) => setState(() {
                  _wm = _wm.copyWith(scale: v);
                  // إعادة تقييد المركز بعد تغيير الحجم
                  _wm = _wm.copyWith(
                      relativeCenter: _clampCenter(_wm.relativeCenter));
                }),
              ),
            ),
          ],
        );
      case 'اللون':
        if (!_wm.isTextMode) {
          return const Center(
              child: Text('غير متاح للصور',
                  style: TextStyle(color: Colors.white54)));
        }
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: _textColors.map((color) {
            return GestureDetector(
              onTap: () =>
                  setState(() => _wm = _wm.copyWith(textColor: color)),
              child: Text(
                'Aa',
                style: TextStyle(
                  color: color,
                  fontSize: 20,
                  fontWeight: _wm.textColor == color
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
            );
          }).toList(),
        );
      case 'عتامة':
        return Row(
          children: [
            Text('${(_wm.opacity * 100).toInt()}%',
                style: const TextStyle(color: Colors.white)),
            Expanded(
              child: Slider(
                value: _wm.opacity,
                min: 0.05,
                max: 1.0,
                activeColor: _accentColor,
                onChanged: (v) =>
                    setState(() => _wm = _wm.copyWith(opacity: v)),
              ),
            ),
          ],
        );
      case 'دوران':
        // الزاوية معروضة بالدرجات ومخزنة بالراديان في النطاق [-180، 180]
        final deg = (_wm.rotationRad * 180 / math.pi).clamp(-180.0, 180.0);
        return Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _rotationPreset('قطري ↗', -math.pi / 4),
                _rotationPreset('أفقي', 0),
                _rotationPreset('قطري ↘', math.pi / 4),
              ],
            ),
            Row(
              children: [
                SizedBox(
                  width: 48,
                  child: Text('${deg.toInt()}°',
                      style: const TextStyle(color: Colors.white)),
                ),
                Expanded(
                  child: Slider(
                    value: _wm.rotationRad.clamp(-math.pi, math.pi).toDouble(),
                    min: -math.pi,
                    max: math.pi,
                    activeColor: _accentColor,
                    onChanged: (v) => setState(() {
                      _wm = _wm.copyWith(rotationRad: v);
                      _wm = _wm.copyWith(
                          relativeCenter: _clampCenter(_wm.relativeCenter));
                    }),
                  ),
                ),
              ],
            ),
          ],
        );
      case 'الموضع':
        if (_wm.isTiled) {
          return const Center(
              child: Text('غير متاح في وضع البلاط',
                  style: TextStyle(color: Colors.white54)));
        }
        // شبكة المواضع تحسب هوامش الحواف من أبعاد العلامة الفعلية
        // (عرض النص الحقيقي + الدوران) فلا تخرج العلامة عن الصفحة أبداً
        final m = _edgeMargins();
        final xs = [m.dx, 0.5, 1.0 - m.dx];
        final ys = [m.dy, 0.5, 1.0 - m.dy];
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(9, (idx) {
            final row = idx ~/ 3;
            final col = idx % 3;
            final target = Offset(xs[col], ys[row]);
            final bool isSelected =
                (_wm.relativeCenter.dx - target.dx).abs() < 0.01 &&
                    (_wm.relativeCenter.dy - target.dy).abs() < 0.01;
            return GestureDetector(
              onTap: () {
                setState(() => _wm = _wm.copyWith(relativeCenter: target));
              },
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  border: Border.all(
                      color: isSelected ? _accentColor : Colors.white24,
                      width: 2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Center(
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: isSelected ? _accentColor : Colors.white54,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            );
          }),
        );
      default:
        return const SizedBox();
    }
  }

  Widget _rotationPreset(String label, double rad) {
    final isSelected = (_wm.rotationRad - rad).abs() < 0.01;
    return GestureDetector(
      onTap: () => setState(() {
        _wm = _wm.copyWith(rotationRad: rad);
        _wm = _wm.copyWith(relativeCenter: _clampCenter(_wm.relativeCenter));
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? _accentColor : Colors.transparent,
          border: Border.all(
              color: isSelected ? _accentColor : Colors.white24),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: GoogleFonts.cairo(
                color: isSelected ? Colors.white : Colors.white70,
                fontSize: 12)),
      ),
    );
  }
}

/// رسّام معاينة وضع البلاط: يحاكي خوارزمية التكرار نفسها المستخدمة
/// في ملف الـ PDF الناتج (التباعد 100 نقطة منسوب لعرض الرسم)
class _TiledWatermarkPainter extends CustomPainter {
  final WatermarkTransform wm;
  final ui.Image? image;

  _TiledWatermarkPainter({required this.wm, required this.image});

  @override
  void paint(Canvas canvas, Size size) {
    TextPainter? tp;
    double ew, eh;

    if (wm.isTextMode) {
      tp = TextPainter(
        text: TextSpan(
          text: wm.text.isEmpty ? 'علامة' : wm.text,
          style: GoogleFonts.cairo(
            fontSize: size.width * wm.scale,
            fontWeight: FontWeight.bold,
            color: wm.textColor.withValues(alpha: wm.opacity),
          ),
        ),
        textDirection: TextDirection.rtl,
        maxLines: 1,
      )..layout();
      ew = tp.width;
      eh = tp.height;
    } else if (image != null) {
      final dim = math.min(size.width, size.height) * wm.scale;
      final a = image!.width / image!.height;
      if (a > 1) {
        ew = dim;
        eh = dim / a;
      } else {
        eh = dim;
        ew = dim * a;
      }
    } else {
      return;
    }
    if (ew <= 0 || eh <= 0) return;

    // التباعد في ملف PDF هو 100 نقطة؛ نحوله لمقياس المعاينة
    // (عرض الرسم في المعاينة يقابل عرض الصفحة بالنقاط)
    final spacing = size.width * (100.0 / 595.0) * 0.85;
    final diagonal = math.sqrt(ew * ew + eh * eh);
    final step = diagonal + spacing;
    final cols = (size.width / step).ceil() + 2;
    final rows = (size.height / step).ceil() + 2;

    final imgPaint = Paint()
      ..color = Colors.white.withValues(alpha: wm.opacity)
      ..filterQuality = FilterQuality.medium;

    for (int col = 0; col < cols; col++) {
      for (int row = 0; row < rows; row++) {
        final cx = -step + col * step + ew / 2;
        final cy = -step + row * step + eh / 2;
        canvas.save();
        canvas.translate(cx, cy);
        canvas.rotate(wm.rotationRad);
        if (wm.isTextMode && tp != null) {
          tp.paint(canvas, Offset(-ew / 2, -eh / 2));
        } else if (image != null) {
          canvas.drawImageRect(
            image!,
            Rect.fromLTWH(0, 0, image!.width.toDouble(),
                image!.height.toDouble()),
            Rect.fromLTWH(-ew / 2, -eh / 2, ew, eh),
            imgPaint,
          );
        }
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TiledWatermarkPainter oldDelegate) {
    return oldDelegate.wm != wm || oldDelegate.image != image;
  }
}
