import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/file_save_service.dart';
import '../../services/history_service.dart';

// ══════════════════════════════════════════════════════
//  نظام الألوان — أسلوب تطبيقات ضغط الملفات العالمية
// ══════════════════════════════════════════════════════

class _C {
  // الخلفيات
  static const bg         = Color(0xFF0F1117);   // أسود دافئ
  static const surface    = Color(0xFF171B26);   // كارت
  static const surfaceEl  = Color(0xFF1E2333);   // كارت مرتفع
  // ignore: unused_field
  static const overlay    = Color(0xFF252A3A);   // hover / selected

  // التمييز الرئيسي — أزرق مشبع نقي
  static const accent     = Color(0xFF3B73F6);
  static const accentSoft = Color(0xFF4F84F8);
  static const accentGlow = Color(0xFF2856C8);

  // التمييز الثانوي — بنفسجي للتشفير
  static const crypto     = Color(0xFF7C4DFF);
  static const cryptoSoft = Color(0xFF9E6FFF);

  // الحالات
  static const success    = Color(0xFF00C875);
  static const successBg  = Color(0xFF00230F);
  static const warn       = Color(0xFFFFAA00);
  static const error      = Color(0xFFFF4444);
  static const errorBg    = Color(0xFF2A0A0A);

  // النص
  static const textHigh   = Color(0xFFEDF0F7);
  static const textMed    = Color(0xFF8892A4);
  static const textLow    = Color(0xFF3F4A5E);

  // الحدود
  static const border     = Color(0xFF232A3C);
  static const borderHi   = Color(0xFF2D3650);
}

// ══════════════════════════════════════════════════════
//  نموذج ملف
// ══════════════════════════════════════════════════════

class _ZipEntry {
  final String id, name, path;
  final int size;
  final bool isFolder;
  bool selected;

  _ZipEntry({
    required this.id, required this.name,
    required this.path, required this.size,
    // ignore: unused_element_parameter
    required this.isFolder, this.selected = true,
  });

  String get displaySize => _fmtBytes(size);
}

String _fmtBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1 << 20) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1 << 30) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
}

// ══════════════════════════════════════════════════════
//  Isolate
// ══════════════════════════════════════════════════════

class _IsolateParams {
  final List<String> paths;
  final String outputPath;
  final int compressionLevel;
  final String? password;
  final SendPort sendPort;
  const _IsolateParams({
    required this.paths, required this.outputPath,
    required this.compressionLevel, required this.sendPort, this.password,
  });
}

class _IsolateProgress {
  final double progress;
  final String stage;
  final String? error;
  final int? resultSize;
  const _IsolateProgress({
    required this.progress, required this.stage, this.error, this.resultSize,
  });
}

void _zipIsolate(_IsolateParams params) {
  try {
    final filePaths = <String>[], fileNames = <String>[];
    for (final path in params.paths) {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.file) {
        filePaths.add(path); fileNames.add(p.basename(path));
      } else if (type == FileSystemEntityType.directory) {
        final dir = Directory(path);
        final baseName = p.basename(path);
        try {
          for (final f in dir.listSync(recursive: true).whereType<File>()) {
            filePaths.add(f.path);
            fileNames.add(p.join(baseName, p.relative(f.path, from: path)));
          }
        } catch (_) {}
      }
    }
    if (filePaths.isEmpty) throw Exception('لا توجد ملفات للضغط');

    int totalBytes = 0;
    final fileSizes = <int>[];
    for (final fp in filePaths) {
      try { final s = File(fp).lengthSync(); fileSizes.add(s); totalBytes += s; }
      catch (_) { fileSizes.add(0); }
    }

    final archive = Archive();
    int processedBytes = 0;
    List<int>? keyBytes;
    if (params.password != null && params.password!.isNotEmpty) {
      keyBytes = sha256.convert(utf8.encode(params.password!)).bytes;
    }

    for (int i = 0; i < filePaths.length; i++) {
      params.sendPort.send(_IsolateProgress(
        progress: totalBytes > 0 ? processedBytes / totalBytes : i / filePaths.length,
        stage: p.basename(filePaths[i]),
      ));
      try {
        Uint8List bytes = File(filePaths[i]).readAsBytesSync();
        if (keyBytes != null) bytes = _xorEncrypt(bytes, keyBytes, i);
        archive.addFile(ArchiveFile(fileNames[i], bytes.length, bytes));
      } catch (_) {}
      processedBytes += fileSizes[i];
    }

    params.sendPort.send(const _IsolateProgress(progress: 0.95, stage: 'كتابة الأرشيف...'));
    final encoded = ZipEncoder().encode(archive, level: params.compressionLevel);
    if (encoded == null) throw Exception('فشل ترميز الأرشيف');
    File(params.outputPath).writeAsBytesSync(encoded);
    final resultSize = File(params.outputPath).lengthSync();
    params.sendPort.send(_IsolateProgress(progress: 1.0, stage: 'اكتمل', resultSize: resultSize));
  } catch (e) {
    params.sendPort.send(_IsolateProgress(progress: 0, stage: 'خطأ', error: e.toString()));
  }
}

Uint8List _xorEncrypt(Uint8List data, List<int> key, int fileIndex) {
  final result = Uint8List(data.length);
  final keyLen = key.length;
  for (int i = 0; i < data.length; i++) {
    result[i] = data[i] ^ key[(i + fileIndex * 7) % keyLen];
  }
  return result;
}

