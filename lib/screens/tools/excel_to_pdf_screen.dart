// ═══════════════════════════════════════════════════════════════════════════
//  Excel ← PDF — شاشة تحويل XLSX / CSV إلى PDF
//  الإصلاحات:
//   ✓ إصلاح مشكلة "لم يتم العثور على البيانات في الأوراق المختارة"
//   ✓ عرض رسائل خطأ واضحة بدل التوقف الصامت
//   ✓ حل مشكلة AnimatedBuilder في pick phase (إضافة Scaffold مع background)
//   ✓ SnackBar يعمل من أي phase
//   ✓ تحسين UX: عداد الأوراق المختارة في زر التحويل
//   ✓ إصلاح منطق _backToPick (الرجوع للاختيار لا لـ pick)
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/xlsx_to_pdf_converter.dart';
import '../../services/isolate_support.dart';
import '../../widgets/pulsing_dots_indicator.dart';
import '../result_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  لوحة الألوان — أخضر زمردي على خلفية ليلية
// ─────────────────────────────────────────────────────────────────────────────

class _Palette {
  static const bg0         = Color(0xFF081209);
  static const bg1         = Color(0xFF0C1A14);
  static const bg2         = Color(0xFF0A1410);
  static const card        = Color(0xFF12211A);
  static const cardLight   = Color(0xFF182C22);
  static const green       = Color(0xFF22C55E);
  static const emerald     = Color(0xFF10B981);
  static const lime        = Color(0xFF84CC16);
  static const danger      = Color(0xFFF43F5E);
  static const textPrimary   = Color(0xFFEFFDF4);
  static const textSecondary = Color(0xFF9BE3B6);
  static const textMuted     = Color(0xFF5FB683);
  static const divider       = Color(0xFF1E3A29);
}

// ─────────────────────────────────────────────────────────────────────────────
//  الشاشة الرئيسية
// ─────────────────────────────────────────────────────────────────────────────

class ExcelToPdfScreen extends StatefulWidget {
  const ExcelToPdfScreen({super.key});
  @override
  State<ExcelToPdfScreen> createState() => _ExcelToPdfScreenState();
}

enum _Phase { pick, selectSheets, converting }

