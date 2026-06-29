import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import '../services/history_service.dart';
import '../theme/app_theme.dart';

/// بيانات وصفية ثابتة عن أداة واحدة — تُستخدم لعرض الاسم/الأيقونة/اللون
/// الصحيحين في سجل الأعمال، بحسب toolId الفعلي المُسجَّل من كل أداة.
class _ToolMeta {
  final String name;
  final IconData icon;
  final Color color;
  const _ToolMeta(this.name, this.icon, this.color);
}

/// ⚠️ تعميم حقيقي شامل: كانت بيانات الأدوات (الاسم في _tools، اللون في
/// _toolColor، والأيقونة الثابتة Icons.picture_as_pdf_rounded في
/// _HistoryCard) تغطي فقط جزءاً صغيراً من أدوات التطبيق الفعلية. أي أداة
/// غير مذكورة كانت تظهر بأيقونة PDF حمراء عامة بصرف النظر عن نوعها
/// الحقيقي (حتى لو كانت صورة لا PDF أصلاً)، وبلا أي تصنيف لون خاص بها،
/// وبلا فلتر تصفية مستقل. هذه الخريطة الموحَّدة (مفتاحها toolId الفعلي
/// المُسجَّل في HistoryService من كل أداة) تغطي الآن كل أداة في التطبيق
/// بما فيها أدوات التحويل الكبيرة (Word/Excel/PPT/HTML/نص)، فتتطابق
/// بيانات السجل مع بيانات بطاقة الأداة في الشاشة الرئيسية لكل أداة دون
/// استثناء.
const Map<String, _ToolMeta> _toolMeta = {
  'img_to_pdf':      _ToolMeta('صورة إلى PDF', Icons.image_rounded, Color(0xFF6C63FF)),
  'word_to_pdf':     _ToolMeta('Word إلى PDF', Icons.description_rounded, Color(0xFF2B6CB0)),
  'excel_to_pdf':    _ToolMeta('Excel إلى PDF', Icons.table_chart_rounded, Color(0xFF276749)),
  'ppt_to_pdf':      _ToolMeta('PPT إلى PDF', Icons.slideshow_rounded, Color(0xFFC05621)),
  'html_to_pdf':     _ToolMeta('HTML إلى PDF', Icons.code_rounded, Color(0xFF4A5568)),
  'txt_to_pdf':      _ToolMeta('نص إلى PDF', Icons.text_snippet_rounded, Color(0xFF553C9A)),
  'merge_pdf':       _ToolMeta('دمج PDF', Icons.merge_rounded, Color(0xFF9B2C2C)),
  'compress_pdf':    _ToolMeta('ضغط PDF', Icons.compress_rounded, Color(0xFF744210)),
  'split_pdf':       _ToolMeta('تقسيم PDF', Icons.call_split_rounded, Color(0xFF322659)),
  'crop_pdf':        _ToolMeta('قص PDF', Icons.crop_rounded, Color(0xFF2C5282)),
  'rotate_pdf':      _ToolMeta('تدوير PDF', Icons.rotate_right_rounded, Color(0xFF1D4044)),
  'compress_image':  _ToolMeta('ضغط الصور', Icons.photo_size_select_small_rounded, Color(0xFF234E52)),
  'image_enhance':   _ToolMeta('تحسين دقة الصور', Icons.auto_fix_high_rounded, Color(0xFF1A365D)),
  'delete_pages':    _ToolMeta('حذف صفحات PDF', Icons.delete_sweep_rounded, Color(0xFF285E61)),
  'watermark':       _ToolMeta('علامة مائية', Icons.water_drop_rounded, Color(0xFF234E52)),
  'protect_pdf':     _ToolMeta('حماية PDF', Icons.lock_rounded, Color(0xFF702459)),
  'sign_pdf':        _ToolMeta('توقيع PDF', Icons.draw_rounded, Color(0xFF2D3748)),
};

/// عنصر افتراضي لأي toolId غير متوقَّع أو قديم (إصدار سابق من
/// التطبيق) — أيقونة عامة محايدة بدل افتراض PDF دوماً.
const _ToolMeta _fallbackToolMeta = _ToolMeta('أداة أخرى', Icons.insert_drive_file_rounded, AppTheme.primary);