// ══════════════════════════════════════════════════════
//  الشاشة الرئيسية
// ══════════════════════════════════════════════════════

enum _Phase { idle, compressing, done }

class ZipCompressScreen extends StatefulWidget {
  const ZipCompressScreen({super.key});
  @override
  State<ZipCompressScreen> createState() => _ZipCompressScreenState();
}

class _ZipCompressScreenState extends State<ZipCompressScreen>
    with TickerProviderStateMixin {

  final List<_ZipEntry> _entries    = [];
  final _nameCtrl     = TextEditingController(text: 'archive');
  final _passwordCtrl = TextEditingController();
  final _listScroll   = ScrollController();

  int    _level            = 6;
  bool   _encryptEnabled   = false;
  bool   _passwordVisible  = false;
  _Phase _phase            = _Phase.idle;

  double  _progress    = 0;
  String  _currentFile = '';
  String? _errorMsg;
  File?   _resultFile;
  int?    _originalTotal;
  int?    _resultSize;
  bool    _wasEncrypted = false;

  late AnimationController _pulseCtrl, _successCtrl, _fabCtrl;
  // ignore: unused_field
  late Animation<double>   _pulseScale, _successBounce, _fabScale;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))
      ..repeat(reverse: true);
    _pulseScale = Tween(begin: 0.95, end: 1.05)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _successCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    _successBounce = CurvedAnimation(parent: _successCtrl, curve: Curves.elasticOut);

    _fabCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
    _fabScale = CurvedAnimation(parent: _fabCtrl, curve: Curves.easeOut);
    _fabCtrl.forward();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose(); _successCtrl.dispose(); _fabCtrl.dispose();
    _nameCtrl.dispose(); _passwordCtrl.dispose(); _listScroll.dispose();
    super.dispose();
  }

  // ── منطق الملفات ──

  Future<void> _pickFiles() async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.any);
    if (r == null) return;
    _addPaths(r.paths.whereType<String>().toList(), isFolder: false);
  }

  Future<void> _pickFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    _addPaths([dir], isFolder: true);
  }

  void _addPaths(List<String> paths, {required bool isFolder}) {
    setState(() {
      for (final path in paths) {
        if (_entries.any((e) => e.path == path)) continue;
        int size = 0;
        if (isFolder) {
          try { Directory(path).listSync(recursive: true).whereType<File>().forEach((f) => size += f.lengthSync()); } catch (_) {}
        } else {
          final f = File(path);
          size = f.existsSync() ? f.lengthSync() : 0;
        }
        _entries.add(_ZipEntry(id: path, name: p.basename(path), path: path, size: size, isFolder: isFolder));
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_listScroll.hasClients) {
        _listScroll.animateTo(_listScroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  void _removeEntry(_ZipEntry e) => setState(() => _entries.remove(e));
  void _toggleAll(bool v) => setState(() { for (final e in _entries) { e.selected = v; } });

  int get _totalSelectedSize => _entries.where((e) => e.selected).fold(0, (s, e) => s + e.size);
  List<_ZipEntry> get _selected => _entries.where((e) => e.selected).toList();

  // ── بدء الضغط ──

  Future<void> _startCompress() async {
    final sel = _selected;
    if (sel.isEmpty) return;
    if (_encryptEnabled && _passwordCtrl.text.trim().isEmpty) {
      _toast('أدخل كلمة المرور أولاً', isError: true);
      return;
    }

    HapticFeedback.mediumImpact();
    final tmpDir = await getTemporaryDirectory();
    final name = _nameCtrl.text.trim().isEmpty ? 'archive' : _nameCtrl.text.trim();
    final outPath = '${tmpDir.path}/$name.zip';

    setState(() {
      _phase = _Phase.compressing; _progress = 0; _currentFile = '';
      _errorMsg = null; _resultFile = null; _resultSize = null;
      _originalTotal = _totalSelectedSize;
      _wasEncrypted = _encryptEnabled && _passwordCtrl.text.trim().isNotEmpty;
    });

    final rp = ReceivePort();
    await Isolate.spawn(_zipIsolate, _IsolateParams(
      paths: sel.map((e) => e.path).toList(), outputPath: outPath,
      compressionLevel: _level, sendPort: rp.sendPort,
      password: _wasEncrypted ? _passwordCtrl.text.trim() : null,
    ));

    await for (final msg in rp) {
      if (msg is _IsolateProgress) {
        if (!mounted) break;
        if (msg.error != null) {
          setState(() { _phase = _Phase.idle; _errorMsg = msg.error; });
          rp.close(); break;
        }
        setState(() { _progress = msg.progress; _currentFile = msg.stage; });
        if (msg.resultSize != null) {
          setState(() { _phase = _Phase.done; _resultFile = File(outPath); _resultSize = msg.resultSize; });
          _successCtrl.forward(from: 0);
          HapticFeedback.lightImpact();
          await _saveHistory(outPath, msg.resultSize!);
          rp.close(); break;
        }
      }
    }
  }

  void _toast(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: isError ? _C.error : _C.success,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      content: Row(children: [
        Icon(isError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
            color: Colors.white, size: 16),
        const SizedBox(width: 8),
        Text(msg, style: GoogleFonts.cairo(fontSize: 13, color: Colors.white)),
      ]),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _saveHistory(String path, int size) async {
    await HistoryService.addEntry(
      toolId: 'zip_compress', toolName: 'ضغط ZIP',
      inputFiles: _selected.map((e) => e.name).toList(),
      outputPath: path, outputSize: size,
    );
  }

  Future<void> _shareResult() async {
    if (_resultFile == null) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(_resultFile!.path)], text: 'ملف ZIP مضغوط'));
  }

  Future<void> _saveResult() async {
    if (_resultFile == null || !mounted) return;
    FileSaveService.showSaveDestinationSheet(
      context: context, subFolder: 'ZIP',
      onSave: (type) async {
        try {
          final dest = await FileSaveService.saveCopy(source: _resultFile!, type: type, subFolder: 'ZIP');
          if (mounted) FileSaveService.showSavedSnackBar(context, dest);
        } catch (e) {
          if (mounted) FileSaveService.showFailedSnackBar(context, e);
        }
      },
    );
  }

  void _reset({bool clearFiles = true}) {
    setState(() {
      _phase = _Phase.idle; _resultFile = null; _errorMsg = null;
      _currentFile = ''; _progress = 0; _wasEncrypted = false;
      if (clearFiles) _entries.clear();
    });
  }

  // ══════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _C.bg,
        body: Column(
          children: [
            // ── AppBar احترافي ──
            _AppHeader(
              phase: _phase,
              onBack: () => Navigator.pop(context),
              onReset: _phase == _Phase.done ? () => _reset(clearFiles: true) : null,
            ),

            // ── المحتوى ──
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 380),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween(begin: const Offset(0, 0.025), end: Offset.zero).animate(anim),
                    child: child,
                  ),
                ),
                child: switch (_phase) {
                  _Phase.compressing => _CompressingView(
                      key: const ValueKey('comp'),
                      progress: _progress, currentFile: _currentFile),
                  _Phase.done => _ResultView(
                      key: const ValueKey('done'),
                      resultFile: _resultFile!, originalSize: _originalTotal ?? 0,
                      resultSize: _resultSize ?? 0, wasEncrypted: _wasEncrypted,
                      successBounce: _successBounce,
                      onSave: _saveResult, onShare: _shareResult,
                      onNewArchive: () => _reset(clearFiles: true)),
                  _Phase.idle => _IdleView(
                      key: const ValueKey('idle'),
                      entries: _entries, listScroll: _listScroll,
                      nameCtrl: _nameCtrl, passwordCtrl: _passwordCtrl,
                      level: _level, encryptEnabled: _encryptEnabled,
                      passwordVisible: _passwordVisible,
                      selected: _selected, totalSelectedSize: _totalSelectedSize,
                      errorMsg: _errorMsg, pulseScale: _pulseScale,
                      onPickFiles: _pickFiles, onPickFolder: _pickFolder,
                      onRemove: _removeEntry,
                      onToggleEntry: (e, v) => setState(() => e.selected = v ?? true),
                      onToggleAll: _toggleAll,
                      onLevelChanged: (v) => setState(() => _level = v),
                      onEncryptToggled: (v) => setState(() => _encryptEnabled = v),
                      onPasswordVisToggled: () => setState(() => _passwordVisible = !_passwordVisible),
                      onStartCompress: _startCompress),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════
//  AppBar احترافي مع SafeArea
// ══════════════════════════════════════════════════════

class _AppHeader extends StatelessWidget {
  final _Phase phase;
  final VoidCallback onBack;
  final VoidCallback? onReset;
  const _AppHeader({required this.phase, required this.onBack, this.onReset});

  String get _title => switch (phase) {
    _Phase.idle        => 'ضغط الملفات',
    _Phase.compressing => 'جارٍ الضغط...',
    _Phase.done        => 'تم الضغط',
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _C.surface,
      child: SafeArea(
        bottom: false,
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: _C.border, width: 0.8)),
          ),
          child: Row(children: [
            // زر العودة
            _HeaderBtn(
              icon: Icons.arrow_back_ios_new_rounded,
              onTap: onBack,
            ),
            const SizedBox(width: 4),

            // الأيقونة + العنوان
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [_C.accent, _C.accentGlow],
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.folder_zip_rounded, color: Colors.white, size: 17),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  _title,
                  key: ValueKey(_title),
                  style: GoogleFonts.cairo(
                      fontSize: 16, fontWeight: FontWeight.w700, color: _C.textHigh),
                ),
              ),
            ),

            // زر التصفية / جديد
            if (onReset != null)
              TextButton(
                onPressed: onReset,
                style: TextButton.styleFrom(
                  foregroundColor: _C.accentSoft,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: Text('جديد', style: GoogleFonts.cairo(
                    fontSize: 13, fontWeight: FontWeight.w600)),
              )
            else
              const SizedBox(width: 44),
          ]),
        ),
      ),
    );
  }
}

