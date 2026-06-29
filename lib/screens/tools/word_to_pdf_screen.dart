// ═══════════════════════════════════════════════════════════════════════════
//  Word إلى PDF — شاشة بتصميم خاص مستقل
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf_master/services/isolate_support.dart';

import '../../services/docx_to_pdf_converter.dart';
import '../../theme/app_theme.dart';
import '../../widgets/conversion_progress_widget.dart';
import '../result_screen.dart';

class _Palette {
  static const bg = Color(0xFF0E1220);
  static const bgCard = Color(0xFF181E32);
  static const bgCardLight = Color(0xFF222A45);
  static const red = Color(0xFFE53E3E);
  static const redDark = Color(0xFFB91C1C);
  static const green = Color(0xFF2BC48A);
  static const greenDark = Color(0xFF15803D);
  static const textPrimary = Color(0xFFF3F5FB);
  static const textSecondary = Color(0xFF9AA3BC);
  static const textMuted = Color(0xFF6B7490);
  static const divider = Color(0xFF2B3354);
}

class WordToPdfScreen extends StatefulWidget {
  const WordToPdfScreen({super.key});
  @override
  State<WordToPdfScreen> createState() => _WordToPdfScreenState();
}

enum _ScreenPhase { pick, converting }

class _WordToPdfScreenState extends State<WordToPdfScreen>
    with TickerProviderStateMixin {
  File? _file;
  String _fileName = '';
  int _fileSize = 0;

  _ScreenPhase _phase = _ScreenPhase.pick;

  double _progress = 0;
  String _stage = '';
  DocxCancelToken? _cancelToken;

  late final AnimationController _pulseCtrl;
  late final AnimationController _dashCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat();
    _dashCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 6))
      ..repeat();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _dashCtrl.dispose();
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
      allowedExtensions: ['docx', 'rtf', 'odt'],
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

  Future<void> _startConversion() async {
    if (_file == null) return;
    final ext = _ext();
    if (ext == 'doc') {
      _err('صيغة .doc القديمة غير مدعومة — احفظ الملف بصيغة .docx ثم أعد المحاولة');
      return;
    }

    HapticFeedback.mediumImpact();
    _cancelToken = DocxCancelToken();
    setState(() {
      _phase = _ScreenPhase.converting;
      _progress = 0;
      _stage = 'بدء التحويل...';
    });

    try {
      final Uint8List outBytes = await convertDocxInBackground(
        _file!,
        cancelToken: _cancelToken,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _progress = p.progress;
            _stage = p.stage;
          });
        },
      );

      if (_cancelToken?.isCancelled == true) {
        _backToPick();
        return;
      }

      setState(() {
        _progress = 0.97;
        _stage = 'حفظ الملف...';
      });

      final dir = await getTemporaryDirectory();
      final name = _fileName.replaceAll(
          RegExp(r'\.(docx|rtf|odt)$', caseSensitive: false), '');
      final out = File('${dir.path}/$name.pdf');
      await out.writeAsBytes(outBytes);

      if (!mounted) return;
      HapticFeedback.heavyImpact();
      _backToPick();
      // ⚠️ تعميم: تنتقل الآن إلى ResultScreen الموحَّدة بدل شاشة نجاح
      // محلية مكرّرة كانت تستخدم منطق حفظ مختلفاً عن باقي أدوات التطبيق.
      Navigator.push(context, MaterialPageRoute(builder: (_) => ResultScreen(
        file: out,
        title: 'تم تحويل الملف بنجاح!',
        subtitle: 'تم إنشاء PDF بجودة عالية من مستند Word الأصلي.',
        toolId: 'word_to_pdf',
        toolName: 'Word إلى PDF',
        settings: {'الملف الأصلي': _fileName},
      )));
    } on DocxCancelledException {
      _backToPick();
    } on DocxConversionException catch (e) {
      // ── إصلاح: DocxConversionException.toString() يُرجع النص المجرّد
      // بدون اسم الكلاس، فالشرط القديم msg.contains('DocxConversionException')
      // كان يفشل دائماً ويُضيف بادئة "خطأ غير متوقع:" الزائدة.
      // الآن نُميّز النوع مباشرة بـ on DocxConversionException.
      _backToPick();
      _err(e.message);
    } catch (e, st) {
      // أي استثناء غير متوقع (StateError من RootIsolateToken، أو غيره)
      // نطبعه كاملاً في الـ console للتشخيص، ونعرض رسالة واضحة للمستخدم.
      debugPrint('DocxConvert unexpected error [${e.runtimeType}]: $e');
      debugPrint('StackTrace: $st');
      _backToPick();
      final msg = e.toString().replaceFirst('Exception: ', '');
      _err('خطأ غير متوقع: $msg');
    }
  }

  void _cancelConversion() {
    HapticFeedback.lightImpact();
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
            colors: [Color(0xFF0E1220), Color(0xFF131A2E), Color(0xFF0E1220)],
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
                Text('Word ← PDF',
                    textDirection: TextDirection.rtl,
                    style: GoogleFonts.cairo(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: _Palette.textPrimary)),
                Text('نصوص واضحة وحجم صغير',
                    textDirection: TextDirection.rtl,
                    style: GoogleFonts.cairo(
                        fontSize: 12, color: _Palette.textSecondary)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _Palette.red.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _Palette.red.withValues(alpha: 0.35)),
            ),
            child: Text('DOCX',
                style: GoogleFonts.cairo(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: _Palette.red)),
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
            _Palette.redDark.withValues(alpha: 0.25),
            _Palette.bgCard,
          ],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        border: Border.all(color: _Palette.red.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: _Palette.red.withValues(alpha: 0.10),
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
                      colors: [_Palette.red, _Palette.redDark]),
                  boxShadow: [
                    BoxShadow(
                      color: _Palette.red.withValues(alpha: glow),
                      blurRadius: 22,
                    ),
                  ],
                ),
                child: const Icon(Icons.picture_as_pdf_rounded,
                    color: Colors.white, size: 30),
              );
            },
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('تحويل قياسي متوافق',
                    textDirection: TextDirection.rtl,
                    style: GoogleFonts.cairo(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: _Palette.red)),
                const SizedBox(height: 2),
                Text(
                    'تصدير الملف كنصوص أصلية قابلة للنسخ والبحث مع الحفاظ على التنسيق وفواصل الصفحات.',
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
                : _Palette.red.withValues(alpha: 0.45),
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
            border: Border.all(color: _Palette.red.withValues(alpha: 0.3)),
          ),
          child: const Icon(Icons.upload_file_rounded,
              color: _Palette.red, size: 28),
        ),
        const SizedBox(height: 12),
        Text('انقر لاختيار ملف',
            style: GoogleFonts.cairo(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: _Palette.textPrimary)),
        const SizedBox(height: 4),
        Text('DOCX أو RTF أو ODT',
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
                color: _Palette.red.withValues(alpha: 0.15),
                border: Border.all(color: _Palette.red.withValues(alpha: 0.4)),
              ),
              child: Center(
                child: Text(_ext().toUpperCase(),
                    style: GoogleFonts.cairo(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        color: _Palette.red)),
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
              border: Border.all(color: _Palette.red.withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              textDirection: TextDirection.rtl,
              children: [
                const Icon(Icons.folder_open_rounded,
                    color: _Palette.red, size: 18),
                const SizedBox(width: 8),
                Text('تغيير الملف',
                    style: GoogleFonts.cairo(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _Palette.red)),
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
              'عملية آمنة • الملفات تُعالج محلياً على جهازك',
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
                    colors: [_Palette.red, _Palette.redDark])
                : null,
            color: canConvert ? null : _Palette.bgCardLight,
            boxShadow: canConvert
                ? [
                    BoxShadow(
                      color: _Palette.red.withValues(alpha: 0.4),
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
      accentColor: _Palette.red,
      icon: Icons.autorenew_rounded,
      title: 'جارِ المعالجة والتحويل...',
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

class ConversionScaffold extends StatelessWidget {
  final bool isDark;
  final String title;
  final IconData icon;
  final Color accent, accentDark;
  final String extensions;
  final File? file;
  final int? fileSize;
  final bool isProcessing;
  final VoidCallback onPickFile, onConvert, onClearFile;
  final String buttonLabel;
  final String Function(int) formatSize;
  final Widget settingsWidget;
  const ConversionScaffold(
      {super.key,
      required this.isDark,
      required this.title,
      required this.icon,
      required this.accent,
      required this.accentDark,
      required this.extensions,
      required this.file,
      required this.isProcessing,
      required this.onPickFile,
      required this.onConvert,
      required this.onClearFile,
      required this.buttonLabel,
      required this.formatSize,
      required this.settingsWidget,
      this.fileSize});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
        backgroundColor:
            isDark ? AppTheme.bgDark : const Color(0xFFF5F5FF),
        body: Container(
            decoration: BoxDecoration(
                gradient: isDark
                    ? AppTheme.bgGradient
                    : const LinearGradient(
                        colors: [Color(0xFFF5F5FF), Color(0xFFEEEEFF)],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter)),
            child: SafeArea(
                child: Column(children: [
              Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Row(children: [
                    GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: isDark
                                    ? AppTheme.bgCardLight
                                    : Colors.white,
                                border:
                                    Border.all(color: AppTheme.divider)),
                            child: const Icon(
                                Icons.arrow_back_ios_new_rounded,
                                size: 18,
                                color: AppTheme.textSecondary))),
                    const SizedBox(width: 14),
                    Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            gradient: LinearGradient(
                                colors: [accentDark, accent])),
                        child:
                            Icon(icon, color: Colors.white, size: 18)),
                    const SizedBox(width: 10),
                    Text(title,
                        style: GoogleFonts.cairo(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: isDark
                                ? AppTheme.textPrimary
                                : const Color(0xFF1A1A2E)))
                  ])),
              Expanded(
                  child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.all(20),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                                onTap: onPickFile,
                                child: AnimatedContainer(
                                    duration:
                                        const Duration(milliseconds: 300),
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(20),
                                    decoration: BoxDecoration(
                                        borderRadius:
                                            BorderRadius.circular(20),
                                        color: isDark
                                            ? AppTheme.bgCardLight
                                            : Colors.white,
                                        border: Border.all(
                                            color: file != null
                                                ? accent.withValues(
                                                    alpha: 0.6)
                                                : AppTheme.divider,
                                            width:
                                                file != null ? 2 : 1)),
                                    child: file == null
                                        ? Column(children: [
                                            Container(
                                                width: 56,
                                                height: 56,
                                                decoration: BoxDecoration(
                                                    shape: BoxShape.circle,
                                                    gradient: LinearGradient(
                                                        colors: [
                                                          accentDark,
                                                          accent
                                                        ])),
                                                child: Icon(icon,
                                                    color: Colors.white,
                                                    size: 28)),
                                            const SizedBox(height: 12),
                                            Text('اضغط لاختيار الملف',
                                                style: GoogleFonts.cairo(
                                                    fontSize: 15,
                                                    fontWeight:
                                                        FontWeight.w700,
                                                    color: isDark
                                                        ? AppTheme
                                                            .textPrimary
                                                        : const Color(
                                                            0xFF1A1A2E))),
                                            const SizedBox(height: 4),
                                            Text(extensions,
                                                style: GoogleFonts.cairo(
                                                    fontSize: 12,
                                                    color:
                                                        AppTheme.textMuted))
                                          ])
                                        : Row(children: [
                                            Icon(icon,
                                                color: accent, size: 32),
                                            const SizedBox(width: 12),
                                            Expanded(
                                                child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                  Text(
                                                      file!.path
                                                          .split(RegExp(
                                                              r'[/\\]'))
                                                          .last,
                                                      style: GoogleFonts
                                                          .cairo(
                                                              fontSize: 14,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700,
                                                              color: isDark
                                                                  ? AppTheme
                                                                      .textPrimary
                                                                  : const Color(
                                                                      0xFF1A1A2E)),
                                                      maxLines: 1,
                                                      overflow: TextOverflow
                                                          .ellipsis),
                                                  Text(
                                                      formatSize(fileSize ??
                                                          file!
                                                              .lengthSync()),
                                                      style: GoogleFonts
                                                          .cairo(
                                                              fontSize: 12,
                                                              color: AppTheme
                                                                  .textMuted))
                                                ])),
                                            GestureDetector(
                                                onTap: onClearFile,
                                                child: const Icon(
                                                    Icons.close_rounded,
                                                    color: AppTheme
                                                        .textMuted))
                                          ]))),
                            const SizedBox(height: 20),
                            settingsWidget,
                            const SizedBox(height: 24),
                            SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                    onPressed: (file == null ||
                                            isProcessing)
                                        ? null
                                        : onConvert,
                                    style: ElevatedButton.styleFrom(
                                        backgroundColor: accentDark,
                                        disabledBackgroundColor:
                                            AppTheme.bgCardLight,
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 16),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(16))),
                                    child: isProcessing
                                        ? Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                                const SizedBox(
                                                    width: 20,
                                                    height: 20,
                                                    child:
                                                        CircularProgressIndicator(
                                                            color:
                                                                Colors.white,
                                                            strokeWidth: 2)),
                                                const SizedBox(width: 12),
                                                Text('جارٍ التحويل...',
                                                    style: GoogleFonts.cairo(
                                                        color: Colors.white,
                                                        fontWeight:
                                                            FontWeight.w700))
                                              ])
                                        : Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                                const Icon(
                                                    Icons
                                                        .picture_as_pdf_rounded,
                                                    color: Colors.white),
                                                const SizedBox(width: 10),
                                                Text(buttonLabel,
                                                    style: GoogleFonts.cairo(
                                                        color: Colors.white,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        fontSize: 16))
                                              ]))),
                            const SizedBox(height: 20)
                          ])))
            ]))));
  }
}