class HistoryScreen extends StatefulWidget {
  /// ⚠️ إصلاح خلل حقيقي (انهيار عند الضغط على "رجوع"): هذه الشاشة لا
  /// تُستدعى عبر Navigator.push إطلاقاً — هي دوماً تبويب ثابت ضمن
  /// IndexedStack في HomeScreen (راجع home_screen.dart)، فلا يوجد أي
  /// مسار (route) فعلي لتُغلَق عودة إليه. استدعاء Navigator.pop(context)
  /// مباشرة هنا كان يفترض وجود مسار سابق على المكدّس بصرف النظر عن واقع
  /// الاستخدام الفعلي، فيفشل أو يتسبب بحالة تنقّل غير متوقَّعة عندما تكون
  /// هذه الشاشة هي الجذر الفعلي المعروض (لا يوجد شيء تحتها على المكدّس).
  /// الإصلاح: onBack اختياري يُستدعى بدل Navigator.pop مباشرة — HomeScreen
  /// يُمرِّر دالة تُبدِّل التبويب النشط بدل أي تنقّل فعلي على المكدّس. إن
  /// استُخدمت هذه الشاشة لاحقاً بشكل مستقل (push حقيقي)، يبقى السلوك
  /// الافتراضي (onBack == null) آمناً عبر Navigator.maybePop الذي يتحقق
  /// أولاً من إمكانية الإغلاق قبل أي محاولة فعلية.
  final VoidCallback? onBack;
  const HistoryScreen({super.key, this.onBack});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<HistoryItem> _items = [];
  bool _isLoading = true;
  String _filterTool = 'الكل';

  // ⚠️ تعميم حقيقي: كانت هذه القائمة تحتوي 6 أدوات فقط (نص ثابت مطابق
  // لـ toolName) من إجمالي أكثر من 15 أداة فعلية في التطبيق — أي أداة
  // غائبة عن هذه القائمة (Word/Excel/PPT/HTML/نص إلى PDF، تدوير PDF،
  // حذف الصفحات، ضغط/تحسين الصور، توقيع PDF...) لم يكن لها أي رقاقة
  // فلترة خاصة بها (تظهر فقط ضمن "الكل"، بلا إمكانية تصفية مستقلة).
  // الآن تُستخرَج القائمة تلقائياً من _toolMeta (مصدر معرفة واحد لكل
  // أدوات التطبيق المعروفة)، مع إضافة أي اسم أداة ظاهر فعلياً في السجل
  // الحالي ولا يطابق أي toolId معروف (سجلات من إصدار تطبيق أقدم مثلاً)
  // بدل إسقاطه بصمت من قائمة الفلاتر.
  List<String> get _tools {
    final known = _toolMeta.values.map((m) => m.name).toSet();
    final fromHistory = _items.map(_displayNameFor).toSet();
    return ['الكل', ...known.union(fromHistory)];
  }