class _HeaderBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _HeaderBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 44, height: 44,
        child: Icon(icon, color: _C.textHigh, size: 19),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════
//  واجهة Idle
// ══════════════════════════════════════════════════════

class _IdleView extends StatelessWidget {
  final List<_ZipEntry> entries;
  final ScrollController listScroll;
  final TextEditingController nameCtrl, passwordCtrl;
  final int level;
  final bool encryptEnabled, passwordVisible;
  final List<_ZipEntry> selected;
  final int totalSelectedSize;
  final String? errorMsg;
  final Animation<double> pulseScale;
  final VoidCallback onPickFiles, onPickFolder, onStartCompress, onPasswordVisToggled;
  final ValueChanged<_ZipEntry> onRemove;
  final void Function(_ZipEntry, bool?) onToggleEntry;
  final ValueChanged<bool> onToggleAll, onEncryptToggled;
  final ValueChanged<int> onLevelChanged;

  const _IdleView({
    super.key,
    required this.entries, required this.listScroll,
    required this.nameCtrl, required this.passwordCtrl,
    required this.level, required this.encryptEnabled, required this.passwordVisible,
    required this.selected, required this.totalSelectedSize,
    required this.errorMsg, required this.pulseScale,
    required this.onPickFiles, required this.onPickFolder,
    required this.onRemove, required this.onToggleEntry, required this.onToggleAll,
    required this.onLevelChanged, required this.onEncryptToggled,
    required this.onPasswordVisToggled, required this.onStartCompress,
  });

