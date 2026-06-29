import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../../services/pdf_service.dart';
import '../../theme/app_theme.dart';
import '../result_screen.dart';

class ImportItem {
  final String id;
  final AssetEntity? asset;
  File? file;
  bool isEdited;

  ImportItem({required this.id, this.asset, this.file, this.isEdited = false});
  bool get hasFile => file != null;
}

class ImageImportScreen extends StatefulWidget {
  final List<AssetEntity> selectedAssets;
  final List<File>? pickedFiles;

  const ImageImportScreen({super.key, required this.selectedAssets, this.pickedFiles});

  @override
  State<ImageImportScreen> createState() => _ImageImportScreenState();
}

class _ImageImportScreenState extends State<ImageImportScreen> with SingleTickerProviderStateMixin {
  late List<ImportItem> _items;
  late final TextEditingController _nameCtrl;
  String _quality = 'high';
  String _pageSize = 'A4';
  String _orientation = 'auto';
  int _perPage = 1;
  bool _isConverting = false;
  double? _estimatedMB;
  late final AnimationController _convertAnim;

  static const _qualityOptions = [
    ('low',    'حجم صغير',   'ضغط عالٍ للمشاركة السريعة',    Icons.compress_rounded,       0.3),
    ('medium', 'متوازنة',    'مثالية للمستندات والأرشيف',     Icons.balance_rounded,        0.7),
    ('high',   'أفضل جودة',  'دقة كاملة للطباعة والحفظ',     Icons.high_quality_rounded,   1.0),
  ];
  static const _pageSizes = ['A4', 'A3', 'Letter', 'Legal'];
  static const _orientations = [
    ('auto',      'تلقائي',  Icons.screen_rotation_rounded),
    ('portrait',  'عمودي',   Icons.stay_current_portrait_rounded),
    ('landscape', 'أفقي',    Icons.stay_current_landscape_rounded),
  ];
  static const _perPageOptions = [1, 2, 4];

  @override
  void initState() {
    super.initState();
    _convertAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _items = [
      ...widget.selectedAssets.map((a) => ImportItem(id: a.id, asset: a)),
      ...?widget.pickedFiles?.map((f) => ImportItem(id: f.path, file: f)),
    ];
    _nameCtrl = TextEditingController(text: 'مستند_${_formattedDate()}');
    _estimateSize();
  }

  @override
  void dispose() { _nameCtrl.dispose(); _convertAnim.dispose(); super.dispose(); }

  String _formattedDate() { final now = DateTime.now(); return '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'; }

  Future<void> _estimateSize() async {
    double total = 0;
    await Future.wait(_items.map((item) async {
      final f = item.hasFile ? item.file : await item.asset?.originFile;
      if (f != null) total += await f.length();
    }));
    final factor = _quality == 'low' ? 0.3 : _quality == 'medium' ? 0.7 : 1.0;
    if (mounted) setState(() => _estimatedMB = (total * factor) / 1048576);
  }

  void _remove(ImportItem item) { HapticFeedback.lightImpact(); setState(() => _items.remove(item)); _estimateSize(); }
  void _reorder(int from, int to) { setState(() { if (from < to) to -= 1; _items.insert(to, _items.removeAt(from)); }); }

  // ── قص الصورة - مع تحويل AssetEntity لملف أولاً ──
  Future<void> _crop(int index) async {
    final item = _items[index];
    File? src;
    // Get actual file path first
    if (item.hasFile) {
      src = item.file;
    } else if (item.asset != null) {
      try {
        _toast('جارٍ تجهيز الصورة...', isSuccess: true);
        src = await item.asset!.originFile;
      } catch (e) {
        _toast('فشل تحميل الصورة: $e');
        return;
      }
    }
    if (src == null || !src.existsSync()) { _toast('لا يمكن تحميل الصورة'); return; }
    if (!mounted) return;

    try {
      final cropped = await ImageCropper().cropImage(
        sourcePath: src.path,
        compressFormat: ImageCompressFormat.jpg,
        compressQuality: 95,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'قص الصورة',
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
      if (cropped != null && mounted) {
        final croppedFile = File(cropped.path);
        if (croppedFile.existsSync()) {
          setState(() { _items[index]..file = croppedFile..isEdited = true; });
          _estimateSize();
          _toast('تم قص الصورة بنجاح ✓', isSuccess: true);
        }
      }
    } catch (e) {
      _toast('فشل القص: تأكد من منح صلاحيات الوصول للصور');
    }
  }

  Future<void> _rotate(int index) async {
    final item = _items[index];
    File? src = item.hasFile ? item.file : await item.asset?.originFile;
    if (src == null || !mounted) return;
    try {
      final bytes = await FlutterImageCompress.compressWithFile(src.absolute.path, quality: 95, rotate: 90);
      if (bytes == null) throw Exception('فشل التدوير');
      final tmp = File('${Directory.systemTemp.path}/rot_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await tmp.writeAsBytes(bytes);
      if (mounted) { setState(() { _items[index]..file = tmp..isEdited = true; }); _estimateSize(); _toast('تم التدوير ✓', isSuccess: true); }
    } catch (e) { _toast('فشل التدوير: $e'); }
  }

  Future<void> _addMore() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp'], allowMultiple: true);
      if (result != null && result.paths.isNotEmpty && mounted) {
        setState(() { for (final p in result.paths.whereType<String>()) {
          _items.add(ImportItem(id: p, file: File(p)));
        } });
        _estimateSize();
      }
    } catch (e) { _toast('فشل إضافة الصور: $e'); }
  }

