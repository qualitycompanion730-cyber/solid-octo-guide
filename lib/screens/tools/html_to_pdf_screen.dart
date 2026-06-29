// ═══════════════════════════════════════════════════════════════════════════
//  HTML إلى PDF — شاشة بتصميم خاص مستقل
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/html_to_pdf_converter.dart';
import '../../services/isolate_support.dart';
import '../../widgets/conversion_progress_widget.dart';
import '../result_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  لوحة الألوان الخاصة بـ HTML
// ─────────────────────────────────────────────────────────────────────────────
class _Palette {
  static const bg = Color(0xFF0E1220);
  static const bgCard = Color(0xFF181E32);
  static const bgCardLight = Color(0xFF222A45);

  static const orange = Color(0xFFFB7C3C);
  static const orangeDark = Color(0xFFC2410C);

  static const green = Color(0xFF2BC48A);
  static const greenDark = Color(0xFF15803D);

  static const textPrimary = Color(0xFFF3F5FB);
  static const textSecondary = Color(0xFF9AA3BC);
  static const textMuted = Color(0xFF6B7490);
  static const divider = Color(0xFF2B3354);
}

class HtmlToPdfScreen extends StatefulWidget {
  const HtmlToPdfScreen({super.key});
  @override
  State<HtmlToPdfScreen> createState() => _HtmlToPdfScreenState();
}

enum _ScreenPhase { pick, converting }