class _ExcelToPdfScreenState extends State<ExcelToPdfScreen>
    with TickerProviderStateMixin {
  File?   _file;
  String  _fileName = '';
  int     _fileSize = 0;

  List<SheetInfo> _availableSheets = [];
  Set<String>     _selectedSheets  = {};

  _Phase  _phase    = _Phase.pick;
  double  _progress = 0;
  String  _stage    = '';
  XlsxCancelToken? _cancelToken;

  int   _rowCount   = 0;
  int   _pageCount  = 0;

  // مؤثّرات الحركة
  late final AnimationController _ambientCtrl;
  late final AnimationController _pulseCtrl;
  late final AnimationController _dashCtrl;
  late final AnimationController _spinCtrl;

  @override
  void initState() {
    super.initState();
    _ambientCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 8))
      ..repeat();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1700))
      ..repeat();
    _dashCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 6))
      ..repeat();
    _spinCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1100))
      ..repeat();
  }

  @override
  void dispose() {
    _ambientCtrl.dispose();
    _pulseCtrl.dispose();
    _dashCtrl.dispose();
    _spinCtrl.dispose();
    super.dispose();
  }

  // ───────────────────────────────────────────────────────────────────────────
  //  منطق
  // ───────────────────────────────────────────────────────────────────────────

  String _formatSize(int b) {
    if (b >= 1048576) return '${(b / 1048576).toStringAsFixed(1)} MB';
    if (b >= 1024)    return '${(b / 1024).toStringAsFixed(0)} KB';
    return '$b B';
  }

  String _ext() =>
      _file == null ? '' : _file!.path.split('.').last.toLowerCase();

  Future<void> _pickFile() async {
    HapticFeedback.selectionClick();
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'xlsx', 'tsv'],
    );
    final picked = r?.files.first;
    if (picked?.path == null) return;

    HapticFeedback.lightImpact();
    setState(() {
      _file             = File(picked!.path!);
      _fileName         = picked.name;
      _fileSize         = picked.size;
      _availableSheets  = [];
      _selectedSheets   = {};
      _phase            = _Phase.pick; // ابقَ في pick حتى تنتهي من القراءة
    });

    await _loadSheetNames();
  }

  Future<void> _loadSheetNames() async {
    if (_file == null) return;

    // CSV/TSV → تحويل مباشر بدون اختيار أوراق
    final ext = _ext();
    if (ext == 'csv' || ext == 'tsv') {
      setState(() {
        _availableSheets = [const SheetInfo(name: 'Sheet1', displayName: 'Sheet1')];
        _selectedSheets  = {'Sheet1'};
        _phase           = _Phase.selectSheets;
      });
      return;
    }

    try {
      final sheets = await XlsxToPdfConverter.getSheetNames(_file!);
      if (!mounted) return;

      if (sheets.isEmpty) {
        _err('لم يتم العثور على أوراق عمل في الملف');
        return;
      }

      setState(() {
        _availableSheets = sheets;
        _selectedSheets  = sheets.map((s) => s.name).toSet();
        _phase           = _Phase.selectSheets;
      });
    } catch (e) {
      if (!mounted) return;
      _err(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _clearFile() {
    HapticFeedback.lightImpact();
    setState(() {
      _file            = null;
      _fileName        = '';
      _fileSize        = 0;
      _availableSheets = [];
      _selectedSheets  = {};
      _phase           = _Phase.pick;
    });
  }

  void _toggleSheet(String name) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedSheets.contains(name)) {
        _selectedSheets.remove(name);
      } else {
        _selectedSheets.add(name);
      }
    });
  }

  void _selectAllSheets() {
    HapticFeedback.lightImpact();
    setState(() => _selectedSheets = _availableSheets.map((s) => s.name).toSet());
  }

  void _deselectAllSheets() {
    HapticFeedback.lightImpact();
    setState(() => _selectedSheets.clear());
  }

  Future<void> _startConversion() async {
    if (_file == null || _selectedSheets.isEmpty) {
      _err('يرجى اختيار ملف وورقة عمل واحدة على الأقل');
      return;
    }

    final ext = _ext();
    if (ext == 'xls') {
      _err('صيغة .xls القديمة غير مدعومة — احفظ الملف كـ .xlsx أو .csv');
      return;
    }

    HapticFeedback.mediumImpact();
    _cancelToken = XlsxCancelToken();
    setState(() {
      _phase    = _Phase.converting;
      _progress = 0;
      _stage    = 'جارٍ التحليل...';
    });

    try {
      final result = await convertXlsxSheetsInBackground(
        _file!,
        selectedSheetNames: _selectedSheets.toList(),
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
        _goToSelectSheets();
        return;
      }

      setState(() {
        _progress = 0.98;
        _stage    = 'حفظ الملف...';
      });

      final dir  = await getTemporaryDirectory();
      final name = _fileName.replaceAll(
          RegExp(r'\.(csv|xlsx|xls|tsv)$', caseSensitive: false), '');
      final out  = File('${dir.path}/$name.pdf');
      await out.writeAsBytes(result.bytes);

      if (!mounted) return;
      HapticFeedback.heavyImpact();
      _rowCount    = result.rowCount;
      _pageCount   = result.pageCount;
      _goToSelectSheets();
      // ⚠️ تعميم: تنتقل الآن إلى ResultScreen الموحَّدة بدل شاشة نجاح
      // محلية مكرّرة.
      Navigator.push(context, MaterialPageRoute(builder: (_) => ResultScreen(
        file: out,
        title: 'تم تحويل الملف بنجاح!',
        subtitle: 'تم إنشاء PDF بجودة عالية من بيانات الجدول الأصلي.',
        toolId: 'excel_to_pdf',
        toolName: 'Excel إلى PDF',
        settings: {
          'الملف الأصلي': _fileName,
          if (_rowCount > 0) 'عدد الصفوف': '$_rowCount',
          if (_pageCount > 0) 'عدد الصفحات': '$_pageCount',
        },
      )));

    } on XlsxCancelledException {
      _goToSelectSheets();

    } catch (e) {
      if (!mounted) return;
      _goToSelectSheets();
      final msg = e.toString().replaceFirst('Exception: ', '');
      _err(msg.isEmpty ? 'تعذّر إكمال التحويل' : msg);
    }
  }

  void _cancelConversion() {
    HapticFeedback.lightImpact();
    _cancelToken?.cancel();
    _goToSelectSheets();
  }

  /// الرجوع إلى مرحلة اختيار الأوراق (إن وُجدت) وإلا إلى pick
  void _goToSelectSheets() {
    if (!mounted) return;
    setState(() => _phase =
        _availableSheets.isNotEmpty ? _Phase.selectSheets : _Phase.pick);
  }

  void _err(String msg) => _toast(msg, _Palette.danger);

  void _toast(String msg, Color bgColor) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg,
            style: GoogleFonts.cairo(color: Colors.white, fontSize: 14)),
        backgroundColor: bgColor,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  //  Build
  // ───────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _Palette.bg0,
      body: AnimatedBuilder(
        animation: _ambientCtrl,
        builder: (context, child) {
          return CustomPaint(
            painter: _AmbientGlowPainter(t: _ambientCtrl.value),
            child: child,
          );
        },
        child: _buildPhase(),
      ),
    );
  }

  Widget _buildPhase() {
    switch (_phase) {
      case _Phase.pick:
        return _buildPickPhase();
      case _Phase.selectSheets:
        return _buildSelectSheetsPhase();
      case _Phase.converting:
        return _buildConvertingPhase();
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  //  مرحلة 1: اختيار الملف
  // ───────────────────────────────────────────────────────────────────────────

  Widget _buildPickPhase() {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Excel to PDF',
                style: GoogleFonts.cairo(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  color: _Palette.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'تحويل أوراق العمل إلى ملف PDF احترافي',
                style: GoogleFonts.cairo(
                    fontSize: 13, color: _Palette.textSecondary),
                textDirection: TextDirection.rtl,
              ),
              const SizedBox(height: 48),

              // منطقة الرفع
              GestureDetector(
                onTap: _pickFile,
                child: AnimatedBuilder(
                  animation: _dashCtrl,
                  builder: (context, _) {
                    return Container(
                      width: double.infinity,
                      height: 220,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        color: _Palette.cardLight.withValues(alpha: 0.4),
                      ),
                      child: CustomPaint(
                        painter: _DashedBorderPainter(
                          color: _Palette.green,
                          phase: _dashCtrl.value,
                          radius: 24,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            AnimatedBuilder(
                              animation: _pulseCtrl,
                              builder: (_, __) => PulsingDotsIndicator(
                                  controller: _pulseCtrl,
                                  color: _Palette.green),
                            ),
                            const SizedBox(height: 16),
                            Icon(Icons.cloud_upload_outlined,
                                size: 48,
                                color: _Palette.green.withValues(alpha: 0.85)),
                            const SizedBox(height: 14),
                            Text(
                              'اضغط لاختيار الملف',
                              style: GoogleFonts.cairo(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: _Palette.textPrimary),
                              textDirection: TextDirection.rtl,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'XLSX, CSV, TSV',
                              style: GoogleFonts.cairo(
                                  fontSize: 12, color: _Palette.textMuted),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  //  مرحلة 2: اختيار الأوراق
  // ───────────────────────────────────────────────────────────────────────────

  Widget _buildSelectSheetsPhase() {
    final selectedCount = _selectedSheets.length;
    final totalCount    = _availableSheets.length;

    return SafeArea(
      child: Column(
        children: [
          // الهيدر
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                // زر الإلغاء / العودة
                GestureDetector(
                  onTap: _clearFile,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _Palette.danger.withValues(alpha: 0.15),
                      border: Border.all(
                          color: _Palette.danger.withValues(alpha: 0.4)),
                    ),
                    child:
                        const Icon(Icons.close, color: _Palette.danger, size: 20),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _fileName,
                        overflow: TextOverflow.ellipsis,
                        textDirection: TextDirection.rtl,
                        style: GoogleFonts.cairo(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: _Palette.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_formatSize(_fileSize)}  •  $totalCount ${totalCount == 1 ? 'ورقة' : 'أوراق'}',
                        textDirection: TextDirection.rtl,
                        style: GoogleFonts.cairo(
                            fontSize: 11, color: _Palette.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // أزرار الاختيار السريع
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _QuickActionButton(
                  label: 'إلغاء الكل',
                  onTap: _deselectAllSheets,
                  bgColor: _Palette.danger.withValues(alpha: 0.12),
                  fgColor: _Palette.danger,
                ),
                const SizedBox(width: 8),
                _QuickActionButton(
                  label: 'تحديد الكل',
                  onTap: _selectAllSheets,
                  bgColor: _Palette.green.withValues(alpha: 0.12),
                  fgColor: _Palette.green,
                ),
              ],
            ),
          ),

          // قائمة الأوراق
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    'اختر أوراق العمل المطلوبة:',
                    textDirection: TextDirection.rtl,
                    style: GoogleFonts.cairo(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _Palette.textSecondary),
                  ),
                ),
                ..._availableSheets.map((sheet) {
                  final isSelected = _selectedSheets.contains(sheet.name);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _SheetCheckboxTile(
                      sheet: sheet,
                      isSelected: isSelected,
                      onTap: () => _toggleSheet(sheet.name),
                    ),
                  );
                }),
              ],
            ),
          ),

          // زر التحويل
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: selectedCount == 0 ? null : _startConversion,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _Palette.green,
                  disabledBackgroundColor:
                      _Palette.green.withValues(alpha: 0.35),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 0,
                ),
                child: Text(
                  selectedCount == 0
                      ? 'اختر ورقة على الأقل'
                      : 'تحويل إلى PDF ($selectedCount/$totalCount)',
                  style: GoogleFonts.cairo(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  //  مرحلة 3: التحويل
  // ───────────────────────────────────────────────────────────────────────────

  Widget _buildConvertingPhase() {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // حلقة التحميل
              AnimatedBuilder(
                animation: Listenable.merge([_spinCtrl, _pulseCtrl]),
                builder: (_, __) {
                  return SizedBox(
                    width: 160,
                    height: 160,
                    child: CustomPaint(
                      painter: _SpinnerRingPainter(
                        progress: _progress,
                        spin:     _spinCtrl.value,
                        pulse:    _pulseCtrl.value,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 32),

              // نسبة التقدم
              Text(
                '${(_progress * 100).toInt()}%',
                style: GoogleFonts.cairo(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    color: _Palette.green),
              ),
              const SizedBox(height: 8),
              Text(
                _stage,
                textDirection: TextDirection.rtl,
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _Palette.textSecondary),
              ),
              const SizedBox(height: 20),

              // شريط التقدم
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 6,
                  backgroundColor: _Palette.cardLight,
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(_Palette.green),
                ),
              ),
              const SizedBox(height: 32),

              // زر الإلغاء
              TextButton.icon(
                onPressed: _cancelConversion,
                icon: const Icon(Icons.cancel_outlined,
                    size: 18, color: _Palette.danger),
                label: Text(
                  'إلغاء',
                  style: GoogleFonts.cairo(
                      fontWeight: FontWeight.w700, color: _Palette.danger),
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

class _SheetCheckboxTile extends StatelessWidget {
  final SheetInfo sheet;
  final bool isSelected;
  final VoidCallback onTap;

  const _SheetCheckboxTile({
    required this.sheet,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: isSelected
              ? _Palette.green.withValues(alpha: 0.08)
              : _Palette.card,
          border: Border.all(
            color: isSelected
                ? _Palette.green.withValues(alpha: 0.6)
                : _Palette.divider,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected ? _Palette.green : Colors.transparent,
                border: Border.all(
                  color:
                      isSelected ? _Palette.green : _Palette.textMuted,
                  width: 2,
                ),
              ),
              child: isSelected
                  ? const Icon(Icons.check, size: 13, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                sheet.displayName,
                textDirection: TextDirection.rtl,
                style: GoogleFonts.cairo(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isSelected
                      ? _Palette.textPrimary
                      : _Palette.textSecondary,
                ),
              ),
            ),
            if (isSelected)
              const Icon(Icons.check_circle,
                  size: 16, color: _Palette.green),
          ],
        ),
      ),
    );
  }
}

class _QuickActionButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Color bgColor;
  final Color fgColor;

  const _QuickActionButton({
    required this.label,
    required this.onTap,
    required this.bgColor,
    required this.fgColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: bgColor,
          border: Border.all(color: fgColor.withValues(alpha: 0.4)),
        ),
        child: Text(
          label,
          textDirection: TextDirection.rtl,
          style: GoogleFonts.cairo(
              fontSize: 11, fontWeight: FontWeight.w700, color: fgColor),
        ),
      ),
    );
  }
}



// ─────────────────────────────────────────────────────────────────────────────
//  الرسّامون (CustomPainter)
// ─────────────────────────────────────────────────────────────────────────────

class _AmbientGlowPainter extends CustomPainter {
  final double t;
  const _AmbientGlowPainter({required this.t});

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()
      ..shader = const LinearGradient(
        colors: [_Palette.bg0, _Palette.bg1, _Palette.bg2],
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, bgPaint);

    final a = t * 2 * math.pi;
    _blob(
      canvas,
      Offset(size.width * (0.25 + 0.12 * math.sin(a)),
          size.height * (0.22 + 0.06 * math.cos(a))),
      size.width * 0.55,
      _Palette.green.withValues(alpha: 0.09),
    );
    _blob(
      canvas,
      Offset(size.width * (0.8 + 0.08 * math.cos(a * 0.8)),
          size.height * (0.78 + 0.05 * math.sin(a * 1.2))),
      size.width * 0.5,
      _Palette.emerald.withValues(alpha: 0.07),
    );
  }

  void _blob(Canvas canvas, Offset c, double r, Color color) {
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
                colors: [color, color.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: c, radius: r))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 50),
    );
  }

  @override
  bool shouldRepaint(covariant _AmbientGlowPainter old) => old.t != t;
}