  @override
  Widget build(BuildContext context) {
    final hasFiles = entries.isNotEmpty;
    final allSelected = hasFiles && entries.every((e) => e.selected);

    return Column(children: [
      // ── شريط الإضافة ──
      Container(
        color: _C.surface,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(children: [
          Expanded(child: _AddBtn(
            icon: Icons.insert_drive_file_outlined,
            label: 'إضافة ملفات',
            onTap: onPickFiles,
          )),
          const SizedBox(width: 10),
          Expanded(child: _AddBtn(
            icon: Icons.create_new_folder_outlined,
            label: 'إضافة مجلد',
            onTap: onPickFolder,
            isSecondary: true,
          )),
        ]),
      ),

      // ── شريط الاختيار (عند وجود ملفات) ──
      if (hasFiles)
        _SelectionStrip(
          allSelected: allSelected,
          selectedCount: selected.length,
          totalSize: totalSelectedSize,
          onToggleAll: onToggleAll,
        ),

      // ── قائمة الملفات / حالة فارغة ──
      Expanded(
        child: hasFiles
            ? _FileList(entries: entries, listScroll: listScroll,
                onRemove: onRemove, onToggle: onToggleEntry)
            : _EmptyDrop(pulseScale: pulseScale,
                onPickFiles: onPickFiles, onPickFolder: onPickFolder),
      ),

      // ── لوحة الإعدادات + زر الضغط ──
      _BottomPanel(
        nameCtrl: nameCtrl, passwordCtrl: passwordCtrl,
        level: level, encryptEnabled: encryptEnabled,
        passwordVisible: passwordVisible,
        canCompress: selected.isNotEmpty,
        selectedCount: selected.length,
        errorMsg: errorMsg,
        onLevelChanged: onLevelChanged,
        onEncryptToggled: onEncryptToggled,
        onPasswordVisToggled: onPasswordVisToggled,
        onStartCompress: onStartCompress,
      ),
    ]);
  }
}

// ── زر إضافة (Pill style) ──
class _AddBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSecondary;
  final VoidCallback onTap;
  const _AddBtn({required this.icon, required this.label, required this.onTap, this.isSecondary = false});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 14),
          decoration: BoxDecoration(
            color: isSecondary ? _C.surfaceEl : _C.accent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSecondary ? _C.border : _C.accent.withValues(alpha: 0.35),
              width: 1,
            ),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 17,
                color: isSecondary ? _C.textMed : _C.accentSoft),
            const SizedBox(width: 7),
            Text(label, style: GoogleFonts.cairo(
              fontSize: 13, fontWeight: FontWeight.w600,
              color: isSecondary ? _C.textMed : _C.accentSoft,
            )),
          ]),
        ),
      ),
    );
  }
}

// ── شريط الاختيار ──
class _SelectionStrip extends StatelessWidget {
  final bool allSelected;
  final int selectedCount;
  final int totalSize;
  final ValueChanged<bool> onToggleAll;
  const _SelectionStrip({
    required this.allSelected, required this.selectedCount,
    required this.totalSize, required this.onToggleAll,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      color: _C.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        GestureDetector(
          onTap: () => onToggleAll(!allSelected),
          behavior: HitTestBehavior.opaque,
          child: Row(children: [
            SizedBox(width: 18, height: 18, child: Checkbox(
              value: allSelected, tristate: true,
              onChanged: (v) => onToggleAll(v ?? false),
              activeColor: _C.accent, checkColor: Colors.white,
              side: const BorderSide(color: _C.textLow, width: 1.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )),
            const SizedBox(width: 8),
            Text(allSelected ? 'إلغاء الكل' : 'تحديد الكل',
                style: GoogleFonts.cairo(fontSize: 12, color: _C.textMed)),
          ]),
        ),
        const Spacer(),
        if (selectedCount > 0)
          Text(
            '$selectedCount عنصر  •  ${_fmtBytes(totalSize)}',
            style: GoogleFonts.cairo(
                fontSize: 11, color: _C.accentSoft, fontWeight: FontWeight.w600),
          ),
      ]),
    );
  }
}

// ── حالة فارغة ──
class _EmptyDrop extends StatelessWidget {
  final Animation<double> pulseScale;
  final VoidCallback onPickFiles, onPickFolder;
  const _EmptyDrop({required this.pulseScale, required this.onPickFiles, required this.onPickFolder});

