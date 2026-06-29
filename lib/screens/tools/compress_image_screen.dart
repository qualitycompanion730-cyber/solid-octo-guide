import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../services/file_save_service.dart';
import '../../services/history_service.dart';
import '../../theme/app_theme.dart';

/// عنصر صورة واحدة في قائمة الضغط — يحتفظ بالملف الأصلي ونتيجة الضغط
/// (إن وُجدت) بشكل مستقل لكل صورة، حتى يمكن عرض مقارنة قبل/بعد لكل واحدة.
class _CompressItem {
  final String id;
  final File original;
  final int originalSize;
  File? compressed;
  int? compressedSize;
  bool isProcessing;

  _CompressItem({
    required this.id,
    required this.original,
    required this.originalSize,
  })  : compressed = null,
        compressedSize = null,
        isProcessing = false;

  bool get isDone => compressed != null;
  double? get savingsPercent {
    if (compressedSize == null || originalSize == 0) return null;
    return (1 - (compressedSize! / originalSize)) * 100;
  }
}

class CompressImageScreen extends StatefulWidget {
  const CompressImageScreen({super.key});
  @override
  State<CompressImageScreen> createState() => _CompressImageScreenState();
}

class _CompressImageScreenState extends State<CompressImageScreen> {
  final List<_CompressItem> _items = [];
  bool _isProcessingAll = false;

  // إعدادات الضغط
  String _qualityPreset = 'medium'; // low | medium | high | custom
  double _customQuality = 70;
  bool _resizeEnabled = false;
  double _maxDimension = 1920;
  String _format = 'jpeg'; // jpeg | png | webp

  static const _accentColor = Color(0xFF38B2AC);
  static const _accentDark = Color(0xFF234E52);

  int get _qualityValue {
    switch (_qualityPreset) {
      case 'low':
        return 40;
      case 'high':
        return 90;
      case 'custom':
        return _customQuality.round();
      default: // medium
        return 70;
    }
  }

  CompressFormat get _compressFormat {
    switch (_format) {
      case 'png':
        return CompressFormat.png;
      case 'webp':
        return CompressFormat.webp;
      default:
        return CompressFormat.jpeg;
    }
  }

  String get _extension {
    switch (_format) {
      case 'png':
        return 'png';
      case 'webp':
        return 'webp';
      default:
        return 'jpg';
    }
  }

  String _formatSize(int b) {
    if (b > 1048576) return '${(b / 1048576).toStringAsFixed(2)} MB';
    return '${(b / 1024).toStringAsFixed(0)} KB';
  }

  Future<void> _pickImages() async {
    try {
      final picker = ImagePicker();
      final List<XFile> picked = await picker.pickMultiImage(imageQuality: 100);
      if (picked.isEmpty) return;

      // ⚠️ إصلاح كفاءة حقيقي: lengthSync() هو استدعاء نظام ملفات حاجز
      // (blocking I/O)، وكان يُستدعى داخل دالة setState المتزامنة نفسها —
      // أي يُنفَّذ على خيط الواجهة مباشرة أثناء طور البناء (build) لكل
      // صورة مُختارة. لاختيار عدة صور كبيرة دفعة واحدة هذا قد يُسبِّب
      // تجميداً مرئياً قصيراً (jank) في الواجهة. الإصلاح: نقرأ حجم كل ملف
      // بشكل غير متزامن (Future.wait للتوازي الآمن — قراءة حجم ملف عملية
      // خفيفة جداً لا خطر منها على الذاكرة أو استقرار قناة التطبيق
      // الأصلية، بخلاف عمليات الضغط/التحويل الثقيلة) قبل استدعاء setState
      // مرة واحدة فقط بكل العناصر الجاهزة.
      final candidates = picked.map((x) => File(x.path)).where((f) => f.existsSync()).toList();
      if (candidates.isEmpty) return;
      final sizes = await Future.wait(candidates.map((f) => f.length()));

      if (!mounted) return;
      setState(() {
        for (var i = 0; i < candidates.length; i++) {
          _items.add(_CompressItem(
            id: '${DateTime.now().microsecondsSinceEpoch}_${_items.length}_$i',
            original: candidates[i],
            originalSize: sizes[i],
          ));
        }
      });
    } catch (e) {
      _err('فشل اختيار الصور: $e');
    }
  }

