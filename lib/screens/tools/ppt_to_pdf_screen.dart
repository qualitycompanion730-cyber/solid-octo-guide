// ═══════════════════════════════════════════════════════════════════════════
//  PPT إلى PDF — شاشة بتصميم خاص مستقل
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/ppt_to_pdf_converter.dart';
import '../../services/isolate_support.dart';
// ignore: unused_import
import '../../theme/app_theme.dart';
import '../result_screen.dart';
import '../../widgets/pulsing_dots_indicator.dart';
import '../../widgets/progress_ring_painter.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  لوحة الألوان الخاصة بـ PPT
// ─────────────────────────────────────────────────────────────────────────────
class _Palette {
  static const bg           = Color(0xFF0E1220);
  static const bgCard       = Color(0xFF181E32);
  static const bgCardLight  = Color(0xFF222A45);

  static const orange       = Color(0xFFED8936);
  static const orangeDark   = Color(0xFFC05621);

  static const gold         = Color(0xFFF6C347);

  static const green        = Color(0xFF2BC48A);
  static const greenDark    = Color(0xFF15803D);

  static const textPrimary   = Color(0xFFF3F5FB);
  static const textSecondary = Color(0xFF9AA3BC);
  static const textMuted     = Color(0xFF6B7490);
  static const divider       = Color(0xFF2B3354);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Widget رئيسي
// ─────────────────────────────────────────────────────────────────────────────
class PptToPdfScreen extends StatefulWidget {
  const PptToPdfScreen({super.key});
  @override
  State<PptToPdfScreen> createState() => _PptToPdfScreenState();
}

enum _ScreenPhase { pick, converting }

class _PptToPdfScreenState extends State<PptToPdfScreen>
    with TickerProviderStateMixin {
  // ── حالة الملف ─────────────────────────────────────────────────────────────
  File?   _file;
  String  _fileName = '';

  // ── مرحلة الشاشة ───────────────────────────────────────────────────────────
  _ScreenPhase _phase = _ScreenPhase.pick;

  // ── حالة التحويل ───────────────────────────────────────────────────────────
  double         _progress = 0;
  String         _stage    = '';
  PptCancelToken? _cancelToken;

  // ── متحكمات الأنيميشن ──────────────────────────────────────────────────────
  late final AnimationController _pulseCtrl;
  late final AnimationController _dashCtrl;
  late final AnimationController _slideShowCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat();
    _dashCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 6))
      ..repeat();
    _slideShowCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2000))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _dashCtrl.dispose();
    _slideShowCtrl.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  منطق الملف
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _pickFile() async {
    HapticFeedback.selectionClick();
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pptx', 'odp'],
    );
    final picked = r?.files.first;
    if (picked?.path != null) {
      HapticFeedback.lightImpact();
      setState(() {
        _file     = File(picked!.path!);
        _fileName = picked.name;
      });
      // لا نحوّل مباشرةً — ننتظر ضغط المستخدم على زر "تحويل".
    }
  }

  void _clearSelectedFile() {
    HapticFeedback.selectionClick();
    setState(() {
      _file     = null;
      _fileName = '';
    });
  }

  String _ext() => _file!.path.split('.').last.toLowerCase();

  // ─────────────────────────────────────────────────────────────────────────
  //  منطق التحويل
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _startConversion() async {
    if (_file == null) return;
    final ext = _ext();
    if (ext == 'ppt') {
      _err('صيغة .ppt القديمة غير مدعومة — احفظ الملف بصيغة .pptx ثم أعد المحاولة');
      return;
    }

    HapticFeedback.mediumImpact();
    _cancelToken = PptCancelToken();
    setState(() {
      _phase    = _ScreenPhase.converting;
      _progress = 0;
      _stage    = 'بدء التحويل...';
    });

    try {
      // تحميل خط NotoNaskhArabic من assets إلى ملف مؤقت يقرأه Syncfusion
      // (rootBundle يُرجع ByteData؛ PdfTrueTypeFont يحتاج مساراً على القرص)
      String? arabicFontPath;
      String? arabicBoldFontPath;
      try {
        final dir = await getApplicationSupportDirectory();

        final regular = File('${dir.path}/NotoNaskhArabic-Regular.ttf');
        if (!regular.existsSync()) {
          final data = await rootBundle.load('assets/fonts/NotoNaskhArabic-Regular.ttf');
          await regular.writeAsBytes(data.buffer.asUint8List(), flush: true);
        }
        arabicFontPath = regular.path;

        final bold = File('${dir.path}/NotoNaskhArabic-Bold.ttf');
        if (!bold.existsSync()) {
          final data = await rootBundle.load('assets/fonts/NotoNaskhArabic-Bold.ttf');
          await bold.writeAsBytes(data.buffer.asUint8List(), flush: true);
        }
        arabicBoldFontPath = bold.path;
      } catch (_) {
        // إذا تعذّر التحميل، يستخدم المحوّل الخط الاحتياطي المدمج
      }

      final options = PptConversionOptions(
        slideLayout:              PptSlideLayout.fromFile,
        theme:                    PptTheme.light,
        slidesPerPage:            1,
        showSlideNumbers:         false,
        showSlideThumbnailBorder: false,
        arabicFontPath:           arabicFontPath,
        arabicBoldFontPath:       arabicBoldFontPath,
      );

      final Uint8List outBytes = await convertPptInBackground(
        _file!,
        options:     options,
        cancelToken: _cancelToken,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _progress = p.progress;
            _stage    = p.stage;
          });
        },
      );

      if (_cancelToken?.isCancelled == true) {
        _backToPick();
        return;
      }

      setState(() {
        _progress = 0.97;
        _stage    = 'حفظ الملف...';
      });

      final dir  = await getTemporaryDirectory();
      final name = _fileName.replaceAll(
          RegExp(r'\.(pptx|odp)$', caseSensitive: false), '');
      final out  = File('${dir.path}/$name.pdf');
      await out.writeAsBytes(outBytes);

      if (!mounted) return;
      HapticFeedback.heavyImpact();
      final originalName = _fileName;
      _backToPick();
      // ⚠️ تعميم: تنتقل الآن إلى ResultScreen الموحَّدة بدل شاشة نجاح
      // محلية مكرّرة.
      Navigator.push(context, MaterialPageRoute(builder: (_) => ResultScreen(
        file: out,
        title: 'تم تحويل الملف بنجاح!',
        subtitle: 'تم إنشاء PDF بجودة عالية من العرض التقديمي الأصلي.',
        toolId: 'ppt_to_pdf',
        toolName: 'PPT إلى PDF',
        settings: {'الملف الأصلي': originalName},
      )));
    } on PptCancelledException {
      _backToPick();
    } catch (e) {
      _backToPick();
      final msg = e.toString().replaceFirst('Exception: ', '');
      _err(msg.contains('PptConversionException')
          ? msg
          : 'خطأ غير متوقع: $msg');
    }
  }

  void _cancelConversion() {
    HapticFeedback.lightImpact();
    _cancelToken?.cancel();
    _backToPick();
  }

  void _backToPick() {
    if (!mounted) return;
    setState(() {
      _phase    = _ScreenPhase.pick;
      _file     = null;
      _fileName = '';
    });
  }

  void _err(String msg) => _toast(msg, Colors.red.shade700);

  void _toast(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content:   Text(msg, style: GoogleFonts.cairo(color: Colors.white)),
      backgroundColor: color,
      behavior:  SnackBarBehavior.floating,
      shape:     RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin:    const EdgeInsets.all(16),
    ));
  }

  String _formatSize(int b) {
    if (b > 1048576) return '${(b / 1048576).toStringAsFixed(1)} MB';
    return '${(b / 1024).toStringAsFixed(0)} KB';
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Build الرئيسي
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _Palette.bg,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0E1220), Color(0xFF161A2E), Color(0xFF0E1220)],
            begin: Alignment.topRight,
            end:   Alignment.bottomLeft,
          ),
        ),
        child: SafeArea(
          child: AnimatedSwitcher(
            duration:        const Duration(milliseconds: 350),
            switchInCurve:   Curves.easeOutCubic,
            switchOutCurve:  Curves.easeInCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.04),
                  end:   Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            child: switch (_phase) {
              _ScreenPhase.pick       => _buildPickPhase(),
              _ScreenPhase.converting => _buildConvertingPhase(),
            },
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  مرحلة الاختيار
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildPickPhase() {
    return Column(
      key: const ValueKey('pick'),
      children: [
        _buildHeader(),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildToolBanner(),
                const SizedBox(height: 16),
                _buildUploadZone(),
                const SizedBox(height: 14),
                _buildPrivacyBanner(),
                const SizedBox(height: 90),
              ],
            ),
          ),
        ),
        _buildBottomBar(),
      ],
    );
  }

  // ── الهيدر ────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Row(
        textDirection: TextDirection.rtl,
        children: [
          _CircleIconButton(
            icon:  Icons.arrow_forward_ios_rounded,
            onTap: () => Navigator.pop(context),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('PPT ← PDF',
                    textDirection: TextDirection.rtl,
                    style: GoogleFonts.cairo(
                        fontSize:   20,
                        fontWeight: FontWeight.w800,
                        color:      _Palette.textPrimary)),
                Text('شرائح احترافية بجودة عالية',
                    textDirection: TextDirection.rtl,
                    style: GoogleFonts.cairo(
                        fontSize: 12, color: _Palette.textSecondary)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color:        _Palette.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border:       Border.all(color: _Palette.orange.withValues(alpha: 0.35)),
            ),
            child: Text('PPTX',
                style: GoogleFonts.cairo(
                    fontSize:   11,
                    fontWeight: FontWeight.w800,
                    color:      _Palette.orange)),
          ),
        ],
      ),
    );
  }

  // ── بانر الأداة ────────────────────────────────────────────────────────────
  Widget _buildToolBanner() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: [
            _Palette.orangeDark.withValues(alpha: 0.28),
            _Palette.bgCard,
          ],
          begin: Alignment.topRight,
          end:   Alignment.bottomLeft,
        ),
        border: Border.all(color: _Palette.orange.withValues(alpha: 0.28)),
        boxShadow: [
          BoxShadow(
            color:      _Palette.orange.withValues(alpha: 0.10),
            blurRadius: 24,
            offset:     const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        textDirection: TextDirection.rtl,
        children: [
          AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (context, _) {
              final glow = 0.25 + 0.15 * math.sin(_pulseCtrl.value * 2 * math.pi);
              return Container(
                width:  58,
                height: 58,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: const LinearGradient(
                    colors: [_Palette.orange, _Palette.orangeDark],
                    begin:  Alignment.topLeft,
                    end:    Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color:      _Palette.orange.withValues(alpha: glow),
                      blurRadius: 22,
                    ),
                  ],
                ),
                child: const Icon(Icons.slideshow_rounded,
                    color: Colors.white, size: 30),
              );
            },
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('تحويل العروض التقديمية',
                    textDirection: TextDirection.rtl,
                    style: GoogleFonts.cairo(
                        fontSize:   17,
                        fontWeight: FontWeight.w800,
                        color:      _Palette.orange)),
                const SizedBox(height: 2),
                Text(
                  'تحويل شرائح PPTX إلى PDF مع الحفاظ على التصميم والنصوص والأشكال وترتيب الصفحات.',
                  textDirection: TextDirection.rtl,
                  style: GoogleFonts.cairo(
                      fontSize: 12, color: _Palette.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── منطقة الرفع ────────────────────────────────────────────────────────────
  Widget _buildUploadZone() {
    final hasFile = _file != null;
    return GestureDetector(
      onTap: hasFile ? null : _pickFile,
      child: AnimatedBuilder(
        animation: _dashCtrl,
        builder: (context, child) => CustomPaint(
          painter: _DashedBorderPainter(
            color: hasFile
                ? _Palette.green.withValues(alpha: 0.55)
                : _Palette.orange.withValues(alpha: 0.45),
            phase:  _dashCtrl.value,
            radius: 20,
          ),
          child: child,
        ),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color:        _Palette.bgCard.withValues(alpha: 0.6),
          ),
          child: hasFile ? _buildSelectedFileCard() : _buildEmptyDropContent(),
        ),
      ),
    );
  }

  // محتوى منطقة الرفع عندما لا يوجد ملف مختار
  Widget _buildEmptyDropContent() {
    return Column(
      children: [
        const SizedBox(height: 6),
        // أيقونة شريحة متحركة
        AnimatedBuilder(
          animation: _slideShowCtrl,
          builder: (context, _) {
            final float = 2.0 * math.sin(_slideShowCtrl.value * math.pi);
            return Transform.translate(
              offset: Offset(0, -float),
              child: Container(
                width:  70,
                height: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  gradient: LinearGradient(
                    colors: [
                      _Palette.orangeDark.withValues(alpha: 0.85),
                      _Palette.orange.withValues(alpha: 0.85),
                    ],
                    begin: Alignment.topLeft,
                    end:   Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color:      _Palette.orange.withValues(alpha: 0.30),
                      blurRadius: 12,
                      offset:     const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width:  42, height: 6,
                      decoration: BoxDecoration(
                        color:        Colors.white.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Container(
                      width:  30, height: 4,
                      decoration: BoxDecoration(
                        color:        Colors.white.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Container(
                      width:  36, height: 4,
                      decoration: BoxDecoration(
                        color:        Colors.white.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 14),
        Text('انقر لاختيار عرض تقديمي',
            style: GoogleFonts.cairo(
                fontSize:   16,
                fontWeight: FontWeight.w800,
                color:      _Palette.textPrimary)),
        const SizedBox(height: 4),
        Text('PPTX أو ODP',
            style: GoogleFonts.cairo(
                fontSize: 12, color: _Palette.textMuted)),
        const SizedBox(height: 6),
      ],
    );
  }

  // بطاقة الملف المختار (قبل التحويل)
  Widget _buildSelectedFileCard() {
    final sizeStr = () {
      try {
        return _formatSize(_file!.lengthSync());
      } catch (_) {
        return '';
      }
    }();
    return Column(
      children: [
        Row(
          textDirection: TextDirection.rtl,
          children: [
            Container(
              width:  52,
              height: 52,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: const LinearGradient(
                  colors: [_Palette.orange, _Palette.orangeDark],
                  begin:  Alignment.topRight,
                  end:    Alignment.bottomLeft,
                ),
              ),
              child: const Icon(Icons.slideshow_rounded,
                  color: Colors.white, size: 28),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _fileName,
                    textDirection: TextDirection.rtl,
                    maxLines:      2,
                    overflow:      TextOverflow.ellipsis,
                    style: GoogleFonts.cairo(
                        fontSize:   14.5,
                        fontWeight: FontWeight.w800,
                        color:      _Palette.textPrimary),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    textDirection: TextDirection.rtl,
                    children: [
                      const Icon(Icons.check_circle_rounded,
                          color: _Palette.green, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        sizeStr.isEmpty ? 'جاهز للتحويل' : '$sizeStr • جاهز للتحويل',
                        textDirection: TextDirection.rtl,
                        style: GoogleFonts.cairo(
                            fontSize: 12, color: _Palette.green),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            GestureDetector(
              onTap: _clearSelectedFile,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: _Palette.bgCardLight,
                ),
                child: const Icon(Icons.close_rounded,
                    color: _Palette.textMuted, size: 18),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // زر تغيير الملف
        GestureDetector(
          onTap: _pickFile,
          child: Container(
            width:   double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color:  _Palette.bgCardLight,
              border: Border.all(color: _Palette.divider),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              textDirection:     TextDirection.rtl,
              children: [
                const Icon(Icons.swap_horiz_rounded,
                    color: _Palette.textSecondary, size: 18),
                const SizedBox(width: 8),
                Text('اختيار ملف آخر',
                    style: GoogleFonts.cairo(
                        fontSize:   13,
                        fontWeight: FontWeight.w700,
                        color:      _Palette.textSecondary)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── بانر الخصوصية ──────────────────────────────────────────────────────────
  Widget _buildPrivacyBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color:  _Palette.greenDark.withValues(alpha: 0.15),
        border: Border.all(color: _Palette.green.withValues(alpha: 0.35)),
      ),
      child: Row(
        textDirection: TextDirection.rtl,
        children: [
          const Icon(Icons.verified_user_rounded, color: _Palette.green, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'معالجة محلية 100% • ملفاتك لا تُرفع إلى أي خادم',
              textDirection: TextDirection.rtl,
              style: GoogleFonts.cairo(
                  fontSize:   12.5,
                  fontWeight: FontWeight.w600,
                  color:      _Palette.green),
            ),
          ),
        ],
      ),
    );
  }

  // ── الشريط السفلي ──────────────────────────────────────────────────────────
  Widget _buildBottomBar() {
    final hasFile = _file != null;
    final gradient = hasFile
        ? const [_Palette.green, _Palette.greenDark]
        : const [_Palette.orange, _Palette.orangeDark];
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
      decoration: BoxDecoration(
        color:        _Palette.bgCard,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color:      Colors.black.withValues(alpha: 0.35),
            blurRadius: 24,
            offset:     const Offset(0, -8),
          ),
        ],
      ),
      child: GestureDetector(
        onTap: hasFile ? _startConversion : _pickFile,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              colors: gradient,
              begin:  Alignment.centerRight,
              end:    Alignment.centerLeft,
            ),
            boxShadow: [
              BoxShadow(
                color:      gradient.first.withValues(alpha: 0.4),
                blurRadius: 20,
                offset:     const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            textDirection: TextDirection.rtl,
            children: [
              Icon(hasFile ? Icons.picture_as_pdf_rounded : Icons.bolt_rounded,
                  color: Colors.white, size: 22),
              const SizedBox(width: 8),
              Text(
                hasFile ? 'تحويل إلى PDF الآن' : 'اختر ملفاً للبدء',
                style: GoogleFonts.cairo(
                    fontSize:   16,
                    fontWeight: FontWeight.w800,
                    color:      Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  مرحلة التحويل — واجهة انتظار محسّنة
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildConvertingPhase() {
    return Center(
      key: const ValueKey('converting'),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Container(
          margin:  const EdgeInsets.symmetric(horizontal: 24),
          padding: const EdgeInsets.fromLTRB(26, 34, 26, 26),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            gradient: const LinearGradient(
              colors: [_Palette.bgCard, _Palette.bg],
              begin:  Alignment.topRight,
              end:    Alignment.bottomLeft,
            ),
            border: Border.all(color: _Palette.orange.withValues(alpha: 0.22)),
            boxShadow: [
              BoxShadow(
                color:      _Palette.orange.withValues(alpha: 0.12),
                blurRadius: 40,
                spreadRadius: 2,
              ),
              BoxShadow(
                color:      Colors.black.withValues(alpha: 0.5),
                blurRadius: 40,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── حلقة التقدم مع تحوّل شريحة → PDF ──
              SizedBox(
                width:  148,
                height: 148,
                child: AnimatedBuilder(
                  animation: Listenable.merge([_pulseCtrl, _slideShowCtrl]),
                  builder: (context, _) {
                    return CustomPaint(
                      painter: ProgressRingPainter(
                        progress:   _progress,
                        pulse:      _pulseCtrl.value,
                        accent:     _Palette.orange,
                        accentDeep: _Palette.gold,
                      ),
                      child: Center(
                        child: Container(
                          width:  86,
                          height: 86,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [
                                _Palette.orange.withValues(alpha: 0.18),
                                _Palette.gold.withValues(alpha: 0.10),
                              ],
                              begin: Alignment.topLeft,
                              end:   Alignment.bottomRight,
                            ),
                            border: Border.all(
                                color: _Palette.orange.withValues(alpha: 0.30),
                                width: 1),
                          ),
                          child: _MorphSlideToPdf(t: _slideShowCtrl.value),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 26),

              Text('جارٍ تحويل عرضك التقديمي',
                  textDirection: TextDirection.rtl,
                  style: GoogleFonts.cairo(
                      fontSize:   19,
                      fontWeight: FontWeight.w900,
                      color:      _Palette.textPrimary)),
              const SizedBox(height: 6),

              // اسم الملف
              if (_fileName.isNotEmpty)
                Text(_fileName,
                    textDirection: TextDirection.rtl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.cairo(
                        fontSize:   12.5,
                        fontWeight: FontWeight.w600,
                        color:      _Palette.orange)),
              const SizedBox(height: 14),

              // المرحلة الحالية
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(_stage,
                    key: ValueKey(_stage),
                    textAlign:     TextAlign.center,
                    textDirection: TextDirection.rtl,
                    style: GoogleFonts.cairo(
                        fontSize: 13, color: _Palette.textSecondary)),
              ),
              const SizedBox(height: 20),

              // شريط التقدم
              Stack(
                alignment: Alignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value:           _progress == 0 ? null : _progress,
                      backgroundColor: _Palette.bgCardLight,
                      valueColor: const AlwaysStoppedAnimation(_Palette.orange),
                      minHeight:       8,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('${(_progress * 100).toStringAsFixed(0)}%',
                      style: GoogleFonts.cairo(
                          fontSize:   15,
                          fontWeight: FontWeight.w900,
                          color:      _Palette.orange)),
                  const SizedBox(width: 8),
                  PulsingDotsIndicator(
                      controller: _pulseCtrl, color: _Palette.orange),
                ],
              ),
              const SizedBox(height: 18),

              // شارة المعالجة المحلية
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: _Palette.green.withValues(alpha: 0.12),
                  border:
                      Border.all(color: _Palette.green.withValues(alpha: 0.35)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  textDirection: TextDirection.rtl,
                  children: [
                    const Icon(Icons.lock_rounded,
                        color: _Palette.green, size: 13),
                    const SizedBox(width: 6),
                    Text('معالجة محلية آمنة 100%',
                        textDirection: TextDirection.rtl,
                        style: GoogleFonts.cairo(
                            fontSize:   11.5,
                            fontWeight: FontWeight.w700,
                            color:      _Palette.green)),
                  ],
                ),
              ),
              const SizedBox(height: 22),

              // زر الإلغاء
              GestureDetector(
                onTap: _cancelConversion,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32, vertical: 11),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: _Palette.bgCardLight,
                    border: Border.all(
                        color: _Palette.divider.withValues(alpha: 0.7)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    textDirection: TextDirection.rtl,
                    children: [
                      const Icon(Icons.close_rounded,
                          color: _Palette.textMuted, size: 16),
                      const SizedBox(width: 6),
                      Text('إلغاء',
                          style: GoogleFonts.cairo(
                              fontSize:   13,
                              fontWeight: FontWeight.w700,
                              color:      _Palette.textMuted)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Widgets مساعدة
// ─────────────────────────────────────────────────────────────────────────────

class _CircleIconButton extends StatelessWidget {
  final IconData   icon;
  final VoidCallback onTap;
  const _CircleIconButton(
      {required this.icon,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        width:  42,
        height: 42,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color:  _Palette.bgCardLight,
          border: Border.all(color: _Palette.divider),
        ),
        child: Icon(icon,
            size:  42 * 0.42,
            color: _Palette.textSecondary),
      ),
    );
  }
}

// ── أيقونة متحركة: شريحة تتحوّل إلى PDF في مركز الحلقة ───────────────────────
class _MorphSlideToPdf extends StatelessWidget {
  final double t; // 0..1
  const _MorphSlideToPdf({required this.t});

  @override
  Widget build(BuildContext context) {
    // نتنقل بين أيقونة الشريحة وأيقونة PDF بتلاشٍ متبادل + قفزة خفيفة
    final fade  = (math.sin(t * math.pi)).clamp(0.0, 1.0);
    final lift  = -3.0 * math.sin(t * math.pi);
    return Transform.translate(
      offset: Offset(0, lift),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Opacity(
            opacity: 1 - fade,
            child: const Icon(Icons.slideshow_rounded,
                color: _Palette.orange, size: 38),
          ),
          Opacity(
            opacity: fade,
            child: const Icon(Icons.picture_as_pdf_rounded,
                color: _Palette.gold, size: 38),
          ),
        ],
      ),
    );
  }
}


class _DashedBorderPainter extends CustomPainter {
  final Color  color;
  final double phase;
  final double radius;

  _DashedBorderPainter(
      {required this.color, required this.phase, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color       = color
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap   = StrokeCap.round;
    final rrect   = RRect.fromRectAndRadius(
        Offset.zero & size, Radius.circular(radius));
    final path    = Path()..addRRect(rrect);
    const dash    = 8.0;
    const gap     = 6.0;
    final metrics = path.computeMetrics();
    for (final metric in metrics) {
      double dist = -phase * (dash + gap) * 4;
      while (dist < metric.length) {
        final start = dist.clamp(0.0, metric.length);
        final end   = (dist + dash).clamp(0.0, metric.length);
        if (end > start) {
          canvas.drawPath(metric.extractPath(start, end), paint);
        }
        dist += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) =>
      old.phase != phase || old.color != color;
}