  @override
  Widget build(BuildContext context) {
    return Center(child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ScaleTransition(
          scale: pulseScale,
          child: Stack(alignment: Alignment.center, children: [
            Container(width: 120, height: 120, decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _C.accent.withValues(alpha: 0.04),
            )),
            Container(width: 88, height: 88, decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _C.accent.withValues(alpha: 0.08),
            )),
            Container(
              width: 60, height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [_C.surface, _C.surfaceEl],
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                ),
                border: Border.all(color: _C.accent.withValues(alpha: 0.28), width: 1.5),
              ),
              child: const Icon(Icons.folder_zip_rounded, size: 28, color: _C.accentSoft),
            ),
          ]),
        ),

        const SizedBox(height: 20),
        Text('لا توجد ملفات',
            style: GoogleFonts.cairo(
                fontSize: 18, fontWeight: FontWeight.w700, color: _C.textHigh)),
        const SizedBox(height: 6),
        Text('اختر الملفات أو المجلدات التي تريد ضغطها',
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(fontSize: 13, color: _C.textMed, height: 1.5)),

        const SizedBox(height: 28),
        // زرا الإضافة السريعة
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _QuickAddBtn(icon: Icons.insert_drive_file_outlined, label: 'ملفات', onTap: onPickFiles),
          const SizedBox(width: 12),
          _QuickAddBtn(icon: Icons.create_new_folder_outlined, label: 'مجلد', onTap: onPickFolder, filled: true),
        ]),
      ]),
    ));
  }
}

class _QuickAddBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback onTap;
  const _QuickAddBtn({required this.icon, required this.label, required this.onTap, this.filled = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: filled ? _C.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: filled ? _C.accent : _C.border, width: 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: filled ? Colors.white : _C.textMed),
          const SizedBox(width: 6),
          Text(label, style: GoogleFonts.cairo(
              fontSize: 13, fontWeight: FontWeight.w600,
              color: filled ? Colors.white : _C.textMed)),
        ]),
      ),
    );
  }
}

// ── قائمة الملفات ──
class _FileList extends StatelessWidget {
  final List<_ZipEntry> entries;
  final ScrollController listScroll;
  final ValueChanged<_ZipEntry> onRemove;
  final void Function(_ZipEntry, bool?) onToggle;
  const _FileList({required this.entries, required this.listScroll, required this.onRemove, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      controller: listScroll,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 1),
      itemBuilder: (_, i) => _FileTile(
        key: ValueKey(entries[i].id),
        entry: entries[i],
        onRemove: () => onRemove(entries[i]),
        onToggle: (v) => onToggle(entries[i], v),
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  final _ZipEntry entry;
  final VoidCallback onRemove;
  final ValueChanged<bool?> onToggle;
  const _FileTile({super.key, required this.entry, required this.onRemove, required this.onToggle});

  static IconData _iconFor(String name) {
    return switch (p.extension(name).toLowerCase()) {
      '.pdf'  => Icons.picture_as_pdf_rounded,
      '.jpg' || '.jpeg' || '.png' || '.gif' || '.webp' => Icons.image_outlined,
      '.mp4' || '.mov' || '.avi' => Icons.videocam_outlined,
      '.mp3' || '.wav' || '.aac' => Icons.audiotrack_outlined,
      '.doc' || '.docx' => Icons.description_outlined,
      '.xls' || '.xlsx' => Icons.table_chart_outlined,
      '.ppt' || '.pptx' => Icons.slideshow_outlined,
      '.zip' || '.rar' || '.7z' => Icons.folder_zip_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  @override
  Widget build(BuildContext context) {
    final isFolder = entry.isFolder;
    final color = isFolder ? _C.warn : _C.accentSoft;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: entry.selected ? _C.surface : _C.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: entry.selected ? _C.borderHi : _C.border,
          width: entry.selected ? 1 : 0.5,
        ),
      ),
      child: InkWell(
        onTap: () => onToggle(!entry.selected),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            // Checkbox
            SizedBox(width: 18, height: 18, child: Checkbox(
              value: entry.selected, onChanged: onToggle,
              activeColor: _C.accent, checkColor: Colors.white,
              side: const BorderSide(color: _C.textLow, width: 1.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )),
            const SizedBox(width: 10),

            // أيقونة نوع الملف
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(isFolder ? Icons.folder_rounded : _iconFor(entry.name),
                  size: 18, color: color),
            ),
            const SizedBox(width: 12),

            // الاسم والحجم
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.name,
                    style: GoogleFonts.cairo(fontSize: 13, fontWeight: FontWeight.w600, color: _C.textHigh),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 1),
                Text(
                  '${entry.displaySize}${isFolder ? '  •  مجلد' : ''}',
                  style: GoogleFonts.cairo(fontSize: 11, color: _C.textMed),
                ),
              ],
            )),

            // زر الحذف
            GestureDetector(
              onTap: onRemove,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close_rounded, size: 16, color: _C.textLow),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════
//  اللوحة السفلية — الإعدادات + الزر
// ══════════════════════════════════════════════════════

class _BottomPanel extends StatelessWidget {
  final TextEditingController nameCtrl, passwordCtrl;
  final int level;
  final bool encryptEnabled, passwordVisible, canCompress;
  final int selectedCount;
  final String? errorMsg;
  final ValueChanged<int> onLevelChanged;
  final ValueChanged<bool> onEncryptToggled;
  final VoidCallback onPasswordVisToggled, onStartCompress;