  void _removeItem(String id) {
    setState(() => _items.removeWhere((e) => e.id == id));
  }

  /// يضغط صورة واحدة فعلياً عبر flutter_image_compress، ويعيد الملف الناتج.
  /// ⚠️ ملاحظة مهمة حول minWidth/minHeight: القيمتان الافتراضيتان لمكتبة
  /// flutter_image_compress هما 1920×1080 — أي أن أي صورة أكبر تُصغَّر
  /// تلقائياً لهذا الحد حتى لو كان المستخدم يريد ضغطاً بالجودة فقط بلا أي
  /// تغيير لأبعاد الصورة. لتفادي هذا السلوك غير المتوقَّع، نُمرِّر أبعاد
  /// الصورة الأصلية نفسها كحد أدنى عندما يكون تغيير الحجم غير مُفعَّلاً،
  /// فلا تُصغَّر الصورة إطلاقاً (المكتبة لا "تُكبِّر" الصور أبداً، فتمرير
  /// أبعاد أكبر من اللازم كحد أدنى آمن تماماً ولا يُغيِّر شيئاً عملياً).
  Future<File?> _compressOne(_CompressItem item) async {
    try {
      final int minW;
      final int minH;
      if (_resizeEnabled) {
        minW = _maxDimension.round();
        minH = _maxDimension.round();
      } else {
        // أبعاد كبيرة بما يكفي لضمان عدم تصغير أي صورة عملياً (لا توجد
        // صور بهذا الحجم في الاستخدام الفعلي، وحتى لو وُجدت فهذا يعني
        // فقط أنها لن تُصغَّر، لا أن شيئاً سيفشل).
        minW = 20000;
        minH = 20000;
      }

      final bytes = await FlutterImageCompress.compressWithFile(
        item.original.absolute.path,
        minWidth: minW,
        minHeight: minH,
        quality: _qualityValue,
        format: _compressFormat,
        keepExif: false,
      );
      if (bytes == null) return null;

      final dir = await getTemporaryDirectory();
      final name = item.original.path.split('/').last.split('.').first;
      final out = File('${dir.path}/${name}_compressed_${DateTime.now().microsecondsSinceEpoch}.$_extension');
      await out.writeAsBytes(bytes);
      return out;
    } catch (e) {
      _err('فشل ضغط ${item.original.path.split('/').last}: $e');
      return null;
    }
  }

  Future<void> _compressAll() async {
    if (_items.isEmpty) {
      _err('أضف صوراً أولاً');
      return;
    }
    setState(() => _isProcessingAll = true);
    try {
      for (final item in _items) {
        if (!mounted) return;
        setState(() => item.isProcessing = true);
        final result = await _compressOne(item);
        if (!mounted) return;
        setState(() {
          item.isProcessing = false;
          if (result != null) {
            item.compressed = result;
            item.compressedSize = result.lengthSync();
          }
        });
      }
      if (!mounted) return;
      final doneCount = _items.where((e) => e.isDone).length;
      if (doneCount == 0) {
        _err('تعذّر ضغط أي صورة');
      } else {
        HapticFeedback.mediumImpact();
        // تسجيل في السجل — لكل صورة نُضيف سجلاً مستقلاً، اتساقاً مع
        // باقي أدوات التطبيق التي تُسجِّل كل ملف ناتج بشكل مستقل.
        for (final item in _items.where((e) => e.isDone)) {
          await HistoryService.add(HistoryItem(
            id: '${item.id}_history',
            toolId: 'compress_image',
            toolName: 'ضغط الصور',
            toolIcon: '0xe3ae',
            fileName: item.compressed!.path.split('/').last,
            filePath: item.compressed!.path,
            fileSizeBytes: item.compressedSize ?? 0,
            createdAt: DateTime.now(),
            settings: {
              'الجودة': '$_qualityValue%',
              'الصيغة': _format.toUpperCase(),
              if (_resizeEnabled) 'الحد الأقصى': '${_maxDimension.round()}px',
            },
          ));
        }
      }
    } finally {
      if (mounted) setState(() => _isProcessingAll = false);
    }
  }