class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double phase;
  final double radius;
  const _DashedBorderPainter(
      {required this.color, required this.phase, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Offset.zero & size, Radius.circular(radius)));
    const dash = 9.0;
    const gap  = 6.0;
    for (final metric in path.computeMetrics()) {
      double dist = -phase * (dash + gap) * 4;
      while (dist < metric.length) {
        final start = dist.clamp(0.0, metric.length);
        final end   = (dist + dash).clamp(0.0, metric.length);
        if (end > start) canvas.drawPath(metric.extractPath(start, end), paint);
        dist += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) =>
      old.phase != phase || old.color != color;
}

class _SpinnerRingPainter extends CustomPainter {
  final double progress;
  final double spin;
  final double pulse;
  const _SpinnerRingPainter(
      {required this.progress, required this.spin, required this.pulse});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 10;

    // حلقة الخلفية
    canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = _Palette.cardLight
          ..style = PaintingStyle.stroke
          ..strokeWidth = 9);

    // حلقة التقدم
    final glow = 0.5 + 0.3 * math.sin(pulse * 2 * math.pi);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.02, 1.0),
      false,
      Paint()
        ..shader = const SweepGradient(
          colors: [_Palette.emerald, _Palette.green, _Palette.lime],
          startAngle: -math.pi / 2,
          endAngle: 3 * math.pi / 2,
        ).createShader(Rect.fromCircle(center: center, radius: radius))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round
        ..maskFilter = MaskFilter.blur(BlurStyle.solid, 1.5 + glow * 2),
    );

    // حلقة الدوران
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius + 8),
      spin * 2 * math.pi,
      math.pi * 0.45,
      false,
      Paint()
        ..color = _Palette.lime.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SpinnerRingPainter old) =>
      old.progress != progress || old.spin != spin || old.pulse != pulse;
}