  const _BottomPanel({
    required this.nameCtrl, required this.passwordCtrl,
    required this.level, required this.encryptEnabled, required this.passwordVisible,
    required this.canCompress, required this.selectedCount, required this.errorMsg,
    required this.onLevelChanged, required this.onEncryptToggled,
    required this.onPasswordVisToggled, required this.onStartCompress,
  });

  static const _levels = [
    (label: 'بلا', value: 0, icon: Icons.bolt_outlined),
    (label: 'سريع', value: 1, icon: Icons.flash_on_outlined),
    (label: 'متوازن', value: 6, icon: Icons.tune_rounded),
    (label: 'أقصى', value: 9, icon: Icons.compress_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _C.surface,
        border: Border(top: BorderSide(color: _C.border, width: 0.8)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

            // ── صف: اسم + مستوى الضغط ──
            Row(children: [
              // حقل الاسم
              Expanded(
                flex: 5,
                child: _FieldWrap(
                  label: 'اسم الأرشيف',
                  child: TextField(
                    controller: nameCtrl,
                    style: GoogleFonts.cairo(fontSize: 13, color: _C.textHigh),
                    decoration: InputDecoration(
                      suffix: Text('.zip', style: GoogleFonts.cairo(
                          color: _C.textLow, fontSize: 12)),
                      hintText: 'archive',
                      hintStyle: GoogleFonts.cairo(fontSize: 13, color: _C.textLow),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                      filled: true,
                      fillColor: _C.bg,
                      border: _border(false),
                      enabledBorder: _border(false),
                      focusedBorder: _border(true),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),

              // مستوى الضغط
              Expanded(
                flex: 6,
                child: _FieldWrap(
                  label: 'مستوى الضغط',
                  child: Row(
                    children: _levels.map((lvl) {
                      final sel = lvl.value == level;
                      return Expanded(child: GestureDetector(
                        onTap: () => onLevelChanged(lvl.value),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          margin: const EdgeInsets.only(right: 3),
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          decoration: BoxDecoration(
                            color: sel ? _C.accent.withValues(alpha: 0.15) : _C.bg,
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(
                              color: sel ? _C.accent.withValues(alpha: 0.5) : _C.border,
                              width: sel ? 1 : 0.5,
                            ),
                          ),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Icon(lvl.icon, size: 12,
                                color: sel ? _C.accentSoft : _C.textLow),
                            const SizedBox(height: 2),
                            Text(lvl.label, style: GoogleFonts.cairo(
                                fontSize: 9,
                                color: sel ? _C.accentSoft : _C.textLow,
                                fontWeight: sel ? FontWeight.w700 : FontWeight.w400)),
                          ]),
                        ),
                      ));
                    }).toList(),
                  ),
                ),
              ),
            ]),

            const SizedBox(height: 10),

            // ── صف التشفير ──
            _EncryptRow(
              enabled: encryptEnabled, visible: passwordVisible,
              controller: passwordCtrl,
              onToggled: onEncryptToggled, onVisToggled: onPasswordVisToggled,
            ),

            // ── رسالة خطأ ──
            if (errorMsg != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: _C.errorBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _C.error.withValues(alpha: 0.4)),
                ),
                child: Row(children: [
                  const Icon(Icons.error_outline_rounded, color: _C.error, size: 14),
                  const SizedBox(width: 8),
                  Expanded(child: Text(errorMsg!, style: GoogleFonts.cairo(
                      fontSize: 11, color: _C.error))),
                ]),
              ),
            ],

            const SizedBox(height: 12),