  // ⚠️ إصلاح خلل حقيقي: كان الحفظ هنا يكتب مباشرة وفقط داخل صندوق
  // التطبيق الداخلي (getApplicationDocumentsDirectory) بلا أي خيار
  // لاختيار وجهة أخرى (تنزيلات/مستندات/تخزين خارجي) — على عكس ResultScreen
  // المستخدَمة في أدوات PDF التي توفّر هذه الخيارات الأربعة فعلياً. الآن
  // تستخدم نفس الآلية الموحَّدة (FileSaveService) بحيث تتطابق تجربة
  // الحفظ بين كل أدوات التطبيق دون تمييز.
  Future<void> _saveOne(_CompressItem item) async {
    if (item.compressed == null) return;
    FileSaveService.showSaveDestinationSheet(
      context: context,
      subFolder: 'PDF Master/Images',
      onSave: (type) async {
        try {
          final dest = await FileSaveService.saveCopy(
            source: item.compressed!,
            type: type,
            subFolder: 'PDF Master/Images',
          );
          if (!mounted) return;
          FileSaveService.showSavedSnackBar(context, dest);
        } catch (e) {
          if (!mounted) return;
          FileSaveService.showFailedSnackBar(context, e);
        }
      },
    );
  }

  Future<void> _shareOne(_CompressItem item, Rect originRect) async {
    if (item.compressed == null) return;
    await SharePlus.instance.share(
      ShareParams(files: [XFile(item.compressed!.path)], sharePositionOrigin: originRect),
    );
  }

