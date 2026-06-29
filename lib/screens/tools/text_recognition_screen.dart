// ═══════════════════════════════════════════════════════════════════════════
//  استخراج النص (OCR) — شاشة بتصميم خاص يطابق نمط أدوات التحويل الأخرى
// ═══════════════════════════════════════════════════════════════════════════
//
//  مصدر الإدخال: كاميرا مباشرة، صورة من المعرض، أو ملف PDF ممسوح.
//
//  ⚠️ تبسيط مُتعمَّد: لا حوار لاختيار لغة النص — يُشغَّل دمج العربية+
//  الإنجليزية معاً (ara+eng) مباشرة دوماً بلا سؤال المستخدم، تماماً
//  كسلوك الإصدار الأول من هذه الأداة (تجربة Text Fairy التي تسأل عن
//  اللغة أولاً كانت تجربة مُختبَرة في إصدار سابق ثم أُزيلت بطلب صريح).
//
//  خطوة اقتصاص/تحديد منطقة النص تفاعلياً (عبر image_cropper، المُستخدمة
//  فعلياً في أداة "استيراد الصور" بنفس المشروع — نفس النمط البصري) تبقى
//  مفعَّلة بعد اختيار الصورة وقبل تمريرها لمحرك OCR.
//
//  الناتج النهائي: PDF قابل للبحث (يحافظ على صورة المستند الأصلية كاملة
//  مع طبقة نص شفافة قابلة للبحث/النسخ فوقها) أو ملف Word قابل للتعديل
//  الكامل — يختار المستخدم الصيغة بعد معاينة النص المستخرج ومراجعته/
//  تصحيحه يدوياً، تماماً كخطوة "تأكيد قبل الحفظ" المعتادة في باقي أدوات
//  التطبيق (راجع _ScreenPhase في word_to_pdf_screen.dart كمرجع للنمط).
//
//  ⚠️ الناتج (PDF أو DOCX) يصل في النهاية إلى ResultScreen الموحَّدة (لا
//  شاشة نتيجة مخصصة)، بنفس نمط كل أدوات التحويل الأخرى في المشروع.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/ocr_result_model.dart';
import '../../services/image_preprocessing_service.dart';
import '../../services/ocr_service.dart';
import '../../services/ocr_to_docx_service.dart';
import '../../services/scanned_pdf_extractor_service.dart';
import '../../services/searchable_pdf_builder_service.dart';
import '../../theme/app_theme.dart';
import '../result_screen.dart';

class _Palette {
  static const bg = Color(0xFF0E1220);
  static const bgCard = Color(0xFF181E32);
  static const bgCardLight = Color(0xFF222A45);
  static const blue = Color(0xFF1A365D);
  static const blueLight = Color(0xFF63B3ED);
  static const green = Color(0xFF2BC48A);
  static const orange = Color(0xFFED8936);
  static const textPrimary = Color(0xFFF3F5FB);
  static const textSecondary = Color(0xFF9AA3BC);
  static const textMuted = Color(0xFF6B7490);
  static const divider = Color(0xFF2B3354);
}

enum _OcrSourceType { camera, gallery, pdf }

enum _ScreenPhase { pick, recognizing, review }

class TextRecognitionScreen extends StatefulWidget {
  const TextRecognitionScreen({super.key});
  @override
  State<TextRecognitionScreen> createState() => _TextRecognitionScreenState();
}