class ChipRow extends StatelessWidget {
  final List<String> options;
  final String selected;
  final void Function(String) onTap;
  final Color accent;
  final bool isDark;
  final String suffix;
  const ChipRow(
      {super.key,
      required this.options,
      required this.selected,
      required this.onTap,
      required this.accent,
      required this.isDark,
      this.suffix = ''});
  @override
  Widget build(BuildContext context) {
    return Wrap(
        spacing: 8,
        children: options.map((v) {
          final sel = selected == v;
          return GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                onTap(v);
              },
              child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: sel
                          ? accent.withValues(alpha: 0.15)
                          : isDark
                              ? AppTheme.bgCardLight
                              : Colors.white,
                      border: Border.all(
                          color: sel
                              ? accent
                              : AppTheme.divider
                                  .withValues(alpha: 0.5))),
                  child: Text('$v$suffix',
                      style: GoogleFonts.cairo(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: sel
                              ? accent
                              : AppTheme.textSecondary))));
        }).toList());
  }
}

class SwitchRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final IconData icon;
  final Color color;
  final bool isDark;
  const SwitchRow(
      {super.key,
      required this.label,
      required this.value,
      required this.onChanged,
      required this.icon,
      required this.color,
      required this.isDark});
  @override
  Widget build(BuildContext context) {
    return Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: isDark ? AppTheme.bgCardLight : Colors.white,
            border: Border.all(
                color: value
                    ? color.withValues(alpha: 0.3)
                    : AppTheme.divider.withValues(alpha: 0.4))),
        child: Row(children: [
          Icon(icon,
              color: value ? color : AppTheme.textMuted, size: 20),
          const SizedBox(width: 12),
          Expanded(
              child: Text(label,
                  style: GoogleFonts.cairo(
                      fontSize: 13,
                      color: isDark
                          ? AppTheme.textPrimary
                          : const Color(0xFF1A1A2E)))),
          Switch.adaptive(
              value: value, onChanged: onChanged, activeTrackColor: color)
        ]));
  }
}