  // ⚠️ إصلاح UX: السابق كان يستدعي _saveOne لكل صورة بالتتابع — وبعد
  // التحديث، _saveOne تفتح قائمة اختيار الوجهة (Bottom Sheet)، فكان هذا
  // يعني فتح القائمة من جديد لكل صورة على حدة (تجربة مزعجة لعدة صور).
  // الآن "حفظ الكل" تسأل عن الوجهة مرة واحدة فقط وتُطبِّقها على كل الصور
  // المُكتمِلة دفعة واحدة.
  Future<void> _saveAll() async {
    final done = _items.where((e) => e.isDone).toList();
    if (done.isEmpty) return;
    FileSaveService.showSaveDestinationSheet(
      context: context,
      subFolder: 'PDF Master/Images',
      onSave: (type) async {
        int success = 0;
        for (final item in done) {
          try {
            await FileSaveService.saveCopy(
              source: item.compressed!,
              type: type,
              subFolder: 'PDF Master/Images',
            );
            success++;
          } catch (_) {
            // نستمر للصورة التالية حتى لو فشلت واحدة — نُعلِم بالنتيجة
            // الكلية في النهاية بدل التوقف عند أول فشل.
          }
        }
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            success == done.length
                ? 'تم حفظ $success صورة بنجاح'
                : 'تم حفظ $success من ${done.length} صورة (فشل البعض)',
            style: GoogleFonts.cairo(fontSize: 12),
          ),
          backgroundColor: success == done.length ? Colors.green.shade700 : Colors.orange.shade700,
          behavior: SnackBarBehavior.floating,
        ));
      },
    );
  }

  void _err(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.cairo()),
      backgroundColor: Colors.red.shade700,
      behavior: SnackBarBehavior.floating,
    ));
  }

  int get _totalOriginalSize => _items.fold(0, (sum, e) => sum + e.originalSize);
  int get _totalCompressedSize => _items.where((e) => e.isDone).fold(0, (sum, e) => sum + (e.compressedSize ?? 0));
  bool get _anyDone => _items.any((e) => e.isDone);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? AppTheme.bgDark : const Color(0xFFF5F5FF),
      body: Container(
        decoration: BoxDecoration(gradient: isDark ? AppTheme.bgGradient : const LinearGradient(
          colors: [Color(0xFFF5F5FF), Color(0xFFEEEEFF)], begin: Alignment.topCenter, end: Alignment.bottomCenter)),
        child: SafeArea(child: Column(children: [
          // ── Header ──
          Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 0), child: Row(children: [
            Semantics(
              button: true,
              label: 'رجوع',
              child: GestureDetector(onTap: () => Navigator.pop(context),
                child: Container(width: 42, height: 42, decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: isDark ? AppTheme.bgCardLight : Colors.white, border: Border.all(color: AppTheme.divider)),
                  child: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: AppTheme.textSecondary))),
            ),
            const SizedBox(width: 14),
            Container(width: 36, height: 36, decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), gradient: const LinearGradient(colors: [_accentDark, _accentColor])),
              child: const Icon(Icons.compress_rounded, color: Colors.white, size: 18)),
            const SizedBox(width: 10),
            Text('ضغط الصور', style: GoogleFonts.cairo(fontSize: 20, fontWeight: FontWeight.w800, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
          ])),

          Expanded(child: SingleChildScrollView(physics: const BouncingScrollPhysics(), padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

              // ── اختيار الصور ──
              GestureDetector(onTap: _pickImages, child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: double.infinity, padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), color: isDark ? AppTheme.bgCardLight : Colors.white,
                  border: Border.all(color: _items.isNotEmpty ? _accentColor.withValues(alpha: 0.6) : AppTheme.divider, width: _items.isNotEmpty ? 2 : 1)),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Container(width: 52, height: 52, decoration: const BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [_accentDark, _accentColor])),
                    child: const Icon(Icons.add_photo_alternate_rounded, color: Colors.white, size: 26)),
                  const SizedBox(width: 14),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_items.isEmpty ? 'اختر صوراً للضغط' : 'أضف صوراً أخرى', style: GoogleFonts.cairo(fontSize: 16, fontWeight: FontWeight.w700, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
                    Text(_items.isEmpty ? 'يمكنك اختيار عدة صور دفعة واحدة' : '${_items.length} صورة مُضافة', style: GoogleFonts.cairo(fontSize: 12, color: AppTheme.textMuted)),
                  ]),
                ]),
              )),

              if (_items.isNotEmpty) ...[
                const SizedBox(height: 20),

                // ── ملخّص الحجم الكلي ──
                if (_anyDone)
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: _accentColor.withValues(alpha: 0.08), border: Border.all(color: _accentColor.withValues(alpha: 0.25))),
                    child: Row(children: [
                      const Icon(Icons.savings_rounded, color: _accentColor, size: 22),
                      const SizedBox(width: 10),
                      Expanded(child: Text(
                        'الحجم الكلي: ${_formatSize(_totalOriginalSize)} ← ${_formatSize(_totalCompressedSize)}',
                        style: GoogleFonts.cairo(fontSize: 12.5, fontWeight: FontWeight.w700, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E)),
                      )),
                    ]),
                  ),

                // ── إعدادات الجودة ──
                Text('مستوى الجودة', style: GoogleFonts.cairo(fontSize: 14, fontWeight: FontWeight.w700, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: _qualityChip('منخفضة', 'low', '~40%', isDark)),
                  const SizedBox(width: 8),
                  Expanded(child: _qualityChip('متوسطة', 'medium', '~70%', isDark)),
                  const SizedBox(width: 8),
                  Expanded(child: _qualityChip('عالية', 'high', '~90%', isDark)),
                  const SizedBox(width: 8),
                  Expanded(child: _qualityChip('مخصّصة', 'custom', '', isDark)),
                ]),
                if (_qualityPreset == 'custom') ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: Slider(value: _customQuality, min: 10, max: 100, activeColor: _accentColor, onChanged: (v) => setState(() => _customQuality = v))),
                    SizedBox(width: 44, child: Text('${_customQuality.round()}%', style: GoogleFonts.cairo(fontSize: 13, fontWeight: FontWeight.w700, color: _accentColor))),
                  ]),
                ],

                const SizedBox(height: 16),
                Text('صيغة الإخراج', style: GoogleFonts.cairo(fontSize: 14, fontWeight: FontWeight.w700, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: _formatChip('JPEG', 'jpeg', isDark)),
                  const SizedBox(width: 8),
                  Expanded(child: _formatChip('PNG', 'png', isDark)),
                  const SizedBox(width: 8),
                  Expanded(child: _formatChip('WebP', 'webp', isDark)),
                ]),

                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: isDark ? AppTheme.bgCardLight : Colors.white, border: Border.all(color: AppTheme.divider.withValues(alpha: 0.4))),
                  child: Column(children: [
                    Row(children: [
                      const Icon(Icons.photo_size_select_large_rounded, color: _accentColor, size: 20),
                      const SizedBox(width: 12),
                      Expanded(child: Text('تصغير الأبعاد', style: GoogleFonts.cairo(fontSize: 13, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E)))),
                      Switch.adaptive(value: _resizeEnabled, onChanged: (v) => setState(() => _resizeEnabled = v), activeThumbColor: _accentColor),
                    ]),
                    if (_resizeEnabled) ...[
                      const Divider(height: 1),
                      const SizedBox(height: 8),
                      Row(children: [
                        Text('الحد الأقصى للبعد', style: GoogleFonts.cairo(fontSize: 12, color: AppTheme.textSecondary)),
                        Expanded(child: Slider(value: _maxDimension, min: 480, max: 4000, divisions: 35, activeColor: _accentColor, onChanged: (v) => setState(() => _maxDimension = v))),
                        SizedBox(width: 56, child: Text('${_maxDimension.round()}px', style: GoogleFonts.cairo(fontSize: 11, fontWeight: FontWeight.w700, color: _accentColor))),
                      ]),
                    ],
                  ]),
                ),

                const SizedBox(height: 20),
                Text('الصور (${_items.length})', style: GoogleFonts.cairo(fontSize: 14, fontWeight: FontWeight.w700, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
                const SizedBox(height: 10),
                ..._items.map((item) => _ImageRow(
                  item: item,
                  isDark: isDark,
                  accent: _accentColor,
                  formatSize: _formatSize,
                  onRemove: () => _removeItem(item.id),
                  onSave: () => _saveOne(item),
                  onShare: (rect) => _shareOne(item, rect),
                )),

                const SizedBox(height: 28),
                Row(children: [
                  Expanded(child: SizedBox(height: 52, child: ElevatedButton(
                    onPressed: _isProcessingAll ? null : _compressAll,
                    style: ElevatedButton.styleFrom(backgroundColor: _accentDark, disabledBackgroundColor: AppTheme.bgCardLight,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    child: _isProcessingAll
                      ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)), const SizedBox(width: 10), Text('جارٍ الضغط...', style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.w700))])
                      : Row(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.compress_rounded, color: Colors.white), const SizedBox(width: 8), Text('ضغط الكل', style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15))]),
                  ))),
                  if (_anyDone) ...[
                    const SizedBox(width: 10),
                    SizedBox(height: 52, width: 52, child: ElevatedButton(
                      onPressed: _saveAll,
                      style: ElevatedButton.styleFrom(backgroundColor: _accentColor, padding: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                      child: const Icon(Icons.save_alt_rounded, color: Colors.white),
                    )),
                  ],
                ]),
                const SizedBox(height: 20),
              ],
            ]),
          )),
        ])),
      ),
    );
  }

  Widget _qualityChip(String label, String value, String hint, bool isDark) {
    final sel = _qualityPreset == value;
    return GestureDetector(
      onTap: () { HapticFeedback.selectionClick(); setState(() => _qualityPreset = value); },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: sel ? _accentColor.withValues(alpha: 0.15) : isDark ? AppTheme.bgCardLight : Colors.white, border: Border.all(color: sel ? _accentColor : AppTheme.divider.withValues(alpha: 0.5))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: GoogleFonts.cairo(fontSize: 12, fontWeight: FontWeight.w700, color: sel ? _accentColor : AppTheme.textSecondary)),
          if (hint.isNotEmpty) Text(hint, style: GoogleFonts.cairo(fontSize: 9.5, color: AppTheme.textMuted)),
        ]),
      ),
    );
  }

  Widget _formatChip(String label, String value, bool isDark) {
    final sel = _format == value;
    return GestureDetector(
      onTap: () { HapticFeedback.selectionClick(); setState(() => _format = value); },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: sel ? _accentColor.withValues(alpha: 0.15) : isDark ? AppTheme.bgCardLight : Colors.white, border: Border.all(color: sel ? _accentColor : AppTheme.divider.withValues(alpha: 0.5))),
        child: Center(child: Text(label, style: GoogleFonts.cairo(fontSize: 12.5, fontWeight: FontWeight.w700, color: sel ? _accentColor : AppTheme.textSecondary))),
      ),
    );
  }
}