class _HtmlToPdfScreenState extends State<HtmlToPdfScreen>
    with TickerProviderStateMixin {
  File? _file;
  String _fileName = '';
  int _fileSize = 0;

  _ScreenPhase _phase = _ScreenPhase.pick;

  double _progress = 0;
  String _stage = '';
  bool _cancelled = false;
  HtmlCancelToken? _cancelToken;

  late final AnimationController _pulseCtrl;
  late final AnimationController _dashCtrl;
  late final AnimationController _breatheCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat();
    _dashCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 7))
      ..repeat();
    _breatheCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _dashCtrl.dispose();
    _breatheCtrl.dispose();
    super.dispose();
  }

  String _formatSize(int b) {
    if (b > 1048576) return '${(b / 1048576).toStringAsFixed(1)} MB';
    return '${(b / 1024).toStringAsFixed(0)} KB';
  }

  Future<void> _pickFile() async {
    HapticFeedback.selectionClick();
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['html', 'htm'],
    );
    final picked = r?.files.first;
    if (picked?.path != null) {
      HapticFeedback.lightImpact();
      setState(() {
        _file = File(picked!.path!);
        _fileName = picked.name;
        _fileSize = picked.size;
      });
    }
  }

  void _clearFile() {
    HapticFeedback.lightImpact();
    setState(() {
      _file = null;
      _fileName = '';
      _fileSize = 0;
    });
  }

  String _ext() => _file!.path.split('.').last.toLowerCase();

  // ⚠️ أُزيل _extractReadableText و _buildPdfBytes بالكامل من هنا — كانا
  // يحوّلان HTML إلى نص خام عبر Regex (تجاهل كامل للجداول/العناوين/
  // القوائم/الصور) ويفرضان RTL ومحاذاة يمين دائماً حتى لمحتوى إنجليزي
  // بحت، ويعملان على Main Isolate مباشرة (تجميد واجهة المستخدم على ملفات
  // كبيرة). الخدمة الحقيقية الغنية (HtmlToPdfConverter في
  // lib/services/html_to_pdf_converter.dart) تُستدعى الآن مباشرة أدناه
  // عبر convertHtmlInBackground (تحليل في Worker Isolate، رسم فعلي عبر
  // الجسر الأصلي من Main Isolate).

  Future<void> _startConversion() async {
    if (_file == null) return;
    HapticFeedback.mediumImpact();
    _cancelled = false;
    _cancelToken = HtmlCancelToken();
    setState(() {
      _phase = _ScreenPhase.converting;
      _progress = 0;
      _stage = 'قراءة الملف...';
    });

    try {
      final outBytes = await convertHtmlInBackground(
        _file!,
        // محتوى عربي بحت سيُحتسَب تلقائياً rtl=true داخل المحلِّل
        // (hasArabic لكل عنصر)؛ rtl هنا قيمة افتراضية فقط عند تعذّر
        // تحديد الاتجاه من المحتوى نفسه (نص غير عربي وغير لاتيني صراحةً).
        options: const HtmlConversionOptions(rtl: true),
        cancelToken: _cancelToken,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _progress = p.progress;
            _stage = p.stage;
          });
        },
      );
      if (_cancelled || !mounted) return;

      setState(() {
        _progress = 0.97;
        _stage = 'حفظ الملف...';
      });

      final dir = await getTemporaryDirectory();
      final name = _fileName.replaceAll(
          RegExp(r'\.(html|htm)$', caseSensitive: false), '');
      final out = File('${dir.path}/$name.pdf');
      await out.writeAsBytes(outBytes);

      if (!mounted) return;
      HapticFeedback.heavyImpact();
      _backToPick();
      // ⚠️ تعميم: تنتقل الآن إلى ResultScreen الموحَّدة بدل شاشة نجاح
      // محلية مكرّرة.
      Navigator.push(context, MaterialPageRoute(builder: (_) => ResultScreen(
        file: out,
        title: 'تم تحويل الملف بنجاح!',
        subtitle: 'تم إنشاء PDF بجودة عالية من صفحة الويب الأصلية.',
        toolId: 'html_to_pdf',
        toolName: 'HTML إلى PDF',
        settings: {'الملف الأصلي': _fileName},
      )));
    } catch (e) {
      if (_cancelled) return;
      _backToPick();
      final msg = e.toString().replaceFirst('Exception: ', '');
      _err('خطأ في التحويل: $msg');
    }
  }

  void _cancelConversion() {
    HapticFeedback.lightImpact();
    _cancelled = true;
    _cancelToken?.cancel();
    _backToPick();
  }

  void _backToPick() {
    if (!mounted) return;
    setState(() => _phase = _ScreenPhase.pick);
  }

  void _err(String msg) => _toast(msg, Colors.red.shade700);

  void _toast(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.cairo(color: Colors.white)),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _Palette.bg,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0E1220), Color(0xFF1B1626), Color(0xFF0E1220)],
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
          ),
        ),
        child: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.04),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            child: switch (_phase) {
              _ScreenPhase.pick => _buildPickPhase(),
              _ScreenPhase.converting => _buildConvertingPhase(),
            },
          ),
        ),
      ),
    );
  }

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

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Row(
        textDirection: TextDirection.rtl,
        children: [
          _CircleIconButton(
            icon: Icons.arrow_forward_ios_rounded,
            onTap: () => Navigator.pop(context),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('HTML ← PDF',
                    textDirection: TextDirection.rtl,
                    style: GoogleFonts.cairo(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: _Palette.textPrimary)),
                Text('صفحات ويب تتحوّل إلى مستند مرتّب',
                    textDirection: TextDirection.rtl,
                    style: GoogleFonts.cairo(
                        fontSize: 12, color: _Palette.textSecondary)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _Palette.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border:
                  Border.all(color: _Palette.orange.withValues(alpha: 0.35)),
            ),
            child: Text('HTML',
                style: GoogleFonts.cairo(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: _Palette.orange)),
          ),
        ],
      ),
    );
  }

  Widget _buildToolBanner() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: [
            _Palette.orangeDark.withValues(alpha: 0.25),
            _Palette.bgCard,
          ],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        border: Border.all(color: _Palette.orange.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: _Palette.orange.withValues(alpha: 0.10),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        textDirection: TextDirection.rtl,
        children: [
          AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (context, _) {
              final glow =
                  0.25 + 0.15 * math.sin(_pulseCtrl.value * 2 * math.pi);
              return Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: const LinearGradient(
                      colors: [_Palette.orange, _Palette.orangeDark]),
                  boxShadow: [
                    BoxShadow(
                      color: _Palette.orange.withValues(alpha: glow),
                      blurRadius: 22,
                    ),
                  ],
                ),
                child: const Icon(Icons.code_rounded,
                    color: Colors.white, size: 30),
              );
            },
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('تحويل ذكي للمحتوى',
                    textDirection: TextDirection.rtl,
                    style: GoogleFonts.cairo(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: _Palette.orange)),
                const SizedBox(height: 2),
                Text(
                    'استخراج النص من صفحة HTML وتنسيقه في مستند PDF نظيف وسهل القراءة.',
                    textDirection: TextDirection.rtl,
                    style: GoogleFonts.cairo(
                        fontSize: 12, color: _Palette.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUploadZone() {
    final hasFile = _file != null;
    return GestureDetector(
      onTap: hasFile ? null : _pickFile,
      child: AnimatedBuilder(
        animation: _dashCtrl,
        builder: (context, child) => CustomPaint(
          painter: _DashedBorderPainter(
            color: hasFile
                ? _Palette.green.withValues(alpha: 0.6)
                : _Palette.orange.withValues(alpha: 0.45),
            phase: hasFile ? 0 : _dashCtrl.value,
            radius: 20,
          ),
          child: child,
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: _Palette.bgCard.withValues(alpha: 0.6),
          ),
          child: hasFile ? _buildSelectedFileCard() : _buildEmptyUpload(),
        ),
      ),
    );
  }

  Widget _buildEmptyUpload() {
    return Column(
      children: [
        const SizedBox(height: 6),
        Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _Palette.bgCardLight,
            border: Border.all(color: _Palette.orange.withValues(alpha: 0.3)),
          ),
          child: const Icon(Icons.upload_file_rounded,
              color: _Palette.orange, size: 28),
        ),
        const SizedBox(height: 12),
        Text('انقر لاختيار ملف',
            style: GoogleFonts.cairo(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: _Palette.textPrimary)),
        const SizedBox(height: 4),
        Text('HTML أو HTM',
            style: GoogleFonts.cairo(fontSize: 12, color: _Palette.textMuted)),
        const SizedBox(height: 6),
      ],
    );
  }

  Widget _buildSelectedFileCard() {
    return Column(
      children: [
        Row(
          textDirection: TextDirection.rtl,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: _Palette.orange.withValues(alpha: 0.15),
                border: Border.all(
                    color: _Palette.orange.withValues(alpha: 0.4)),
              ),
              child: Center(
                child: Text(_ext().toUpperCase(),
                    style: GoogleFonts.cairo(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        color: _Palette.orange)),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_fileName,
                      textDirection: TextDirection.rtl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: _Palette.textPrimary)),
                  Text(_formatSize(_fileSize),
                      style: GoogleFonts.cairo(
                          fontSize: 12, color: _Palette.textMuted)),
                ],
              ),
            ),
            _CircleIconButton(
              icon: Icons.close_rounded,
              color: Colors.red.shade300,
              size: 36,
              onTap: _clearFile,
            ),
          ],
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: _pickFile,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border:
                  Border.all(color: _Palette.orange.withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              textDirection: TextDirection.rtl,
              children: [
                const Icon(Icons.folder_open_rounded,
                    color: _Palette.orange, size: 18),
                const SizedBox(width: 8),
                Text('تغيير الملف',
                    style: GoogleFonts.cairo(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _Palette.orange)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPrivacyBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: _Palette.greenDark.withValues(alpha: 0.15),
        border: Border.all(color: _Palette.green.withValues(alpha: 0.35)),
      ),
      child: Row(
        textDirection: TextDirection.rtl,
        children: [
          const Icon(Icons.verified_user_rounded,
              color: _Palette.green, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'معالجة آمنة • لا يتم رفع أي محتوى إلى الإنترنت',
              textDirection: TextDirection.rtl,
              style: GoogleFonts.cairo(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: _Palette.green),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    final canConvert = _file != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
      decoration: BoxDecoration(
        color: _Palette.bgCard,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: GestureDetector(
        onTap: canConvert ? _startConversion : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: canConvert
                ? const LinearGradient(
                    colors: [_Palette.orange, _Palette.orangeDark])
                : null,
            color: canConvert ? null : _Palette.bgCardLight,
            boxShadow: canConvert
                ? [
                    BoxShadow(
                      color: _Palette.orange.withValues(alpha: 0.4),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    )
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            textDirection: TextDirection.rtl,
            children: [
              Icon(Icons.bolt_rounded,
                  color: canConvert ? Colors.white : _Palette.textMuted,
                  size: 22),
              const SizedBox(width: 8),
              Text(
                canConvert ? 'تحويل الملف' : 'اختر ملفاً أولاً',
                style: GoogleFonts.cairo(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: canConvert ? Colors.white : _Palette.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConvertingPhase() {
    return ConversionProgressWidget(
      progress: _progress,
      stage: _stage,
      accentColor: _Palette.orange,
      icon: Icons.data_object_rounded,
      title: 'جارِ تحويل صفحة HTML...',
      controller: _pulseCtrl,
      fileName: _fileName,
      onCancel: _cancelConversion,
    );
  }

}

// ─────────────────────────────────────────────────────────────────────────────
// الكلاسات المساعدة
// ─────────────────────────────────────────────────────────────────────────────

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;
  final double size;
  const _CircleIconButton(
      {required this.icon,
      required this.onTap,
      this.color,
      this.size = 42});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: _Palette.bgCardLight,
                border: Border.all(color: _Palette.divider)),
            child: Icon(icon,
                size: size * 0.42,
                color: color ?? _Palette.textSecondary)));
  }
}

class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double phase;
  final double radius;
  _DashedBorderPainter(
      {required this.color, required this.phase, required this.radius});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, Radius.circular(radius));
    final path = Path()..addRRect(rrect);
    const dash = 8.0;
    const gap = 6.0;
    final metrics = path.computeMetrics();
    for (final metric in metrics) {
      double dist = -phase * (dash + gap) * 4;
      while (dist < metric.length) {
        final start = dist.clamp(0.0, metric.length);
        final end = (dist + dash).clamp(0.0, metric.length);
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