  Future<File> _compressFile(File src) async {
    final q = _quality == 'low' ? 40 : _quality == 'medium' ? 72 : 92;
    final bytes = await FlutterImageCompress.compressWithFile(src.absolute.path, quality: q, format: CompressFormat.jpeg);
    if (bytes == null) return src;
    final out = File('${Directory.systemTemp.path}/cmp_${DateTime.now().microsecondsSinceEpoch}.jpg');
    await out.writeAsBytes(bytes);
    return out;
  }

  Future<void> _convert() async {
    if (_items.isEmpty) return;
    if (_nameCtrl.text.trim().isEmpty) { _toast('الرجاء إدخال اسم الملف'); return; }
    setState(() => _isConverting = true);
    _convertAnim.repeat();
    try {
      final paths = <String>[];
      for (final item in _items) {
        File? f = item.file ?? await item.asset?.originFile;
        if (f == null) continue;
        final compressed = await _compressFile(f);
        paths.add(compressed.path);
      }
      if (paths.isEmpty) { _toast('لا توجد ملفات صالحة'); return; }
      final pdf = await PdfService.imagesToPdf(paths, quality: _quality, pageSize: _pageSize, pageOrientation: _orientation, imagesPerPage: _perPage, outputName: _nameCtrl.text.trim());
      if (mounted) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => ResultScreen(
          file: pdf, title: 'تم إنشاء PDF بنجاح!', subtitle: 'تم تحويل ${_items.length} صورة بنجاح',
          toolId: 'img_to_pdf', toolName: 'صورة إلى PDF',
          settings: {'الجودة': _qualityLabel(_quality), 'حجم الورق': _pageSize, 'الاتجاه': _orientationLabel(_orientation), 'صور/صفحة': '$_perPage'},
        )));
      }
    } catch (e) { _toast('حدث خطأ أثناء التحويل: $e'); }
    finally { _convertAnim.stop(); _convertAnim.reset(); if (mounted) setState(() => _isConverting = false); }
  }

  void _showSettings() {
    showModalBottomSheet(context: context, backgroundColor: Colors.transparent, isScrollControlled: true, builder: (_) => _SettingsSheet(
      quality: _quality, pageSize: _pageSize, orientation: _orientation, perPage: _perPage, estimatedMB: _estimatedMB,
      onChanged: ({q, s, o, p}) { setState(() { if (q != null) _quality = q; if (s != null) _pageSize = s; if (o != null) _orientation = o; if (p != null) _perPage = p; }); _estimateSize(); },
      onConfirm: () { Navigator.pop(context); _convert(); },
    ));
  }

  void _toast(String msg, {bool isSuccess = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.cairo(color: Colors.white)),
      backgroundColor: isSuccess ? Colors.green.shade700 : Colors.redAccent.shade700,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
    ));
  }

  String _qualityLabel(String q) => q == 'low' ? 'حجم صغير' : q == 'medium' ? 'متوازنة' : 'أفضل جودة';
  String _orientationLabel(String o) => o == 'portrait' ? 'عمودي' : o == 'landscape' ? 'أفقي' : 'تلقائي';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      appBar: AppBar(
        backgroundColor: Colors.transparent, elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios_new_rounded, color: AppTheme.textPrimary, size: 20), onPressed: () => Navigator.pop(context, true)),
        title: Text('تجهيز المستند', style: GoogleFonts.cairo(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 17)),
        centerTitle: true,
        actions: [
          IconButton(icon: const Icon(Icons.add_photo_alternate_rounded, color: AppTheme.textPrimary, size: 22), tooltip: 'إضافة المزيد', onPressed: _addMore),
          IconButton(icon: const Icon(Icons.tune_rounded, color: AppTheme.primary, size: 22), tooltip: 'الإعدادات', onPressed: _showSettings),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.bgGradient),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(children: [
              _buildNameField(),
              _buildCountBar(),
              Expanded(child: _buildList()),
              _buildConvertBar(),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildNameField() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: TextField(
      controller: _nameCtrl,
      style: GoogleFonts.cairo(color: AppTheme.textPrimary, fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        hintText: 'اسم الملف',
        hintStyle: GoogleFonts.cairo(color: Colors.grey[600]),
        filled: true, fillColor: AppTheme.bgCardLight,
        prefixIcon: const Icon(Icons.drive_file_rename_outline_rounded, color: AppTheme.primary, size: 20),
        suffixIcon: IconButton(icon: Icon(Icons.clear_rounded, color: Colors.grey[600], size: 18), onPressed: () => _nameCtrl.clear()),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppTheme.primary, width: 1.5)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    ),
  );

  Widget _buildCountBar() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 16, 0),
    child: Row(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: AppTheme.bgCardLight, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.layers_rounded, size: 13, color: AppTheme.primary),
          const SizedBox(width: 5),
          Text('${_items.length} صورة', style: GoogleFonts.cairo(color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w500)),
        ]),
      ),
      const SizedBox(width: 8),
      if (_estimatedMB != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: AppTheme.accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.data_usage_rounded, size: 13, color: AppTheme.accent),
            const SizedBox(width: 5),
            Text('~${_estimatedMB!.toStringAsFixed(1)} MB', style: GoogleFonts.cairo(color: AppTheme.accent, fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        ),
      const Spacer(),
      TextButton.icon(onPressed: _showSettings, icon: const Icon(Icons.tune_rounded, size: 16, color: AppTheme.primary), label: Text('الإعدادات', style: GoogleFonts.cairo(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w600))),
    ]),
  );

  Widget _buildList() {
    if (_items.isEmpty) {
      return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(padding: const EdgeInsets.all(24), decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.04), shape: BoxShape.circle), child: Icon(Icons.image_not_supported_outlined, size: 48, color: Colors.grey[600])),
        const SizedBox(height: 16),
        Text('لا توجد صور', style: GoogleFonts.cairo(color: Colors.grey[500], fontSize: 16)),
        const SizedBox(height: 8),
        TextButton.icon(onPressed: _addMore, icon: const Icon(Icons.add_rounded, color: AppTheme.primary), label: Text('أضف صوراً', style: GoogleFonts.cairo(color: AppTheme.primary))),
      ]));
    }
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      // ignore: deprecated_member_use
      itemCount: _items.length, onReorder: _reorder,
      proxyDecorator: (child, _, anim) => AnimatedBuilder(animation: anim, builder: (_, c) => Material(color: Colors.transparent, elevation: 12 * anim.value, shadowColor: AppTheme.primary.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(16), child: c), child: child),
      itemBuilder: (_, i) => Padding(
        key: ValueKey(_items[i].id),
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: _ItemCard(item: _items[i], index: i, onRemove: () => _remove(_items[i]), onCrop: () => _crop(i), onRotate: () => _rotate(i)),
      ),
    );
  }

  Widget _buildConvertBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      decoration: BoxDecoration(color: AppTheme.bgDark, boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 12, offset: const Offset(0, -4))]),
      child: SafeArea(top: false, child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Settings summary row
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: AppTheme.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.primary.withValues(alpha: 0.2))),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            _chip(_qualityLabel(_quality), Icons.high_quality_rounded),
            _chip(_pageSize, Icons.description_rounded),
            _chip(_orientationLabel(_orientation), Icons.screen_rotation_rounded),
            _chip('$_perPage صور/ص', Icons.grid_view_rounded),
          ]),
        ),
        SizedBox(width: double.infinity, height: 52, child: ElevatedButton(
          onPressed: (_items.isEmpty || _isConverting) ? null : _showSettings,
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, disabledBackgroundColor: Colors.grey[800], elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          child: _isConverting
              ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5)), const SizedBox(width: 12), Text('جارٍ المعالجة…', style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15))])
              : Row(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.picture_as_pdf_rounded, color: Colors.white, size: 20), const SizedBox(width: 10), Text('إنشاء PDF', style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15))]),
        )),
        const SizedBox(height: 4),
      ])),
    );
  }

  Widget _chip(String label, IconData icon) => Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, size: 13, color: AppTheme.textSecondary),
    const SizedBox(width: 4),
    Text(label, style: GoogleFonts.cairo(color: AppTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.w500)),
  ]);
}