class _ImageRow extends StatelessWidget {
  final _CompressItem item;
  final bool isDark;
  final Color accent;
  final String Function(int) formatSize;
  final VoidCallback onRemove;
  final VoidCallback onSave;
  final void Function(Rect originRect) onShare;

  const _ImageRow({
    required this.item,
    required this.isDark,
    required this.accent,
    required this.formatSize,
    required this.onRemove,
    required this.onSave,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final shareKey = GlobalKey();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), color: isDark ? AppTheme.bgCardLight : Colors.white, border: Border.all(color: item.isDone ? accent.withValues(alpha: 0.4) : AppTheme.divider.withValues(alpha: 0.5))),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.file(item.original, width: 52, height: 52, fit: BoxFit.cover),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(item.original.path.split('/').last, style: GoogleFonts.cairo(fontSize: 13, fontWeight: FontWeight.w700, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E)), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 3),
          if (item.isProcessing)
            Text('جارٍ الضغط...', style: GoogleFonts.cairo(fontSize: 11, color: AppTheme.textMuted))
          else if (item.isDone)
            Row(children: [
              Text(formatSize(item.originalSize), style: GoogleFonts.cairo(fontSize: 11, color: AppTheme.textMuted, decoration: TextDecoration.lineThrough)),
              const SizedBox(width: 6),
              Icon(Icons.arrow_back_rounded, size: 11, color: accent),
              const SizedBox(width: 6),
              Text(formatSize(item.compressedSize!), style: GoogleFonts.cairo(fontSize: 11, fontWeight: FontWeight.w700, color: accent)),
              if (item.savingsPercent != null) ...[
                const SizedBox(width: 6),
                Text('(−${item.savingsPercent!.round()}%)', style: GoogleFonts.cairo(fontSize: 10.5, fontWeight: FontWeight.w700, color: Colors.green.shade600)),
              ],
            ])
          else
            Text(formatSize(item.originalSize), style: GoogleFonts.cairo(fontSize: 11, color: AppTheme.textMuted)),
        ])),
        if (item.isProcessing)
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        else if (item.isDone) ...[
          Semantics(button: true, label: 'حفظ', child: GestureDetector(onTap: onSave, child: Padding(padding: const EdgeInsets.all(6), child: Icon(Icons.save_alt_rounded, size: 18, color: accent)))),
          Semantics(
            button: true,
            label: 'مشاركة',
            child: GestureDetector(
              key: shareKey,
              onTap: () {
                final box = shareKey.currentContext?.findRenderObject() as RenderBox?;
                final origin = box != null ? box.localToGlobal(Offset.zero) & box.size : const Rect.fromLTWH(0, 0, 1, 1);
                onShare(origin);
              },
              child: Padding(padding: const EdgeInsets.all(6), child: Icon(Icons.share_rounded, size: 18, color: accent)),
            ),
          ),
        ] else
          Semantics(button: true, label: 'إزالة', child: GestureDetector(onTap: onRemove, child: const Padding(padding: EdgeInsets.all(6), child: Icon(Icons.close_rounded, size: 18, color: AppTheme.textMuted)))),
      ]),
    );
  }
}