            // ── زر الضغط الرئيسي ──
            SizedBox(
              width: double.infinity, height: 50,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  gradient: canCompress
                      ? const LinearGradient(
                          colors: [_C.accent, _C.accentGlow],
                          begin: Alignment.centerLeft, end: Alignment.centerRight)
                      : null,
                  color: canCompress ? null : _C.surfaceEl,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: canCompress ? [
                    BoxShadow(color: _C.accent.withValues(alpha: 0.3),
                        blurRadius: 16, offset: const Offset(0, 4)),
                  ] : [],
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: canCompress ? onStartCompress : null,
                    borderRadius: BorderRadius.circular(12),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(
                        canCompress ? Icons.folder_zip_rounded : Icons.add_circle_outline_rounded,
                        size: 18,
                        color: canCompress ? Colors.white : _C.textLow,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        canCompress
                            ? 'ضغط $selectedCount ${selectedCount == 1 ? 'عنصر' : 'عناصر'}'
                            : 'أضف ملفات للبدء',
                        style: GoogleFonts.cairo(
                          fontSize: 14, fontWeight: FontWeight.w700,
                          color: canCompress ? Colors.white : _C.textLow,
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  OutlineInputBorder _border(bool focused) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(9),
    borderSide: BorderSide(
      color: focused ? _C.accent.withValues(alpha: 0.6) : _C.border,
      width: focused ? 1 : 0.5,
    ),
  );
}

class _FieldWrap extends StatelessWidget {
  final String label;
  final Widget child;
  const _FieldWrap({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: GoogleFonts.cairo(fontSize: 10, color: _C.textMed)),
      const SizedBox(height: 4),
      child,
    ]);
  }
}

// ── صف التشفير ──
class _EncryptRow extends StatelessWidget {
  final bool enabled, visible;
  final TextEditingController controller;
  final ValueChanged<bool> onToggled;
  final VoidCallback onVisToggled;
  const _EncryptRow({
    required this.enabled, required this.visible,
    required this.controller, required this.onToggled, required this.onVisToggled,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // شريط التشفير
        GestureDetector(
          onTap: () => onToggled(!enabled),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: enabled ? _C.crypto.withValues(alpha: 0.08) : _C.bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: enabled ? _C.crypto.withValues(alpha: 0.4) : _C.border,
                width: enabled ? 1 : 0.5,
              ),
            ),
            child: Row(children: [
              Icon(
                enabled ? Icons.lock_rounded : Icons.lock_open_outlined,
                size: 16,
                color: enabled ? _C.cryptoSoft : _C.textMed,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  enabled ? 'التشفير مفعّل' : 'تشفير بكلمة مرور',
                  style: GoogleFonts.cairo(
                      fontSize: 13, fontWeight: FontWeight.w600,
                      color: enabled ? _C.cryptoSoft : _C.textMed),
                ),
              ),
              // مفتاح التبديل
              _Toggle(value: enabled, onChanged: onToggled, color: _C.crypto),
            ]),
          ),
        ),

        // حقل كلمة المرور
        if (enabled) ...[
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            obscureText: !visible,
            style: GoogleFonts.cairo(fontSize: 13, color: _C.textHigh),
            decoration: InputDecoration(
              hintText: 'كلمة المرور...',
              hintStyle: GoogleFonts.cairo(fontSize: 13, color: _C.textLow),
              prefixIcon: const Icon(Icons.vpn_key_rounded, size: 15, color: _C.cryptoSoft),
              suffixIcon: IconButton(
                icon: Icon(
                    visible ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                    size: 17, color: _C.textMed),
                onPressed: onVisToggled,
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              filled: true,
              fillColor: _C.bg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: BorderSide(color: _C.crypto.withValues(alpha: 0.3)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: BorderSide(color: _C.crypto.withValues(alpha: 0.3)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: const BorderSide(color: _C.cryptoSoft),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Row(children: [
            const Icon(Icons.info_outline_rounded, size: 11, color: _C.textLow),
            const SizedBox(width: 4),
            Text('احتفظ بكلمة المرور — لا يمكن استرجاعها',
                style: GoogleFonts.cairo(fontSize: 10, color: _C.textLow)),
          ]),
        ],
      ]),
    );
  }
}

/// مفتاح تبديل مخصص
class _Toggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final Color color;
  const _Toggle({required this.value, required this.onChanged, required this.color});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        width: 42, height: 23,
        decoration: BoxDecoration(
          color: value ? color : _C.surfaceEl,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: value ? color.withValues(alpha: 0.5) : _C.border, width: 0.5),
        ),
        child: Stack(children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            left: value ? 20 : 1, top: 1,
            child: Container(
              width: 21, height: 21,
              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
            ),
          ),
        ]),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════
//  شاشة التقدم (Compressing)
// ══════════════════════════════════════════════════════

class _CompressingView extends StatelessWidget {
  final double progress;
  final String currentFile;
  const _CompressingView({super.key, required this.progress, required this.currentFile});

  @override
  Widget build(BuildContext context) {
    final pct = (progress * 100).clamp(0, 100).toInt();

    return Center(child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(mainAxisSize: MainAxisSize.min, children: [

        // مؤشر دائري
        SizedBox(width: 140, height: 140, child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(width: 140, height: 140, child: CircularProgressIndicator(
              value: 1, strokeWidth: 5,
              color: _C.accent.withValues(alpha: 0.08),
            )),
            SizedBox(width: 140, height: 140, child: CircularProgressIndicator(
              value: progress, strokeWidth: 5,
              strokeCap: StrokeCap.round, color: _C.accent,
              backgroundColor: Colors.transparent,
            )),
            Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.folder_zip_rounded, size: 24, color: _C.accentSoft),
              const SizedBox(height: 4),
              Text('$pct%', style: GoogleFonts.cairo(
                  fontSize: 22, fontWeight: FontWeight.w800, color: _C.textHigh)),
            ]),
          ],
        )),

        const SizedBox(height: 32),
        Text('جارٍ ضغط الملفات',
            style: GoogleFonts.cairo(
                fontSize: 19, fontWeight: FontWeight.w700, color: _C.textHigh)),
        const SizedBox(height: 8),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Text(
            currentFile.isEmpty ? 'جارٍ التهيئة...' : currentFile,
            key: ValueKey(currentFile),
            textAlign: TextAlign.center, maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.cairo(fontSize: 12, color: _C.textMed),
          ),
        ),
        const SizedBox(height: 24),
        // شريط تقدم خطي
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress, minHeight: 4,
            color: _C.accent, backgroundColor: _C.accent.withValues(alpha: 0.1),
          ),
        ),
        const SizedBox(height: 16),
        Text('لا تغلق التطبيق أثناء المعالجة',
            style: GoogleFonts.cairo(fontSize: 11, color: _C.textLow)),
      ]),
    ));
  }
}

// ══════════════════════════════════════════════════════
//  شاشة النتيجة (Done)
// ══════════════════════════════════════════════════════

class _ResultView extends StatelessWidget {
  final File resultFile;
  final int originalSize, resultSize;
  final bool wasEncrypted;
  final Animation<double> successBounce;
  final VoidCallback onSave, onShare, onNewArchive;

  const _ResultView({
    super.key,
    required this.resultFile, required this.originalSize, required this.resultSize,
    required this.wasEncrypted, required this.successBounce,
    required this.onSave, required this.onShare, required this.onNewArchive,
  });