class _TextRecognitionScreenState extends State<TextRecognitionScreen>
    with TickerProviderStateMixin {
  _ScreenPhase _phase = _ScreenPhase.pick;
  double _progress = 0;
  String _stage = '';

  OcrDocumentResult? _result;
  late List<TextEditingController> _textControllers;
  int _currentPageIndex = 0;
  bool _exporting = false;

  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    for (final c in _textControllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _err(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: const Color(0xFFE53E3E)),
    );
  }

  Future<void> _startFromSource(_OcrSourceType source) async {
    HapticFeedback.selectionClick();
    try {
      switch (source) {
        case _OcrSourceType.camera:
          await _processSingleImage(useCamera: true);
          break;
        case _OcrSourceType.gallery:
          await _processSingleImage(useCamera: false);
          break;
        case _OcrSourceType.pdf:
          await _processPdf();
          break;
      }
    } on OcrException catch (e) {
      _err(e.message);
      _backToPick();
    } on FormatException catch (e) {
      _err(e.message);
      _backToPick();
    } catch (e) {
      _err('حدث خطأ غير متوقع أثناء استخراج النص: $e');
      _backToPick();
    }
  }

  void _backToPick() {
    if (!mounted) return;
    setState(() {
      _phase = _ScreenPhase.pick;
      _progress = 0;
      _stage = '';
    });
  }

  Future<void> _processSingleImage({required bool useCamera}) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: useCamera ? ImageSource.camera : ImageSource.gallery,
      imageQuality: 100, // لا ضغط — جودة الصورة تؤثر مباشرة على دقة OCR
    );
    if (picked == null) return;

    final croppedPath = await _cropImage(picked.path);
    if (croppedPath == null || !mounted) return; // المستخدم ألغى الاقتصاص

    // ⚠️ تبسيط مُتعمَّد: لا حوار اختيار لغة — يُشغَّل دمج العربية+الإنجليزية
    // معاً مباشرة دوماً (نفس سلوك الإصدار الأول قبل إضافة الاختيار).
    const language = OcrLanguageSelection.both;

    HapticFeedback.mediumImpact();
    setState(() {
      _phase = _ScreenPhase.recognizing;
      _progress = 0.05;
      _stage = 'جاري تحسين جودة الصورة...';
    });

    setState(() {
      _progress = 0.3;
      _stage = 'جاري التحقق من بيانات اللغة المطلوبة...';
    });
    await OcrService.ensureLanguageDataAvailable(
      languageCodes: language.requiredLanguageCodes,
      onProgress: (lang, p) {
        if (!mounted) return;
        setState(() {
          _stage = 'جاري تحميل بيانات لغة "$lang"...';
          _progress = 0.3 + (p * 0.2);
        });
      },
    );

    setState(() {
      _stage = 'جاري التعرف على النص...';
      _progress = 0.6;
    });

    // ⚠️ إصلاح حقيقي محفوظ من إصلاح سابق: صورة من "المعرض" غالباً ما
    // تكون رقمية المنشأ (لقطة شاشة، صورة محادثة) لا مستنداً ممسوحاً
    // فعلياً بسكانر — استخدام digitalScreenshot هنا يضمن كشف/عكس
    // القطبية اللازم لخلفيات Dark Mode الشائعة جداً في لقطات الشاشة.
    final pageResult = await OcrService.recognizeImage(
      File(croppedPath),
      language: language,
      preprocessingOptions:
          useCamera ? ImagePreprocessingOptions.cameraCapture : ImagePreprocessingOptions.digitalScreenshot,
    );

    _finishWithDocument(OcrDocumentResult(pages: [pageResult], createdAt: DateTime.now()));
  }

  /// يعرض واجهة اقتصاص تفاعلية (uCrop على أندرويد عبر image_cropper)
  /// تسمح للمستخدم بسحب مقابض الزوايا لتحديد منطقة النص بدقة قبل OCR،
  /// بنفس النمط البصري المستخدم فعلياً في أداة استيراد الصور لهذا
  /// المشروع. يُعيد مسار الصورة المُقتَصة، أو null لو ألغى المستخدم.
  Future<String?> _cropImage(String sourcePath) async {
    final cropped = await ImageCropper().cropImage(
      sourcePath: sourcePath,
      compressFormat: ImageCompressFormat.png,
      compressQuality: 100,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'حدد منطقة النص',
          toolbarColor: AppTheme.primary,
          toolbarWidgetColor: Colors.white,
          backgroundColor: Colors.black,
          activeControlsWidgetColor: AppTheme.primaryLight,
          initAspectRatio: CropAspectRatioPreset.original,
          lockAspectRatio: false,
          showCropGrid: true,
        ),
      ],
    );
    return cropped?.path;
  }

  Future<void> _processPdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    final picked = result?.files.first;
    if (picked?.path == null) return;

    HapticFeedback.mediumImpact();
    setState(() {
      _phase = _ScreenPhase.recognizing;
      _progress = 0.02;
      _stage = 'جاري استخراج صفحات PDF...';
    });

    final pdfFile = File(picked!.path!);

    final extractedPages = await ScannedPdfExtractorService.extractPagesAsImages(
      pdfFile,
      onProgress: (current, total) {
        if (!mounted) return;
        setState(() {
          _stage = 'جاري استخراج الصفحة $current من $total...';
          _progress = (current / total) * 0.25;
        });
      },
    );

    await OcrService.ensureLanguageDataAvailable(
      languageCodes: OcrLanguageSelection.both.requiredLanguageCodes,
    );

    final pageResults = <OcrPageResult>[];
    for (int i = 0; i < extractedPages.length; i++) {
      setState(() {
        _stage = 'جاري التعرف على نص الصفحة ${i + 1} من ${extractedPages.length}...';
        _progress = 0.25 + ((i / extractedPages.length) * 0.7);
      });

      final pageResult = await OcrService.recognizeImage(
        extractedPages[i].imageFile,
        preprocessingOptions: ImagePreprocessingOptions.scannedDocument,
      );
      pageResults.add(pageResult);
    }

    await ScannedPdfExtractorService.cleanup(extractedPages);

    _finishWithDocument(OcrDocumentResult(pages: pageResults, createdAt: DateTime.now()));
  }

  void _finishWithDocument(OcrDocumentResult document) {
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    _textControllers = document.pages.map((p) => TextEditingController(text: p.fullText)).toList();
    setState(() {
      _result = document;
      _currentPageIndex = 0;
      _phase = _ScreenPhase.review;
      _progress = 1.0;
    });
  }

  Future<void> _exportSearchablePdf() async {
    if (_result == null) return;
    setState(() => _exporting = true);
    try {
      // ⚠️ يُصدَّر من بيانات OCR الأصلية (مع صناديق الإحداثيات الدقيقة)
      // لا من نص الحقول المُعدَّلة — لأن طبقة النص الشفافة يجب أن تطابق
      // مواضع الكلمات الفعلية في الصورة بالضبط. أي تصحيح يدوي للنص ينطبق
      // فقط على تصدير DOCX (نص حر بلا قيد موضعي).
      final file = await SearchablePdfBuilderService.buildAndSave(_result!);
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => ResultScreen(
        file: file,
        title: 'تم استخراج النص بنجاح!',
        subtitle: 'تم إنشاء PDF قابل للبحث يحافظ على شكل المستند الأصلي.',
        toolId: 'ocr_pdf',
        toolName: 'استخراج النص (OCR)',
      )));
    } catch (e) {
      _err('فشل إنشاء PDF القابل للبحث: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _exportDocx() async {
    if (_result == null) return;
    setState(() => _exporting = true);
    try {
      // يُصدَّر النص المُعدَّل يدوياً (لا الخام)، لأن DOCX نص حر بلا قيد
      // موضعي — يستفيد المستخدم من أي تصحيح طبّقه في حقول المراجعة.
      final editedDocument = _buildDocumentWithEditedText();
      final file = await OcrToDocxService.build(editedDocument);
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => ResultScreen(
        file: file,
        title: 'تم استخراج النص بنجاح!',
        subtitle: 'تم إنشاء مستند Word قابل للتعديل من النص المستخرج.',
        toolId: 'ocr_pdf',
        toolName: 'استخراج النص (OCR)',
      )));
    } catch (e) {
      _err('فشل إنشاء ملف Word: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// يبني نسخة من نتيجة OCR تستبدل نص كل صفحة بالنص المُعدَّل من حقل
  /// المراجعة المقابل. غير مستخدَم لتصدير PDF (يعتمد على الصناديق
  /// الأصلية)؛ فقط لتصدير DOCX (نص حر بلا قيد موضعي).
  OcrDocumentResult _buildDocumentWithEditedText() {
    final pages = <OcrPageResult>[];
    for (int i = 0; i < _result!.pages.length; i++) {
      final original = _result!.pages[i];
      final editedText = _textControllers[i].text;
      final paragraphs = editedText.split('\n\n').where((p) => p.trim().isNotEmpty);

      final blocks = paragraphs.map((paragraphText) {
        final lines = paragraphText.split('\n').map((lineText) {
          final isRtl = RegExp(r'[\u0600-\u06FF]').allMatches(lineText).length >=
              RegExp(r'[A-Za-z]').allMatches(lineText).length;
          return OcrLine(
            words: [
              OcrWord(
                text: lineText,
                boundingBox: const OcrBoundingBox(left: 0, top: 0, width: 0, height: 0),
                confidence: 100,
              ),
            ],
            boundingBox: const OcrBoundingBox(left: 0, top: 0, width: 0, height: 0),
            direction: isRtl ? OcrTextDirection.rtl : OcrTextDirection.ltr,
          );
        }).toList();
        return OcrBlock(
          lines: lines,
          boundingBox: const OcrBoundingBox(left: 0, top: 0, width: 0, height: 0),
        );
      }).toList();

      pages.add(OcrPageResult(
        sourceImagePath: original.sourceImagePath,
        imageWidthPx: original.imageWidthPx,
        imageHeightPx: original.imageHeightPx,
        blocks: blocks,
        processingTimeMs: original.processingTimeMs,
      ));
    }
    return OcrDocumentResult(pages: pages, createdAt: _result!.createdAt);
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: _Palette.bg,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text('استخراج النص (OCR)',
              style: GoogleFonts.cairo(color: _Palette.textPrimary, fontWeight: FontWeight.w700)),
          iconTheme: const IconThemeData(color: _Palette.textPrimary),
        ),
        body: SafeArea(
          child: switch (_phase) {
            _ScreenPhase.pick => _buildPickView(),
            _ScreenPhase.recognizing => _buildProgressView(),
            _ScreenPhase.review => _buildReviewView(),
          },
        ),
      ),
    );
  }

  Widget _buildPickView() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'اختر مصدر النص الذي تريد استخراجه. يدعم النص العربي والإنجليزي معاً في الصورة نفسها.',
            style: GoogleFonts.cairo(fontSize: 14, color: _Palette.textSecondary, height: 1.6),
          ),
          const SizedBox(height: 28),
          _SourceCard(
            icon: Icons.camera_alt_rounded,
            title: 'تصوير مباشر بالكاميرا',
            subtitle: 'صوّر صفحة أو لافتة الآن',
            color: _Palette.blueLight,
            onTap: () => _startFromSource(_OcrSourceType.camera),
          ),
          const SizedBox(height: 12),
          _SourceCard(
            icon: Icons.image_rounded,
            title: 'اختيار صورة من المعرض',
            subtitle: 'صورة محفوظة مسبقاً على الجهاز',
            color: _Palette.green,
            onTap: () => _startFromSource(_OcrSourceType.gallery),
          ),
          const SizedBox(height: 12),
          _SourceCard(
            icon: Icons.picture_as_pdf_rounded,
            title: 'ملف PDF ممسوح',
            subtitle: 'استخراج النص من كل صفحات الملف دفعة واحدة',
            color: _Palette.orange,
            onTap: () => _startFromSource(_OcrSourceType.pdf),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _pulseCtrl,
              builder: (context, child) {
                final scale = 1.0 + (0.06 * _pulseCtrl.value);
                return Transform.scale(
                  scale: scale,
                  child: Container(
                    width: 84,
                    height: 84,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: [_Palette.blue, _Palette.blueLight]),
                    ),
                    child: const Icon(Icons.document_scanner_rounded, color: Colors.white, size: 38),
                  ),
                );
              },
            ),
            const SizedBox(height: 28),
            Text(_stage,
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(fontSize: 15, color: _Palette.textPrimary, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: 8,
                backgroundColor: _Palette.bgCardLight,
                color: _Palette.blueLight,
              ),
            ),
            const SizedBox(height: 8),
            Text('${(_progress * 100).clamp(0, 100).toStringAsFixed(0)}٪',
                style: GoogleFonts.cairo(fontSize: 12, color: _Palette.textMuted)),
          ],
        ),
      ),
    );
  }

  Widget _buildReviewView() {
    final result = _result!;
    final pageCount = result.pages.length;
    final page = result.pages[_currentPageIndex];
    final controller = _textControllers[_currentPageIndex];
    final lowConfidence = page.averageConfidence > 0 && page.averageConfidence < 65.0;

    return Column(
      children: [
        if (pageCount > 1)
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: pageCount,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final selected = index == _currentPageIndex;
                return GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() => _currentPageIndex = index);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected ? _Palette.blueLight.withValues(alpha: 0.18) : _Palette.bgCard,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: selected ? _Palette.blueLight : _Palette.divider),
                    ),
                    child: Text('صفحة ${index + 1}',
                        style: GoogleFonts.cairo(
                            fontSize: 12,
                            color: selected ? _Palette.blueLight : _Palette.textSecondary,
                            fontWeight: FontWeight.w700)),
                  ),
                );
              },
            ),
          ),
        if (lowConfidence)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _Palette.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _Palette.orange.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline_rounded, color: _Palette.orange, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'دقة التعرف منخفضة لهذه الصفحة (${page.averageConfidence.toStringAsFixed(0)}٪). يُنصح بمراجعة النص يدوياً قبل الحفظ.',
                    style: GoogleFonts.cairo(fontSize: 12, color: _Palette.orange, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _Palette.bgCard,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _Palette.divider),
              ),
              child: TextField(
                controller: controller,
                maxLines: null,
                expands: true,
                textDirection: _detectOverallDirection(controller.text),
                style: GoogleFonts.cairo(fontSize: 15, color: _Palette.textPrimary, height: 1.7),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: 'النص المستخرج...',
                  hintStyle: GoogleFonts.cairo(color: _Palette.textMuted),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: _exporting
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Center(child: CircularProgressIndicator(color: _Palette.blueLight)),
                )
              : Row(
                  children: [
                    Expanded(
                      child: _ExportButton(
                        label: 'حفظ كـ Word',
                        icon: Icons.description_rounded,
                        color: _Palette.green,
                        onTap: _exportDocx,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ExportButton(
                        label: 'PDF قابل للبحث',
                        icon: Icons.picture_as_pdf_rounded,
                        color: _Palette.blueLight,
                        onTap: _exportSearchablePdf,
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  TextDirection _detectOverallDirection(String text) {
    final arabicCount = RegExp(r'[\u0600-\u06FF]').allMatches(text).length;
    final latinCount = RegExp(r'[A-Za-z]').allMatches(text).length;
    return arabicCount >= latinCount ? TextDirection.rtl : TextDirection.ltr;
  }
}

class _SourceCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _SourceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _Palette.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _Palette.divider),
        ),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: GoogleFonts.cairo(
                          fontSize: 14, fontWeight: FontWeight.w700, color: _Palette.textPrimary)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: GoogleFonts.cairo(fontSize: 12, color: _Palette.textMuted)),
                ],
              ),
            ),
            const Icon(Icons.arrow_back_ios_rounded, size: 14, color: _Palette.textMuted),
          ],
        ),
      ),
    );
  }
}

class _ExportButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ExportButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            Text(label, style: GoogleFonts.cairo(color: color, fontWeight: FontWeight.w700, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