class _ItemCard extends StatelessWidget {
  final ImportItem item;
  final int index;
  final VoidCallback onRemove, onCrop, onRotate;

  const _ItemCard({required this.item, required this.index, required this.onRemove, required this.onCrop, required this.onRotate});

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey('dismiss_${item.id}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onRemove(),
      background: Container(decoration: BoxDecoration(color: Colors.red.shade700, borderRadius: BorderRadius.circular(16)), alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete_rounded, color: Colors.white, size: 26)),
      child: Container(
        decoration: BoxDecoration(color: AppTheme.bgCardLight, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white.withValues(alpha: 0.05))),
        child: Row(children: [
          ClipRRect(
            borderRadius: const BorderRadius.horizontal(left: Radius.circular(15)),
            child: SizedBox(
              width: 72, height: 72,
              child: item.hasFile
                  ? Image.file(item.file!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: AppTheme.bgCard, child: const Icon(Icons.broken_image_rounded, color: AppTheme.textMuted)))
                  : AssetEntityImage(item.asset!, isOriginal: false, thumbnailSize: const ThumbnailSize.square(150), fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('الصفحة ${index + 1}', style: GoogleFonts.cairo(color: AppTheme.textPrimary, fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 2),
            Row(children: [
              if (item.isEdited) _tag('معدّلة', AppTheme.accent) else if (item.asset != null) _tag('${item.asset!.width}×${item.asset!.height}', AppTheme.textMuted),
            ]),
          ])),
          Row(mainAxisSize: MainAxisSize.min, children: [
            _iconBtn(Icons.rotate_right_rounded, 'تدوير', onRotate, AppTheme.primaryLight),
            _iconBtn(Icons.crop_rounded, 'قص', onCrop, AppTheme.primary),
            _iconBtn(Icons.delete_outline_rounded, 'حذف', onRemove, Colors.redAccent),
            ReorderableDragStartListener(index: index, child: Padding(padding: const EdgeInsets.all(8), child: Icon(Icons.drag_indicator_rounded, color: Colors.grey[600], size: 20))),
          ]),
        ]),
      ),
    );
  }

  Widget _tag(String text, Color color) => Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2), decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)), child: Text(text, style: GoogleFonts.cairo(color: color, fontSize: 11, fontWeight: FontWeight.w500)));
  Widget _iconBtn(IconData icon, String tip, VoidCallback fn, Color color) => Tooltip(message: tip, child: InkWell(onTap: fn, borderRadius: BorderRadius.circular(8), child: Padding(padding: const EdgeInsets.all(8), child: Icon(icon, color: color, size: 20))));
}