  double get _saving {
    if (originalSize <= 0) return 0;
    return ((originalSize - resultSize) / originalSize * 100).clamp(0, 100);
  }

  @override
  Widget build(BuildContext context) {
    final saving  = _saving;
    final hasSave = saving > 0.5;

    return Column(children: [
      Expanded(child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          const SizedBox(height: 16),

          // ── أيقونة النجاح ──
          ScaleTransition(scale: successBounce, child: Stack(
            alignment: Alignment.center,
            children: [
              Container(width: 130, height: 130, decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _C.success.withValues(alpha: 0.06),
              )),
              Container(width: 88, height: 88, decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _C.successBg,
                border: Border.all(color: _C.success.withValues(alpha: 0.3), width: 1.5),
              ), child: const Icon(Icons.check_rounded, size: 42, color: _C.success)),
            ],
          )),

          const SizedBox(height: 20),
          Text('تم إنشاء الأرشيف',
              style: GoogleFonts.cairo(
                  fontSize: 20, fontWeight: FontWeight.w800, color: _C.textHigh)),
          const SizedBox(height: 6),

          // شارة التشفير
          if (wasEncrypted)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: _C.crypto.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _C.crypto.withValues(alpha: 0.4)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.lock_rounded, size: 12, color: _C.cryptoSoft),
                const SizedBox(width: 5),
                Text('محمي بكلمة مرور', style: GoogleFonts.cairo(
                    fontSize: 11, fontWeight: FontWeight.w600, color: _C.cryptoSoft)),
              ]),
            )
          else
            Text('جاهز للحفظ أو المشاركة',
                style: GoogleFonts.cairo(fontSize: 13, color: _C.textMed)),

          const SizedBox(height: 24),

          // ── بطاقات الإحصاء ──
          Row(children: [
            _StatTile(
              label: 'الحجم الأصلي',
              value: _fmtBytes(originalSize),
              icon: Icons.folder_outlined,
              color: _C.textMed,
            ),
            const SizedBox(width: 8),
            _StatTile(
              label: 'بعد الضغط',
              value: _fmtBytes(resultSize),
              icon: Icons.folder_zip_outlined,
              color: _C.accentSoft,
            ),
            if (hasSave) ...[
              const SizedBox(width: 8),
              _StatTile(
                label: 'توفير',
                value: '${saving.toStringAsFixed(1)}%',
                icon: Icons.trending_down_rounded,
                color: _C.success,
              ),
            ],
          ]),

          const SizedBox(height: 14),

          // ── بطاقة الملف ──
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _C.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _C.border),
            ),
            child: Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: _C.accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.folder_zip_rounded, color: _C.accentSoft, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.basename(resultFile.path),
                      style: GoogleFonts.cairo(fontSize: 13, fontWeight: FontWeight.w600, color: _C.textHigh),
                      overflow: TextOverflow.ellipsis),
                  Text(_fmtBytes(resultSize),
                      style: GoogleFonts.cairo(fontSize: 11, color: _C.textMed)),
                ],
              )),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _C.success.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text('ZIP', style: GoogleFonts.cairo(
                    fontSize: 10, fontWeight: FontWeight.w800, color: _C.success)),
              ),
            ]),
          ),
        ]),
      )),

      // ── أزرار الإجراءات ──
      Container(
        decoration: const BoxDecoration(
          color: _C.surface,
          border: Border(top: BorderSide(color: _C.border, width: 0.8)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(children: [
              // حفظ + مشاركة
              Row(children: [
                Expanded(child: _OutlineBtn(
                  icon: Icons.save_alt_rounded, label: 'حفظ', onTap: onSave)),
                const SizedBox(width: 10),
                Expanded(child: _OutlineBtn(
                  icon: Icons.share_rounded, label: 'مشاركة', onTap: onShare)),
              ]),
              const SizedBox(height: 10),

              // زر أرشيف جديد
              SizedBox(
                width: double.infinity, height: 48,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [_C.accent, _C.accentGlow],
                      begin: Alignment.centerLeft, end: Alignment.centerRight,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [BoxShadow(
                      color: _C.accent.withValues(alpha: 0.28),
                      blurRadius: 14, offset: const Offset(0, 4),
                    )],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: onNewArchive,
                      borderRadius: BorderRadius.circular(12),
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const Icon(Icons.add_rounded, size: 18, color: Colors.white),
                        const SizedBox(width: 8),
                        Text('أرشيف جديد', style: GoogleFonts.cairo(
                            fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
                      ]),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    ]);
  }
}

class _StatTile extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  const _StatTile({required this.label, required this.value, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(child: Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Column(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(height: 5),
        Text(value, style: GoogleFonts.cairo(
            fontSize: 12, fontWeight: FontWeight.w800, color: color)),
        const SizedBox(height: 2),
        Text(label, textAlign: TextAlign.center,
            style: GoogleFonts.cairo(fontSize: 9.5, color: _C.textMed)),
      ]),
    ));
  }
}

class _OutlineBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _OutlineBtn({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: _C.surfaceEl,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _C.borderHi),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 16, color: _C.textMed),
            const SizedBox(width: 7),
            Text(label, style: GoogleFonts.cairo(
                fontSize: 13, fontWeight: FontWeight.w600, color: _C.textMed)),
          ]),
        ),
      ),
    );
  }
}