  // ⚠️ إصلاح: أُزيل TabController/SingleTickerProviderStateMixin كلياً —
  // كانا يُنشآن وتُتلَفان بشكل صحيح لكنهما لم يُستخدما إطلاقاً (لا TabBar
  // ولا TabBarView في الشجرة). حالة ميتة بالكامل، تُزيل تكلفة إنشاء/تفكيك
  // بلا أي فائدة.

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() => _isLoading = true);
    final items = await HistoryService.getAll();
    if (mounted) setState(() { _items = items; _isLoading = false; });
  }

  /// الاسم المعياري المعروض لعنصر سجل — من _toolMeta حسب toolId الفعلي،
  /// مع رجوع آمن إلى toolName الخام المُخزَّن إن كان toolId غير معروف
  /// (مثلاً سجل قديم من أداة أُزيلت لاحقاً) بدل تسمية كل شيء "أداة أخرى".
  String _displayNameFor(HistoryItem item) => _toolMeta[item.toolId]?.name ?? (item.toolName.isNotEmpty ? item.toolName : _fallbackToolMeta.name);

  List<HistoryItem> get _filtered {
    if (_filterTool == 'الكل') return _items;
    return _items.where((e) => _displayNameFor(e) == _filterTool).toList();
  }

  Future<void> _deleteItem(HistoryItem item) async {
    // ⚠️ إصلاح تناسق UX: الحذف الفردي كان يُنفَّذ فوراً بلا أي تأكيد، رغم
    // أن "مسح الكل" (_clearAll) كان يطلب تأكيداً صريحاً. حذف سجل واحد
    // أقل خطورة لكنه لا يزال إجراءً لا يمكن التراجع عنه — نفس نمط
    // التأكيد الآن مطبَّق على الاثنين بشكل متناسق.
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.bgCardLight,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('حذف هذا السجل', style: GoogleFonts.cairo(color: AppTheme.textPrimary, fontWeight: FontWeight.w800)),
        content: Text('هل تريد حذف "${item.fileName}" من السجل؟ (لن يُحذف الملف نفسه من الجهاز)', style: GoogleFonts.cairo(color: AppTheme.textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('إلغاء', style: GoogleFonts.cairo(color: AppTheme.textMuted))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text('حذف', style: GoogleFonts.cairo(color: Colors.red, fontWeight: FontWeight.w700))),
        ],
      ),
    );
    if (confirm != true) return;

    await HistoryService.remove(item.id);
    await _loadHistory();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('تم حذف السجل', style: GoogleFonts.cairo()),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.red.shade700,
      ));
    }
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.bgCardLight,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('مسح كل السجلات', style: GoogleFonts.cairo(color: AppTheme.textPrimary, fontWeight: FontWeight.w800)),
        content: Text('هل تريد حذف جميع سجلات العمل؟ لا يمكن التراجع عن هذا الإجراء.', style: GoogleFonts.cairo(color: AppTheme.textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('إلغاء', style: GoogleFonts.cairo(color: AppTheme.textMuted))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text('حذف الكل', style: GoogleFonts.cairo(color: Colors.red, fontWeight: FontWeight.w700))),
        ],
      ),
    );
    if (confirm == true) {
      await HistoryService.clearAll();
      await _loadHistory();
    }
  }

  Future<void> _shareItem(HistoryItem item, Rect originRect) async {
    // ⚠️ إصلاح: Share.shareXFiles مُهمَل (deprecated) في share_plus
    // 12.0.0 لصالح SharePlus.instance.share(ShareParams(...)) — كان
    // الكود القديم يُخفي هذا التحذير عبر "// ignore: deprecated_member_use"
    // بدل إصلاحه فعلياً. sharePositionOrigin إلزامي عملياً على iOS لتفادي
    // عطل حقيقي معروف عند تركه صفراً/فارغاً.
    await SharePlus.instance.share(
      ShareParams(files: [XFile(item.filePath)], sharePositionOrigin: originRect),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppTheme.bgDark : const Color(0xFFF5F5FF),
      body: Container(
        decoration: BoxDecoration(
          gradient: isDark ? AppTheme.bgGradient : const LinearGradient(colors: [Color(0xFFF5F5FF), Color(0xFFEEEEFF)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
        ),
        child: SafeArea(
          child: Column(children: [
            _buildHeader(isDark),
            _buildFilterChips(isDark),
            Expanded(child: _isLoading ? _buildLoading() : _filtered.isEmpty ? _buildEmpty(isDark) : _buildList(isDark)),
          ]),
        ),
      ),
    );
  }

  Widget _buildHeader(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(children: [
        Semantics(
          button: true,
          label: 'رجوع',
          child: GestureDetector(
            onTap: () {
              if (widget.onBack != null) {
                widget.onBack!();
              } else {
                Navigator.maybePop(context);
              }
            },
            child: Container(
              width: 42, height: 42,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: isDark ? AppTheme.bgCardLight : Colors.white, border: Border.all(color: AppTheme.divider)),
              child: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: AppTheme.textSecondary),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('سجل الأعمال', style: GoogleFonts.cairo(fontSize: 20, fontWeight: FontWeight.w800, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
          Text('${_items.length} عملية محفوظة', style: GoogleFonts.cairo(fontSize: 12, color: AppTheme.textMuted)),
        ])),
        if (_items.isNotEmpty)
          Semantics(
            button: true,
            label: 'مسح كل السجلات',
            child: GestureDetector(
              onTap: _clearAll,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: Colors.red.withValues(alpha: 0.1)),
                child: Text('مسح الكل', style: GoogleFonts.cairo(fontSize: 12, color: Colors.red, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _buildFilterChips(bool isDark) {
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
        itemCount: _tools.length,
        itemBuilder: (_, i) {
          final selected = _filterTool == _tools[i];
          return GestureDetector(
            onTap: () { HapticFeedback.selectionClick(); setState(() => _filterTool = _tools[i]); },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(50),
                gradient: selected ? AppTheme.primaryGradient : null,
                color: selected ? null : isDark ? AppTheme.bgCardLight : Colors.white,
                border: selected ? null : Border.all(color: AppTheme.divider),
              ),
              child: Text(_tools[i], style: GoogleFonts.cairo(fontSize: 12, fontWeight: FontWeight.w600, color: selected ? Colors.white : AppTheme.textSecondary)),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLoading() => const Center(child: CircularProgressIndicator(color: AppTheme.primary));

  Widget _buildEmpty(bool isDark) {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          width: 110, height: 110,
          decoration: BoxDecoration(shape: BoxShape.circle, color: isDark ? AppTheme.bgCardLight : Colors.white, border: Border.all(color: AppTheme.divider, width: 2)),
          child: Icon(Icons.history_rounded, size: 48, color: AppTheme.textMuted.withValues(alpha: 0.5)),
        ),
        const SizedBox(height: 20),
        Text('لا يوجد سجل أعمال بعد', style: GoogleFonts.cairo(fontSize: 18, fontWeight: FontWeight.w700, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
        const SizedBox(height: 8),
        Text('ستظهر هنا جميع الملفات التي أنشأتها\nأو عدّلتها باستخدام أدوات التطبيق', textAlign: TextAlign.center, style: GoogleFonts.cairo(fontSize: 13, color: AppTheme.textSecondary, height: 1.6)),
      ]),
    );
  }

  Widget _buildList(bool isDark) {
    final grouped = <String, List<HistoryItem>>{};
    for (final item in _filtered) {
      final key = _groupKey(item.createdAt);
      grouped.putIfAbsent(key, () => []).add(item);
    }
    final keys = grouped.keys.toList();

    return RefreshIndicator(
      onRefresh: _loadHistory,
      color: AppTheme.primary,
      child: ListView.builder(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        itemCount: keys.length,
        itemBuilder: (_, gi) {
          final groupItems = grouped[keys[gi]]!;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _GroupLabel(label: keys[gi], isDark: isDark),
            ...groupItems.map((item) => _HistoryCard(
              item: item,
              isDark: isDark,
              onDelete: () => _deleteItem(item),
              onOpen: () => OpenFilex.open(item.filePath),
              onShare: (rect) => _shareItem(item, rect),
            )),
          ]);
        },
      ),
    );
  }

  String _groupKey(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final itemDay = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(itemDay).inDays;
    if (diff == 0) return 'اليوم';
    if (diff == 1) return 'الأمس';
    if (diff < 7) return 'هذا الأسبوع';
    if (diff < 30) return 'هذا الشهر';
    return 'أقدم';
  }
}

class _GroupLabel extends StatelessWidget {
  final String label;
  final bool isDark;
  const _GroupLabel({required this.label, required this.isDark});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10, top: 16),
    child: Row(children: [
      Container(width: 3, height: 16, decoration: BoxDecoration(borderRadius: BorderRadius.circular(2), gradient: AppTheme.primaryGradient)),
      const SizedBox(width: 8),
      Text(label, style: GoogleFonts.cairo(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.primaryLight)),
    ]),
  );
}

class _HistoryCard extends StatefulWidget {
  final HistoryItem item;
  final bool isDark;
  final VoidCallback onDelete;
  final VoidCallback onOpen;
  final void Function(Rect originRect) onShare;
  const _HistoryCard({required this.item, required this.isDark, required this.onDelete, required this.onOpen, required this.onShare});

  @override
  State<_HistoryCard> createState() => _HistoryCardState();
}

class _HistoryCardState extends State<_HistoryCard> {
  bool _expanded = false;
  bool _fileExists = false;
  final GlobalKey _shareKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _checkFile();
  }

  void _checkFile() {
    setState(() => _fileExists = File(widget.item.filePath).existsSync());
  }

  // ⚠️ تعميم حقيقي: كانت _toolColor تغطي 6 toolId فقط، وكانت أيقونة كل
  // عنصر سجل (انظر الأسفل) ثابتة Icons.picture_as_pdf_rounded بصرف
  // النظر عن نوع الأداة الفعلي — حتى لأدوات تُنتج صوراً لا ملفات PDF
  // أصلاً (ضغط/تحسين الصور). الآن نستخدم _toolMeta الموحَّدة لكل من
  // اللون والأيقونة معاً، فتطابق كل أداة بياناتها الحقيقية من بطاقتها
  // في الشاشة الرئيسية.
  _ToolMeta get _meta => _toolMeta[widget.item.toolId] ?? _fallbackToolMeta;
  Color get _toolColor => _meta.color;

  void _handleShareTap() {
    // ⚠️ مطلوب لـ SharePlus.instance.share على iOS/iPad — sharePositionOrigin
    // غير صفري يمنع عطلاً معروفاً عند فتح ورقة المشاركة. نحسبه من موضع
    // زر "مشاركة" نفسه بدل قيمة افتراضية عشوائية.
    final box = _shareKey.currentContext?.findRenderObject() as RenderBox?;
    final origin = box != null
        ? box.localToGlobal(Offset.zero) & box.size
        : const Rect.fromLTWH(0, 0, 1, 1);
    widget.onShare(origin);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final isDark = widget.isDark;

    return GestureDetector(
      onTap: () { HapticFeedback.selectionClick(); setState(() => _expanded = !_expanded); },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: isDark ? AppTheme.bgCardLight : Colors.white,
          border: Border.all(color: _expanded ? _toolColor.withValues(alpha: 0.4) : AppTheme.divider.withValues(alpha: 0.5), width: _expanded ? 1.5 : 1),
          boxShadow: _expanded ? [BoxShadow(color: _toolColor.withValues(alpha: 0.1), blurRadius: 16)] : [],
        ),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Container(
                width: 46, height: 46,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(13), color: _toolColor.withValues(alpha: 0.12)),
                child: Icon(_meta.icon, color: _toolColor, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item.fileName, style: GoogleFonts.cairo(fontSize: 14, fontWeight: FontWeight.w700, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E)), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Row(children: [
                  Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), color: _toolColor.withValues(alpha: 0.1)), child: Text(_toolMeta[item.toolId]?.name ?? (item.toolName.isNotEmpty ? item.toolName : _meta.name), style: GoogleFonts.cairo(fontSize: 10, color: _toolColor, fontWeight: FontWeight.w700))),
                  const SizedBox(width: 8),
                  Text('${item.formattedSize} • ${item.formattedDate}', style: GoogleFonts.cairo(fontSize: 11, color: AppTheme.textMuted)),
                ]),
              ])),
              Row(mainAxisSize: MainAxisSize.min, children: [
                if (!_fileExists)
                  const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 16),
                const SizedBox(width: 4),
                AnimatedRotation(turns: _expanded ? 0.5 : 0, duration: const Duration(milliseconds: 250), child: const Icon(Icons.keyboard_arrow_down_rounded, color: AppTheme.textMuted)),
              ]),
            ]),
          ),
          if (_expanded) ...[
            Divider(color: AppTheme.divider.withValues(alpha: 0.5), height: 1),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (!_fileExists)
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: Colors.orange.withValues(alpha: 0.1), border: Border.all(color: Colors.orange.withValues(alpha: 0.3))),
                    child: Row(children: [const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 16), const SizedBox(width: 8), Expanded(child: Text('الملف لم يعد موجوداً في هذا المسار', style: GoogleFonts.cairo(fontSize: 12, color: Colors.orange)))]),
                  ),
                // Settings chips
                if (item.settings.isNotEmpty) ...[
                  Wrap(spacing: 8, runSpacing: 6, children: item.settings.entries.map((e) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), color: AppTheme.primary.withValues(alpha: 0.08)),
                    child: Text('${e.key}: ${e.value}', style: GoogleFonts.cairo(fontSize: 11, color: AppTheme.primaryLight)),
                  )).toList()),
                  const SizedBox(height: 12),
                ],
                // Action buttons
                Row(children: [
                  if (_fileExists) ...[
                    _ActionChip(label: 'فتح', icon: Icons.open_in_new_rounded, color: AppTheme.primary, onTap: widget.onOpen),
                    const SizedBox(width: 8),
                    _ActionChip(key: _shareKey, label: 'مشاركة', icon: Icons.share_rounded, color: AppTheme.accent, onTap: _handleShareTap),
                    const SizedBox(width: 8),
                  ],
                  _ActionChip(label: 'حذف', icon: Icons.delete_outline_rounded, color: Colors.red, onTap: widget.onDelete),
                ]),
              ]),
            ),
          ],
        ]),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _ActionChip({super.key, required this.label, required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: color.withValues(alpha: 0.1), border: Border.all(color: color.withValues(alpha: 0.25))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(label, style: GoogleFonts.cairo(fontSize: 12, color: color, fontWeight: FontWeight.w700)),
        ]),
      ),
    ),
  );
}