typedef _OnChanged = void Function({String? q, String? s, String? o, int? p});

class _SettingsSheet extends StatefulWidget {
  final String quality, pageSize, orientation;
  final int perPage;
  final double? estimatedMB;
  final _OnChanged onChanged;
  final VoidCallback onConfirm;

  const _SettingsSheet({required this.quality, required this.pageSize, required this.orientation, required this.perPage, required this.estimatedMB, required this.onChanged, required this.onConfirm});

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late String _q, _s, _o;
  late int _p;

  @override
  void initState() { super.initState(); _q = widget.quality; _s = widget.pageSize; _o = widget.orientation; _p = widget.perPage; }

  void _notify() => widget.onChanged(q: _q, s: _s, o: _o, p: _p);

  String get _estimatedDesc {
    if (widget.estimatedMB == null) return '';
    final factor = _q == 'low' ? 0.3 : _q == 'medium' ? 0.7 : 1.0;
    final adjusted = widget.estimatedMB! * factor / (widget.quality == 'low' ? 0.3 : widget.quality == 'medium' ? 0.7 : 1.0);
    return '${adjusted.toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: Container(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
      decoration: const BoxDecoration(color: Color(0xFF1C1E2E), borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(margin: const EdgeInsets.symmetric(vertical: 12), width: 36, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
        Row(children: [
          Text('إعدادات PDF', style: GoogleFonts.cairo(color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.bold)),
          const Spacer(),
          if (widget.estimatedMB != null) Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: AppTheme.accent.withValues(alpha: 0.1)),
            child: Text('~$_estimatedDesc', style: GoogleFonts.cairo(color: AppTheme.accent, fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: 20),

        // جودة الصورة
        _sectionLabel('جودة الصورة'),
        const SizedBox(height: 8),
        ..._ImageImportScreenState._qualityOptions.map((opt) {
          final sel = _q == opt.$1;
          return GestureDetector(
            onTap: () { setState(() => _q = opt.$1); _notify(); },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(color: sel ? AppTheme.primary.withValues(alpha: 0.12) : AppTheme.bgCardLight, borderRadius: BorderRadius.circular(14), border: Border.all(color: sel ? AppTheme.primary : Colors.white.withValues(alpha: 0.05), width: sel ? 1.5 : 1)),
              child: Row(children: [
                Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: (sel ? AppTheme.primary : Colors.grey[700])!.withValues(alpha: 0.2), shape: BoxShape.circle), child: Icon(opt.$4, color: sel ? AppTheme.primary : Colors.grey[400], size: 18)),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(opt.$2, style: GoogleFonts.cairo(color: sel ? AppTheme.primary : AppTheme.textPrimary, fontWeight: sel ? FontWeight.bold : FontWeight.w600, fontSize: 14)),
                  Text(opt.$3, style: GoogleFonts.cairo(color: AppTheme.textMuted, fontSize: 12)),
                ])),
                if (sel) const Icon(Icons.check_circle_rounded, color: AppTheme.primary, size: 20),
              ]),
            ),
          );
        }),
        const SizedBox(height: 20),

        // حجم الورق
        _sectionLabel('حجم الورق'),
        const SizedBox(height: 8),
        _segmented(options: _ImageImportScreenState._pageSizes, selected: _s, onSelected: (v) { setState(() => _s = v); _notify(); }),
        const SizedBox(height: 20),

        // اتجاه الصفحة
        _sectionLabel('اتجاه الصفحة'),
        const SizedBox(height: 8),
        Row(children: _ImageImportScreenState._orientations.map((e) {
          final sel = _o == e.$1;
          return Expanded(child: GestureDetector(
            onTap: () { setState(() => _o = e.$1); _notify(); },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(color: sel ? AppTheme.primary.withValues(alpha: 0.15) : AppTheme.bgCardLight, borderRadius: BorderRadius.circular(12), border: Border.all(color: sel ? AppTheme.primary : Colors.white.withValues(alpha: 0.05))),
              child: Column(children: [
                Icon(e.$3, color: sel ? AppTheme.primary : Colors.grey[500], size: 22),
                const SizedBox(height: 4),
                Text(e.$2, style: GoogleFonts.cairo(color: sel ? AppTheme.primary : AppTheme.textSecondary, fontSize: 12, fontWeight: sel ? FontWeight.bold : FontWeight.normal)),
              ]),
            ),
          ));
        }).toList()),
        const SizedBox(height: 20),

        // صور لكل صفحة
        _sectionLabel('صور في كل صفحة'),
        const SizedBox(height: 8),
        Row(children: _ImageImportScreenState._perPageOptions.map((n) {
          final sel = _p == n;
          return Expanded(child: GestureDetector(
            onTap: () { setState(() => _p = n); _notify(); },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(color: sel ? AppTheme.primary.withValues(alpha: 0.15) : AppTheme.bgCardLight, borderRadius: BorderRadius.circular(12), border: Border.all(color: sel ? AppTheme.primary : Colors.white.withValues(alpha: 0.05))),
              child: Column(children: [
                Text('$n', style: GoogleFonts.cairo(fontSize: 20, fontWeight: FontWeight.w900, color: sel ? AppTheme.primary : AppTheme.textPrimary)),
                Text(n == 1 ? 'صورة' : 'صور', style: GoogleFonts.cairo(fontSize: 11, color: sel ? AppTheme.primaryLight : AppTheme.textMuted)),
              ]),
            ),
          ));
        }).toList()),
        const SizedBox(height: 24),

        SizedBox(width: double.infinity, height: 52, child: ElevatedButton(
          onPressed: widget.onConfirm,
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          child: Text('بدء التحويل', style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
        )),
      ])),
    ))));
  }

  Widget _sectionLabel(String text) => Text(text, style: GoogleFonts.cairo(color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5));

  Widget _segmented({required List<String> options, required String selected, required void Function(String) onSelected}) {
    return Row(children: options.map((v) {
      final sel = selected == v;
      return Expanded(child: GestureDetector(
        onTap: () => onSelected(v),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(color: sel ? AppTheme.primary.withValues(alpha: 0.15) : AppTheme.bgCardLight, borderRadius: BorderRadius.circular(10), border: Border.all(color: sel ? AppTheme.primary : Colors.white.withValues(alpha: 0.05))),
          child: Center(child: Text(v, style: GoogleFonts.cairo(color: sel ? AppTheme.primary : AppTheme.textSecondary, fontSize: 13, fontWeight: sel ? FontWeight.bold : FontWeight.normal))),
        ),
      ));
    }).toList());
  }
}
