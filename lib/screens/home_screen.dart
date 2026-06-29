import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_theme.dart';
import '../widgets/tool_card.dart';
import 'tools/image_to_pdf_screen.dart';
import 'tools/merge_pdf_screen.dart';
import 'tools/compress_pdf_screen.dart';
import 'tools/split_pdf_screen.dart';
import 'tools/watermark_pdf_screen.dart';
import 'tools/protect_pdf_screen.dart';
import 'tools/coming_soon_screen.dart';
import 'tools/excel_to_pdf_screen.dart';
import 'tools/html_to_pdf_screen.dart';
import 'tools/ppt_to_pdf_screen.dart';
import 'tools/compress_image_screen.dart';
import 'tools/zip_compress_screen.dart';
import 'tools/rotate_pdf_screen.dart';
import 'tools/sign_pdf_screen.dart';
import 'tools/delete_pages_screen.dart';
import 'tools/txt_to_pdf_screen.dart';
import 'tools/word_to_pdf_screen.dart';
import 'tools/text_recognition_screen.dart';
import 'settings_screen.dart';
import 'history_screen.dart';

// ═══════════════════════════════════════════════════════════════
//  HomeScreen — PDF Master  (rewritten: modern global style)
//  Design: glassmorphic cards · vibrant category sidebar
//  UX lifts: search bar · tap targets · visual hierarchy
// ═══════════════════════════════════════════════════════════════

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  late AnimationController _staggerCtrl;
  final ScrollController _scrollCtrl = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();

  int _selectedCategory = 0;
  int _bottomNavIndex = 0;
  String _searchQuery = '';

  // ── Palette ──────────────────────────────────────────────────
  static const Color _navy     = Color(0xFF0A0E27);
  static const Color _navyCard = Color(0xFF111630);
  static const Color _indigo   = Color(0xFF4F46E5);
  static const Color _indigoLt = Color(0xFF818CF8);
  static const Color _cyan     = Color(0xFF06B6D4);
  static const Color _pearl    = Color(0xFFF8FAFC);
  static const Color _muted    = Color(0xFF64748B);
  static const Color _divider  = Color(0xFF1E2A45);

  // ── Category definitions (icon + accent per category) ───────
  final List<_Category> _categories = const [
    _Category(label: 'الكل',    icon: Icons.apps_rounded,           accent: Color(0xFF4F46E5)),
    _Category(label: 'تحويل',   icon: Icons.swap_horiz_rounded,     accent: Color(0xFF06B6D4)),
    _Category(label: 'تحرير',   icon: Icons.edit_rounded,           accent: Color(0xFFF59E0B)),
    _Category(label: 'حماية',   icon: Icons.shield_rounded,         accent: Color(0xFF10B981)),
    _Category(label: 'قريباً',  icon: Icons.rocket_launch_rounded,  accent: Color(0xFF8B5CF6)),
  ];

  // ── Tool list ────────────────────────────────────────────────
  final List<ToolItem> _allTools = const [
    // تحويل
    ToolItem(id: 'img_to_pdf',   title: 'صورة إلى PDF',      subtitle: 'حوّل صورك لمستند PDF',               icon: Icons.image_rounded,               color: Color(0xFF4F46E5), colorLight: Color(0xFF818CF8), route: '/img-to-pdf',   category: 'تحويل'),
    ToolItem(id: 'word_to_pdf',  title: 'Word إلى PDF',       subtitle: 'تحويل مستندات Word',                 icon: Icons.description_rounded,         color: Color(0xFF2563EB), colorLight: Color(0xFF60A5FA), route: '/word-to-pdf',  category: 'تحويل'),
    ToolItem(id: 'excel_to_pdf', title: 'Excel إلى PDF',      subtitle: 'تحويل جداول البيانات',               icon: Icons.table_chart_rounded,         color: Color(0xFF059669), colorLight: Color(0xFF34D399), route: '/excel-to-pdf', category: 'تحويل'),
    ToolItem(id: 'ppt_to_pdf',   title: 'PPT إلى PDF',        subtitle: 'تحويل العروض التقديمية',             icon: Icons.slideshow_rounded,           color: Color(0xFFD97706), colorLight: Color(0xFFFBBF24), route: '/ppt-to-pdf',   category: 'تحويل'),
    ToolItem(id: 'html_to_pdf',  title: 'HTML إلى PDF',       subtitle: 'تحويل صفحات الويب',                  icon: Icons.code_rounded,                color: Color(0xFF475569), colorLight: Color(0xFF94A3B8), route: '/html-to-pdf',  category: 'تحويل'),
    ToolItem(id: 'txt_to_pdf',   title: 'نص إلى PDF',         subtitle: 'تحويل ملفات النص',                   icon: Icons.text_snippet_rounded,        color: Color(0xFF7C3AED), colorLight: Color(0xFFA78BFA), route: '/txt-to-pdf',   category: 'تحويل'),
    ToolItem(id: 'ocr_pdf',      title: 'قراءة PDF (OCR)',    subtitle: 'استخراج النص من الصور',              icon: Icons.document_scanner_rounded,    color: Color(0xFF0891B2), colorLight: Color(0xFF22D3EE), route: '/ocr',          category: 'تحويل'),
    // تحرير
    ToolItem(id: 'merge_pdf',    title: 'دمج PDF',            subtitle: 'ادمج ملفات PDF معاً',                icon: Icons.merge_rounded,               color: Color(0xFFDC2626), colorLight: Color(0xFFFCA5A5), route: '/merge-pdf',    category: 'تحرير'),
    ToolItem(id: 'compress_pdf', title: 'ضغط PDF',            subtitle: 'قلّل حجم الملف',                     icon: Icons.compress_rounded,            color: Color(0xFFB45309), colorLight: Color(0xFFFCD34D), route: '/compress-pdf', category: 'تحرير'),
    ToolItem(id: 'split_pdf',    title: 'تقسيم PDF',          subtitle: 'قسّم الملف لأجزاء',                  icon: Icons.call_split_rounded,          color: Color(0xFF6D28D9), colorLight: Color(0xFFDDD6FE), route: '/split-pdf',    category: 'تحرير'),
    ToolItem(id: 'rotate_pdf',   title: 'تدوير PDF',          subtitle: 'تدوير صفحات الملف',                  icon: Icons.rotate_right_rounded,        color: Color(0xFF0F766E), colorLight: Color(0xFF5EEAD4), route: '/rotate-pdf',   category: 'تحرير'),
    ToolItem(id: 'compress_image', title: 'ضغط الصور',        subtitle: 'قلّل حجم الصور بجودة عالية',         icon: Icons.photo_size_select_small_rounded, color: Color(0xFF0E7490), colorLight: Color(0xFF67E8F9), route: '/compress-image', category: 'تحرير'),
    ToolItem(id: 'zip_compress', title: 'ضغط ZIP',            subtitle: 'ضغط الملفات في أرشيف',               icon: Icons.folder_zip_rounded,          color: Color(0xFF1D4ED8), colorLight: Color(0xFF93C5FD), route: '/zip-compress', category: 'تحرير'),
    ToolItem(id: 'split_page',   title: 'حذف صفحات PDF',      subtitle: 'حذف صفحة أو أكثر من المستند',        icon: Icons.delete_sweep_rounded,        color: Color(0xFF047857), colorLight: Color(0xFF6EE7B7), route: '/split-page',   category: 'تحرير'),
    // حماية
    ToolItem(id: 'watermark',    title: 'علامة مائية',        subtitle: 'أضف علامتك المائية',                 icon: Icons.water_drop_rounded,          color: Color(0xFF0369A1), colorLight: Color(0xFF7DD3FC), route: '/watermark',    category: 'حماية'),
    ToolItem(id: 'protect_pdf',  title: 'حماية PDF',          subtitle: 'تشفير بكلمة مرور',                   icon: Icons.lock_rounded,                color: Color(0xFF9D174D), colorLight: Color(0xFFFBCFE8), route: '/protect-pdf',  category: 'حماية'),
    ToolItem(id: 'sign_pdf',     title: 'توقيع PDF',          subtitle: 'أضف توقيعك الرقمي',                  icon: Icons.draw_rounded,                color: Color(0xFF374151), colorLight: Color(0xFFD1D5DB), route: '/sign-pdf',     category: 'حماية'),
    // قريباً
    ToolItem(id: 'pdf_editor',   title: 'تحرير PDF',          subtitle: 'تعديل النصوص مباشرة',                icon: Icons.edit_document,               color: Color(0xFF166534), colorLight: Color(0xFF86EFAC), route: '/pdf-editor',   category: 'قريباً'),
    ToolItem(id: 'pdf_to_word',  title: 'PDF إلى Word',       subtitle: 'تحويل PDF لمستند Word',              icon: Icons.article_rounded,             color: Color(0xFF5B21B6), colorLight: Color(0xFFC4B5FD), route: '/pdf-to-word',  category: 'قريباً'),
    ToolItem(id: 'pdf_to_img',   title: 'PDF إلى صور',        subtitle: 'تحويل الصفحات لصور',                 icon: Icons.perm_media_rounded,          color: Color(0xFF92400E), colorLight: Color(0xFFFDE68A), route: '/pdf-to-img',   category: 'قريباً'),
  ];

  // ── Filtered + searched tools ────────────────────────────────
  List<ToolItem> get _filteredTools {
    Iterable<ToolItem> base = _allTools;
    final cat = _categories[_selectedCategory].label;
    if (cat != 'الكل') base = base.where((t) => t.category == cat);
    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.trim().toLowerCase();
      base = base.where((t) =>
        t.title.toLowerCase().contains(q) ||
        t.subtitle.toLowerCase().contains(q) ||
        t.category.toLowerCase().contains(q),
      );
    }
    return base.toList();
  }

  @override
  void initState() {
    super.initState();
    _staggerCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..forward();
    _searchCtrl.addListener(() => setState(() => _searchQuery = _searchCtrl.text));
  }

  @override
  void dispose() {
    _staggerCtrl.dispose();
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Root build ───────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));

    return Scaffold(
      backgroundColor: isDark ? _navy : const Color(0xFFF1F5F9),
      body: IndexedStack(
        index: _bottomNavIndex,
        children: [
          _buildToolsView(isDark),
          HistoryScreen(onBack: () => setState(() => _bottomNavIndex = 0)),
        ],
      ),
      bottomNavigationBar: _buildBottomNav(isDark),
    );
  }

  // ── Tools view ───────────────────────────────────────────────
  Widget _buildToolsView(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        gradient: isDark
            ? const LinearGradient(colors: [_navy, Color(0xFF0D1230)], begin: Alignment.topCenter, end: Alignment.bottomCenter)
            : const LinearGradient(colors: [Color(0xFFF1F5F9), Color(0xFFE8EEFF)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
      ),
      child: SafeArea(
        bottom: false,
        child: CustomScrollView(
          controller: _scrollCtrl,
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _buildHeader(isDark)),
            SliverToBoxAdapter(child: _buildSearchBar(isDark)),
            SliverToBoxAdapter(child: _buildCategoryRail(isDark)),
            SliverToBoxAdapter(child: _buildSectionTitle(isDark)),
            if (_filteredTools.isEmpty)
              SliverToBoxAdapter(child: _buildEmptyState(isDark))
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 110),
                sliver: SliverGrid(
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) => _buildAnimatedCard(_filteredTools[i], i),
                    childCount: _filteredTools.length,
                  ),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 200,
                    crossAxisSpacing: 14,
                    mainAxisSpacing: 14,
                    childAspectRatio: 0.9,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── Header ───────────────────────────────────────────────────
  Widget _buildHeader(bool isDark) {
    final availableCount = _allTools.where((t) => t.category != 'قريباً').length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Logo mark
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: const LinearGradient(
                    colors: [_indigo, Color(0xFF7C3AED)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [BoxShadow(color: _indigo.withValues(alpha: 0.4), blurRadius: 14, offset: const Offset(0, 4))],
                ),
                child: const Icon(Icons.picture_as_pdf_rounded, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              // App name
              RichText(
                text: TextSpan(children: [
                  TextSpan(
                    text: 'PDF ',
                    style: GoogleFonts.cairo(fontSize: 22, fontWeight: FontWeight.w900, color: isDark ? _pearl : const Color(0xFF0F172A)),
                  ),
                  TextSpan(
                    text: 'Master',
                    style: GoogleFonts.cairo(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      foreground: Paint()
                        ..shader = const LinearGradient(colors: [_indigoLt, _cyan])
                            .createShader(const Rect.fromLTWH(0, 0, 90, 30)),
                    ),
                  ),
                ]),
              ),
              const Spacer(),
              // Settings button
              Semantics(
                button: true,
                label: 'الإعدادات',
                child: GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
                  },
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: isDark ? _navyCard : Colors.white,
                      border: Border.all(color: isDark ? _divider : const Color(0xFFE2E8F0)),
                    ),
                    child: Icon(Icons.tune_rounded, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B), size: 20),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          // Hero banner
          _buildHeroBanner(isDark, availableCount),
          const SizedBox(height: 6),
          // Credit
          Center(
            child: RichText(
              text: TextSpan(children: [
                TextSpan(
                  text: 'إعداد: ',
                  style: GoogleFonts.cairo(fontSize: 11, color: _muted),
                ),
                TextSpan(
                  text: 'ابوحسن المؤيدي',
                  style: GoogleFonts.cairo(fontSize: 11, color: _indigoLt, fontWeight: FontWeight.w700),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroBanner(bool isDark, int count) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          colors: [Color(0xFF1E1B4B), Color(0xFF0F172A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: _indigo.withValues(alpha: 0.25)),
        boxShadow: [BoxShadow(color: _indigo.withValues(alpha: 0.12), blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'مرحباً بك في',
                  style: GoogleFonts.cairo(fontSize: 13, color: const Color(0xFF94A3B8)),
                ),
                Text(
                  'PDF Master',
                  style: GoogleFonts.cairo(fontSize: 24, fontWeight: FontWeight.w900, color: _pearl),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(50),
                        color: _indigo.withValues(alpha: 0.2),
                        border: Border.all(color: _indigoLt.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        '$count أداة جاهزة',
                        style: GoogleFonts.cairo(fontSize: 11, fontWeight: FontWeight.w700, color: _indigoLt),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(50),
                        color: _cyan.withValues(alpha: 0.12),
                        border: Border.all(color: _cyan.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        'مجاني 100٪',
                        style: GoogleFonts.cairo(fontSize: 11, fontWeight: FontWeight.w700, color: _cyan),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [_indigo.withValues(alpha: 0.35), _indigo.withValues(alpha: 0.0)],
              ),
              border: Border.all(color: _indigoLt.withValues(alpha: 0.3), width: 1.5),
            ),
            child: const Icon(Icons.auto_awesome_rounded, color: _indigoLt, size: 28),
          ),
        ],
      ),
    );
  }

  // ── Search bar ───────────────────────────────────────────────
  Widget _buildSearchBar(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: isDark ? _navyCard : Colors.white,
          border: Border.all(color: isDark ? _divider : const Color(0xFFE2E8F0)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 3))],
        ),
        child: TextField(
          controller: _searchCtrl,
          textAlign: TextAlign.right,
          textDirection: TextDirection.rtl,
          style: GoogleFonts.cairo(fontSize: 14, color: isDark ? _pearl : const Color(0xFF0F172A)),
          decoration: InputDecoration(
            hintText: 'ابحث عن أداة…',
            hintStyle: GoogleFonts.cairo(fontSize: 14, color: _muted),
            prefixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    color: _muted,
                    onPressed: () { _searchCtrl.clear(); FocusScope.of(context).unfocus(); },
                  )
                : null,
            suffixIcon: const Icon(Icons.search_rounded, color: _muted, size: 22),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          ),
        ),
      ),
    );
  }

  // ── Category horizontal rail ─────────────────────────────────
  Widget _buildCategoryRail(bool isDark) {
    return SizedBox(
      height: 60,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
        itemCount: _categories.length,
        itemBuilder: (_, i) {
          final cat = _categories[i];
          final selected = _selectedCategory == i;
          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() {
                _selectedCategory = i;
                _staggerCtrl.reset();
                _staggerCtrl.forward();
              });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              margin: const EdgeInsets.only(right: 10),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(50),
                color: selected
                    ? cat.accent
                    : (isDark ? _navyCard : Colors.white),
                border: Border.all(
                  color: selected
                      ? cat.accent
                      : (isDark ? _divider : const Color(0xFFE2E8F0)),
                ),
                boxShadow: selected
                    ? [BoxShadow(color: cat.accent.withValues(alpha: 0.38), blurRadius: 14, offset: const Offset(0, 4))]
                    : [],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    cat.icon,
                    size: 14,
                    color: selected ? Colors.white : _muted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    cat.label,
                    style: GoogleFonts.cairo(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: selected ? Colors.white : _muted,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Section title with count badge ───────────────────────────
  Widget _buildSectionTitle(bool isDark) {
    final count = _filteredTools.length;
    final cat = _categories[_selectedCategory];
    final title = _selectedCategory == 0 ? 'جميع الأدوات' : cat.label;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 22,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              gradient: LinearGradient(
                colors: [cat.accent, cat.accent.withValues(alpha: 0.4)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            title,
            style: GoogleFonts.cairo(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: isDark ? _pearl : const Color(0xFF0F172A),
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(50),
              color: cat.accent.withValues(alpha: 0.12),
            ),
            child: Text(
              '$count أداة',
              style: GoogleFonts.cairo(fontSize: 12, fontWeight: FontWeight.w700, color: cat.accent),
            ),
          ),
        ],
      ),
    );
  }

  // ── Empty state ──────────────────────────────────────────────
  Widget _buildEmptyState(bool isDark) {
    final isSearch = _searchQuery.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64),
      child: Column(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _indigo.withValues(alpha: 0.1),
            ),
            child: Icon(
              isSearch ? Icons.search_off_rounded : Icons.construction_rounded,
              size: 36,
              color: _indigo.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            isSearch ? 'لا توجد نتائج' : 'قريباً!',
            style: GoogleFonts.cairo(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: isDark ? _pearl : const Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isSearch
                ? 'لم نجد أداة تطابق "$_searchQuery"'
                : 'نعمل على هذه الأدوات وستكون متاحة قريباً',
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(fontSize: 13, color: _muted, height: 1.6),
          ),
          if (isSearch) ...[
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () { _searchCtrl.clear(); FocusScope.of(context).unfocus(); },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: _indigo.withValues(alpha: 0.12),
                  border: Border.all(color: _indigoLt.withValues(alpha: 0.3)),
                ),
                child: Text(
                  'مسح البحث',
                  style: GoogleFonts.cairo(fontSize: 13, fontWeight: FontWeight.w600, color: _indigoLt),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Animated tool card wrapper ───────────────────────────────
  Widget _buildAnimatedCard(ToolItem tool, int index) {
    final delay = (index * 0.07).clamp(0.0, 0.65);
    final anim = CurvedAnimation(
      parent: _staggerCtrl,
      curve: Interval(delay, (delay + 0.4).clamp(0.0, 1.0), curve: Curves.easeOutCubic),
    );
    return AnimatedBuilder(
      animation: anim,
      builder: (_, child) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.25), end: Offset.zero).animate(anim),
          child: child,
        ),
      ),
      child: ToolCard(tool: tool, onTap: () => _onToolTap(tool)),
    );
  }

  // ── Bottom navigation ────────────────────────────────────────
  Widget _buildBottomNav(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0C1020) : Colors.white,
        border: Border(top: BorderSide(color: isDark ? _divider : const Color(0xFFE2E8F0), width: 1)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 24, offset: const Offset(0, -6))],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _navItem(0, 'الأدوات', Icons.grid_view_rounded, isDark),
              _navItem(1, 'السجل',  Icons.history_rounded,    isDark),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem(int index, String label, IconData icon, bool isDark) {
    final isSelected = _bottomNavIndex == index;
    return Semantics(
      button: true,
      selected: isSelected,
      label: label,
      child: GestureDetector(
        onTap: () { HapticFeedback.selectionClick(); setState(() => _bottomNavIndex = index); },
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutQuint,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 11),
          decoration: BoxDecoration(
            color: isSelected ? _indigo.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                child: Icon(
                  icon,
                  key: ValueKey<bool>(isSelected),
                  color: isSelected ? _indigo : _muted,
                  size: 24,
                ),
              ),
              if (isSelected) ...[
                const SizedBox(width: 8),
                Text(
                  label,
                  style: GoogleFonts.cairo(fontSize: 14, fontWeight: FontWeight.bold, color: _indigo),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── Navigation handler ───────────────────────────────────────
  void _onToolTap(ToolItem tool) {
    HapticFeedback.lightImpact();
    switch (tool.id) {
      case 'img_to_pdf':     Navigator.push(context, _route(const ImageToPdfScreen()));    break;
      case 'word_to_pdf':    Navigator.push(context, _route(const WordToPdfScreen()));     break;
      case 'excel_to_pdf':   Navigator.push(context, _route(const ExcelToPdfScreen()));    break;
      case 'ppt_to_pdf':     Navigator.push(context, _route(const PptToPdfScreen()));      break;
      case 'html_to_pdf':    Navigator.push(context, _route(const HtmlToPdfScreen()));     break;
      case 'txt_to_pdf':     Navigator.push(context, _route(const TxtToPdfScreen()));      break;
      case 'ocr_pdf':        Navigator.push(context, _route(const TextRecognitionScreen())); break;
      case 'merge_pdf':      Navigator.push(context, _route(const MergePdfScreen()));      break;
      case 'compress_pdf':   Navigator.push(context, _route(const CompressPdfScreen()));   break;
      case 'split_pdf':      Navigator.push(context, _route(const SplitPdfScreen()));      break;
      case 'rotate_pdf':     Navigator.push(context, _route(const RotatePdfScreen()));     break;
      case 'compress_image': Navigator.push(context, _route(const CompressImageScreen())); break;
      case 'zip_compress':   Navigator.push(context, _route(const ZipCompressScreen()));   break;
      case 'split_page':     Navigator.push(context, _route(const DeletePagesScreen()));   break;
      case 'watermark':      Navigator.push(context, _route(const WatermarkPdfScreen()));  break;
      case 'protect_pdf':    Navigator.push(context, _route(const ProtectPdfScreen()));    break;
      case 'sign_pdf':       Navigator.push(context, _route(const SignPdfScreen()));       break;
      default:               Navigator.push(context, _route(ComingSoonScreen(tool: tool)));
    }
  }

  /// Shared fade+slide transition for tool screens
  MaterialPageRoute<void> _route(Widget screen) {
    return MaterialPageRoute(
      builder: (_) => screen,
      // Smooth slide from bottom for sub-screens
    );
  }
}

// ── Data models ──────────────────────────────────────────────────

class _Category {
  final String label;
  final IconData icon;
  final Color accent;
  const _Category({required this.label, required this.icon, required this.accent});
}
