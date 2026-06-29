import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimmer/shimmer.dart';

import '../../theme/app_theme.dart';
import 'image_import_screen.dart';

enum SortOrder {
  dateDesc,
  dateAsc,
  nameAsc,
  nameDesc,
  resolutionDesc,
  resolutionAsc
}

extension SortOrderLabel on SortOrder {
  String get label {
    switch (this) {
      case SortOrder.dateDesc:
        return 'الأحدث أولاً';
      case SortOrder.dateAsc:
        return 'الأقدم أولاً';
      case SortOrder.nameAsc:
        return 'الاسم أ → ي';
      case SortOrder.nameDesc:
        return 'الاسم ي → أ';
      case SortOrder.resolutionDesc:
        return 'الدقة الأعلى';
      case SortOrder.resolutionAsc:
        return 'الدقة الأدنى';
    }
  }

  IconData get icon {
    switch (this) {
      case SortOrder.dateDesc:
        return Icons.schedule_rounded;
      case SortOrder.dateAsc:
        return Icons.history_rounded;
      case SortOrder.nameAsc:
        return Icons.sort_by_alpha_rounded;
      case SortOrder.nameDesc:
        return Icons.sort_by_alpha_rounded;
      case SortOrder.resolutionDesc:
        return Icons.hd_rounded;
      case SortOrder.resolutionAsc:
        return Icons.sd_rounded;
    }
  }
}

class ImageToPdfScreen extends StatefulWidget {
  const ImageToPdfScreen({super.key});
  @override
  State<ImageToPdfScreen> createState() => _ImageToPdfScreenState();
}

class _ImageToPdfScreenState extends State<ImageToPdfScreen>
    with TickerProviderStateMixin {
  final List<AssetEntity> _images = [];
  final Set<AssetEntity> _selectedAssets = {};
  final List<AssetEntity> _selectionOrder = [];
  final Map<String, int> _selectionIndexes = {};
  List<AssetPathEntity> _albums = [];
  AssetPathEntity? _currentAlbum;

  bool _isLoading = true;
  bool _hasPermission = true;
  bool _isLoadingMore = false;
  int _currentPage = 0;
  static const int _pageSize = 80;
  int _requestId = 0;

  SortOrder _sortOrder = SortOrder.dateDesc;
  int _currentTab = 0;

  final ScrollController _scrollController = ScrollController();
  Timer? _reloadDebounce;

  late final AnimationController _fabController;
  late final Animation<double> _fabScale;

  @override
  void initState() {
    super.initState();
    _fabController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _fabScale =
        CurvedAnimation(parent: _fabController, curve: Curves.elasticOut);
    _restorePreferences();
    _scrollController.addListener(_onScroll);
    _loadAlbums();
    PhotoManager.addChangeCallback((_) {
      _reloadDebounce?.cancel();
      _reloadDebounce = Timer(const Duration(milliseconds: 700), () {
        if (!mounted || _isLoading || _isLoadingMore) return;
        _currentPage = 0;
        _loadImages();
      });
    });
    PhotoManager.startChangeNotify();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _reloadDebounce?.cancel();
    _fabController.dispose();
    PhotoManager.stopChangeNotify();
    super.dispose();
  }

  Future<void> _restorePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final sortStr = prefs.getString('img2pdf_sort');
    if (sortStr != null && mounted) {
      setState(() {
        _sortOrder = SortOrder.values.firstWhere((e) => e.name == sortStr,
            orElse: () => SortOrder.dateDesc);
      });
    }
    final tab = prefs.getInt('img2pdf_tab');
    if (tab != null && mounted) { setState(() => _currentTab = tab); }
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('img2pdf_sort', _sortOrder.name);
    await prefs.setInt('img2pdf_tab', _currentTab);
    if (_currentAlbum != null)
      // ignore: curly_braces_in_flow_control_structures
      await prefs.setString('img2pdf_album', _currentAlbum!.id);
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 500 &&
        !_isLoadingMore &&
        !_isLoading) {
      _loadImages(loadMore: true);
    }
  }

  Future<void> _loadAlbums() async {
    try {
      final perm = await PhotoManager.requestPermissionExtend();
      if (!perm.isAuth) {
        if (mounted)
          // ignore: curly_braces_in_flow_control_structures
          setState(() {
            _isLoading = false;
            _hasPermission = false;
          });
        return;
      }
      final albums = await PhotoManager.getAssetPathList(
          type: RequestType.image, hasAll: true);
      if (!mounted) return;
      final prefs = await SharedPreferences.getInstance();
      final lastId = prefs.getString('img2pdf_album');
      AssetPathEntity? target;
      if (lastId != null) {
        try {
          target = albums.firstWhere((a) => a.id == lastId);
        } catch (_) {}
      }
      target ??= albums.isNotEmpty ? albums.first : null;
      setState(() {
        _albums = albums;
        _currentAlbum = target;
      });
      await _loadImages();
    } catch (e) {
      debugPrint('[ImageToPdf] loadAlbums: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadImages({bool loadMore = false}) async {
    if (_currentAlbum == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    if (loadMore && (_isLoadingMore || _isLoading)) return;
    _requestId++;
    final reqId = _requestId;
    setState(() {
      loadMore ? _isLoadingMore = true : (_isLoading = true);
      if (!loadMore) _currentPage = 0;
    });
    try {
      final page = loadMore ? _currentPage : 0;
      final assets =
          await _currentAlbum!.getAssetListPaged(page: page, size: _pageSize);
      if (reqId != _requestId || !mounted) return;
      final sorted = List<AssetEntity>.from(assets);
      _applySort(sorted);
      setState(() {
        if (loadMore) {
          _images.addAll(sorted);
        } else {
          _images
            ..clear()
            ..addAll(sorted);
          _currentPage = 0;
        }
        if (assets.length == _pageSize) _currentPage++;
        _isLoading = false;
        _isLoadingMore = false;
      });
      _savePreferences();
    } catch (e) {
      debugPrint('[ImageToPdf] loadImages: $e');
      if (mounted)
        // ignore: curly_braces_in_flow_control_structures
        setState(() {
          _isLoading = false;
          _isLoadingMore = false;
        });
    }
  }

  void _applySort(List<AssetEntity> list) {
    list.sort((a, b) {
      switch (_sortOrder) {
        case SortOrder.dateDesc:
          return b.modifiedDateTime.compareTo(a.modifiedDateTime);
        case SortOrder.dateAsc:
          return a.modifiedDateTime.compareTo(b.modifiedDateTime);
        case SortOrder.nameAsc:
          return (a.title ?? '').compareTo(b.title ?? '');
        case SortOrder.nameDesc:
          return (b.title ?? '').compareTo(a.title ?? '');
        case SortOrder.resolutionDesc:
          return (b.width * b.height).compareTo(a.width * a.height);
        case SortOrder.resolutionAsc:
          return (a.width * a.height).compareTo(b.width * b.height);
      }
    });
  }

  void _toggleSelection(AssetEntity asset) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedAssets.contains(asset)) {
        _selectedAssets.remove(asset);
        _selectionOrder.remove(asset);
        _rebuildIndexes();
      } else {
        _selectedAssets.add(asset);
        _selectionOrder.add(asset);
        _selectionIndexes[asset.id] = _selectionOrder.length;
      }
    });
    _selectedAssets.isNotEmpty
        ? _fabController.forward()
        : _fabController.reverse();
  }

  void _clearSelection() {
    HapticFeedback.lightImpact();
    setState(() {
      _selectedAssets.clear();
      _selectionOrder.clear();
      _selectionIndexes.clear();
    });
    _fabController.reverse();
  }

  void _selectAll() {
    HapticFeedback.mediumImpact();
    setState(() {
      _selectedAssets
        ..clear()
        ..addAll(_images);
      _selectionOrder
        ..clear()
        ..addAll(_images);
      _rebuildIndexes();
    });
    _fabController.forward();
  }

  void _invertSelection() {
    HapticFeedback.lightImpact();
    setState(() {
      final prev = Set<AssetEntity>.from(_selectedAssets);
      _selectedAssets.clear();
      _selectionOrder.clear();
      for (final img in _images) {
        if (!prev.contains(img)) {
          _selectedAssets.add(img);
          _selectionOrder.add(img);
        }
      }
      _rebuildIndexes();
    });
    _selectedAssets.isNotEmpty
        ? _fabController.forward()
        : _fabController.reverse();
  }

  void _rebuildIndexes() {
    _selectionIndexes.clear();
    for (int i = 0; i < _selectionOrder.length; i++) {
      _selectionIndexes[_selectionOrder[i].id] = i + 1;
    }
  }

  // Navigate to import screen and refresh gallery on return
  Future<void> _onImportPressed() async {
    if (_selectedAssets.isEmpty) return;
    await Navigator.push<bool>(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => ImageImportScreen(
            selectedAssets: List.from(_selectionOrder), pickedFiles: const []),
        transitionsBuilder: (_, anim, __, c) =>
            FadeTransition(opacity: anim, child: c),
      ),
    );
    _clearSelection();
    // Refresh the gallery so newly converted files appear
    if (mounted) {
      _currentPage = 0;
      _loadImages();
    }
  }

  Future<void> _pickFromFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp'],
          allowMultiple: true);
      if (result != null && result.paths.isNotEmpty && mounted) {
        final files =
            result.paths.whereType<String>().map((p) => File(p)).toList();
        if (files.isNotEmpty) {
          await Navigator.push(
              context,
              PageRouteBuilder(
                pageBuilder: (_, __, ___) => ImageImportScreen(
                    selectedAssets: const [], pickedFiles: files),
                transitionsBuilder: (_, anim, __, c) =>
                    FadeTransition(opacity: anim, child: c),
              ));
          if (mounted) {
            _currentPage = 0;
            _loadImages();
          }
        }
      }
    } catch (e) {
      _toast('فشل فتح مدير الملفات: $e');
    }
  }

  Future<void> _pickFromCamera() async {
    try {
      final photo = await ImagePicker()
          .pickImage(source: ImageSource.camera, imageQuality: 95);
      if (photo != null && mounted) {
        await Navigator.push(
            context,
            PageRouteBuilder(
              pageBuilder: (_, __, ___) => ImageImportScreen(
                  selectedAssets: const [], pickedFiles: [File(photo.path)]),
              transitionsBuilder: (_, anim, __, c) =>
                  FadeTransition(opacity: anim, child: c),
            ));
        if (mounted) {
          _currentPage = 0;
          _loadImages();
        }
      }
    } catch (e) {
      _toast('فشل فتح الكاميرا: $e');
    }
  }

  void _openPreview(int index) => Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) =>
            _ImagePreviewScreen(images: _images, initialIndex: index),
        transitionsBuilder: (_, anim, __, c) =>
            FadeTransition(opacity: anim, child: c),
      ));

  void _showSortSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true, // تمت إضافتها للسماح بالتحكم في الحجم
      builder: (_) => Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: AppTheme.bgCardLight),
        child: SingleChildScrollView(
          // تمت إضافته لتفعيل التمرير عند الحاجة
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 12),
            Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    color: AppTheme.textMuted)),
            Padding(
                padding: const EdgeInsets.all(20),
                child: Text('ترتيب الصور',
                    style: GoogleFonts.cairo(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.textPrimary))),
            ...SortOrder.values.map((s) => ListTile(
                  leading: Icon(s.icon,
                      color: s == _sortOrder
                          ? AppTheme.primary
                          : AppTheme.textMuted),
                  title: Text(s.label,
                      style: GoogleFonts.cairo(
                          color: s == _sortOrder
                              ? AppTheme.primary
                              : AppTheme.textPrimary,
                          fontWeight: s == _sortOrder
                              ? FontWeight.w700
                              : FontWeight.normal)),
                  trailing: s == _sortOrder
                      ? const Icon(Icons.check_rounded, color: AppTheme.primary)
                      : null,
                  onTap: () {
                    Navigator.pop(context);
                    setState(() => _sortOrder = s);
                    _loadImages();
                  },
                )),
            const SizedBox(height: 12),
          ]),
        ),
      ),
    );
  }

  void _showAlbumsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _AlbumsSheet(
          albums: _albums,
          currentAlbum: _currentAlbum,
          onSelected: (album) {
            Navigator.pop(context);
            if (album.id != _currentAlbum?.id) {
              setState(() => _currentAlbum = album);
              _clearSelection();
              _loadImages();
            }
          }),
    );
  }

  void _toast(String msg, {bool isError = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.cairo(color: Colors.white)),
      backgroundColor: isError ? Colors.redAccent.shade700 : AppTheme.primary,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          bottom: false,
          child: Column(children: [
            _buildAppBar(),
            if (_selectedAssets.isNotEmpty) _buildSelectionBar(),
            Expanded(child: _buildContent()),
            _buildBottomNav(),
            if (_selectedAssets.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: _buildFab()),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    final albumName = _currentAlbum == null
        ? 'الصور'
        : (_currentAlbum!.isAll || _currentAlbum!.name == 'Recent'
            ? 'جميع الصور'
            : _currentAlbum!.name);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: AppTheme.bgCardLight,
                  border: Border.all(color: AppTheme.divider)),
              child: const Icon(Icons.arrow_back_ios_new_rounded,
                  size: 18, color: AppTheme.textSecondary)),
        ),
        const SizedBox(width: 12),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('صورة إلى PDF',
              style: GoogleFonts.cairo(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textPrimary)),
          GestureDetector(
            onTap: _showAlbumsSheet,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(albumName,
                  style: GoogleFonts.cairo(
                      fontSize: 12, color: AppTheme.primaryLight)),
              const Icon(Icons.keyboard_arrow_down_rounded,
                  size: 14, color: AppTheme.primaryLight),
            ]),
          ),
        ])),
        IconButton(
            icon: const Icon(Icons.sort_rounded, color: AppTheme.textSecondary),
            onPressed: _showSortSheet),
        if (_selectedAssets.isNotEmpty) ...[
          IconButton(
              icon:
                  const Icon(Icons.select_all_rounded, color: AppTheme.primary),
              tooltip: 'تحديد الكل',
              onPressed: _selectAll),
          IconButton(
              icon: const Icon(Icons.close_rounded,
                  color: AppTheme.textSecondary),
              onPressed: _clearSelection),
        ],
      ]),
    );
  }

  Widget _buildSelectionBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: AppTheme.primary.withValues(alpha: 0.12),
          border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3))),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8), color: AppTheme.primary),
          child: Text('${_selectedAssets.length}',
              style: GoogleFonts.cairo(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 14)),
        ),
        const SizedBox(width: 10),
        Text('صورة محددة',
            style:
                GoogleFonts.cairo(color: AppTheme.textPrimary, fontSize: 14)),
        const Spacer(),
        TextButton(
            onPressed: _invertSelection,
            child: Text('عكس التحديد',
                style: GoogleFonts.cairo(
                    color: AppTheme.primaryLight, fontSize: 12))),
        TextButton(
            onPressed: _clearSelection,
            child: Text('إلغاء',
                style: GoogleFonts.cairo(
                    color: AppTheme.textMuted, fontSize: 12))),
      ]),
    );
  }

  Widget _buildContent() {
    if (!_hasPermission) return _permissionView();
    if (_isLoading) return _skeletonGrid();
    if (_currentTab == 1) return _albumsGrid();
    if (_images.isEmpty) return _emptyView();
    return _imagesGrid();
  }

  Widget _permissionView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.bgCardLight,
                    border: Border.all(color: AppTheme.divider, width: 2)),
                child: const Icon(Icons.photo_library_rounded,
                    size: 44, color: AppTheme.textMuted)),
            const SizedBox(height: 24),
            Text('الوصول للصور مطلوب',
                style: GoogleFonts.cairo(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary)),
            const SizedBox(height: 10),
            Text('يحتاج التطبيق إذن الوصول للصور لتحويلها إلى PDF',
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                    color: AppTheme.textSecondary, fontSize: 14)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
                onPressed: _loadAlbums,
                icon: const Icon(Icons.security_rounded),
                label: Text('منح الإذن',
                    style: GoogleFonts.cairo(fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 28, vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)))),
          ]),
        ),
      );

  Widget _emptyView() => Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.photo_library_outlined, size: 72, color: Colors.grey[700]),
        const SizedBox(height: 16),
        Text('لا توجد صور هنا',
            style: GoogleFonts.cairo(color: Colors.grey[500], fontSize: 16)),
      ]));

  Widget _skeletonGrid() => Shimmer.fromColors(
        baseColor: const Color(0xFF252836),
        highlightColor: const Color(0xFF2E3347),
        child: GridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
          itemCount: 18,
          itemBuilder: (_, __) => Container(
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12))),
        ),
      );

  Widget _imagesGrid() {
    return LayoutBuilder(builder: (ctx, c) {
      final cols = (c.maxWidth / 115).floor().clamp(3, 6);
      return GridView.builder(
        controller: _scrollController,
        // ignore: deprecated_member_use
        cacheExtent: 600,
        padding: const EdgeInsets.only(top: 6, left: 6, right: 6, bottom: 110),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols, crossAxisSpacing: 6, mainAxisSpacing: 6),
        itemCount: _images.length + (_isLoadingMore ? 1 : 0),
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: true,
        itemBuilder: (_, i) {
          if (i == _images.length)
            // ignore: curly_braces_in_flow_control_structures
            return const Center(
                child: Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: AppTheme.primary))));
          final asset = _images[i];
          return RepaintBoundary(
              child: _ImageTile(
            asset: asset,
            isSelected: _selectedAssets.contains(asset),
            order: _selectionIndexes[asset.id] ?? 0,
            onTap: () => _selectedAssets.isNotEmpty
                ? _toggleSelection(asset)
                : _openPreview(i),
            onLongPress: () {
              if (!_selectedAssets.contains(asset)) _toggleSelection(asset);
            },
          ));
        },
      );
    });
  }

  Widget _albumsGrid() {
    if (_albums.isEmpty)
      // ignore: curly_braces_in_flow_control_structures
      return Center(
          child: Text('لا توجد ألبومات',
              style: GoogleFonts.cairo(color: Colors.grey[500])));
    final sorted = [..._albums]..sort((a, b) {
        if (a.isAll) return -1;
        if (b.isAll) return 1;
        return a.name.compareTo(b.name);
      });
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.05),
      itemCount: sorted.length,
      itemBuilder: (_, i) => _AlbumCard(
          album: sorted[i],
          isSelected: _currentAlbum?.id == sorted[i].id,
          onTap: () {
            setState(() {
              _currentAlbum = sorted[i];
              _currentTab = 0;
            });
            _clearSelection();
            _loadImages();
          }),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
          color: AppTheme.bgCard,
          border: Border(
              top: BorderSide(color: Colors.white.withValues(alpha: 0.06))),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 16,
                offset: const Offset(0, -4))
          ]),
      child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              _navItem(Icons.photo_library_rounded,
                  Icons.photo_library_outlined, 'الصور', 0),
              _navItem(Icons.folder_copy_rounded, Icons.folder_copy_outlined,
                  'الألبومات', 1),
              _navSeparator(),
              _navAction(Icons.folder_open_rounded, 'الملفات', _pickFromFiles),
              _navAction(Icons.camera_alt_rounded, 'الكاميرا', _pickFromCamera),
            ]),
          )),
    );
  }

  Widget _navSeparator() => Container(
      width: 1,
      height: 32,
      color: Colors.white.withValues(alpha: 0.08),
      margin: const EdgeInsets.symmetric(horizontal: 4));

  Widget _navItem(IconData active, IconData inactive, String label, int tab) {
    final sel = _currentTab == tab;
    return Expanded(
        child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() => _currentTab = tab);
        if (tab == 0) _loadImages();
        _savePreferences();
      },
      child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Icon(sel ? active : inactive,
                    key: ValueKey(sel),
                    color: sel ? AppTheme.primary : AppTheme.textMuted,
                    size: 22)),
            const SizedBox(height: 2),
            Text(label,
                style: GoogleFonts.cairo(
                    fontSize: 10,
                    color: sel ? AppTheme.primary : AppTheme.textMuted,
                    fontWeight: sel ? FontWeight.w600 : FontWeight.normal)),
            const SizedBox(height: 2),
            AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: sel ? 16 : 0,
                height: 2,
                decoration: BoxDecoration(
                    color: AppTheme.primary,
                    borderRadius: BorderRadius.circular(1))),
          ])),
    ));
  }

  Widget _navAction(IconData icon, String label, VoidCallback fn) {
    return Expanded(
        child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: fn,
      child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: AppTheme.textMuted, size: 22),
            const SizedBox(height: 2),
            Text(label,
                style:
                    GoogleFonts.cairo(fontSize: 10, color: AppTheme.textMuted)),
          ])),
    ));
  }

  Widget _buildFab() => ScaleTransition(
        scale: _fabScale,
        child: SizedBox(
            height: 54,
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _onImportPressed,
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  elevation: 8,
                  shadowColor: AppTheme.primary.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16))),
              child:
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.auto_awesome_motion_rounded,
                    color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Text('استيراد ${_selectedAssets.length} صورة',
                    style: GoogleFonts.cairo(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15)),
              ]),
            )),
      );
}

class _ImageTile extends StatelessWidget {
  final AssetEntity asset;
  final bool isSelected;
  final int order;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ImageTile(
      {required this.asset,
      required this.isSelected,
      required this.order,
      required this.onTap,
      required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Hero(
        tag: 'img_${asset.id}',
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          // ignore: deprecated_member_use
          transform: isSelected
              // ignore: deprecated_member_use
              ? (Matrix4.identity()..scale(0.91))
              : Matrix4.identity(),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: isSelected
                ? Border.all(color: AppTheme.primary, width: 2.5)
                : Border.all(color: Colors.transparent, width: 2.5),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                        color: AppTheme.primary.withValues(alpha: 0.35),
                        blurRadius: 10)
                  ]
                : [],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(isSelected ? 9 : 11),
            child: Stack(fit: StackFit.expand, children: [
              AssetEntityImage(asset,
                  isOriginal: false,
                  thumbnailSize: const ThumbnailSize.square(280),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                      color: const Color(0xFF252836),
                      child: const Icon(Icons.broken_image_rounded,
                          color: Colors.white24, size: 28))),
              if (isSelected)
                Container(color: Colors.black.withValues(alpha: 0.25)),
              Positioned(
                  top: 6,
                  right: 6,
                  child: AnimatedScale(
                    scale: isSelected ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.elasticOut,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                          color: AppTheme.primary,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                                color: AppTheme.primary.withValues(alpha: 0.5),
                                blurRadius: 6)
                          ]),
                      child: Center(
                          child: Text('$order',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11))),
                    ),
                  )),
            ]),
          ),
        ),
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  final AssetPathEntity album;
  final bool isSelected;
  final VoidCallback onTap;

  const _AlbumCard(
      {required this.album, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final name =
        album.isAll || album.name == 'Recent' ? 'جميع الصور' : album.name;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: AppTheme.bgCardLight,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: isSelected
                  ? AppTheme.primary
                  : Colors.white.withValues(alpha: 0.05),
              width: isSelected ? 2 : 1),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                      color: AppTheme.primary.withValues(alpha: 0.2),
                      blurRadius: 12)
                ]
              : [],
        ),
        child: Column(children: [
          Expanded(
              child: FutureBuilder<List<AssetEntity>>(
            future: album.getAssetListRange(start: 0, end: 1),
            builder: (_, snap) {
              final cover =
                  snap.data?.isNotEmpty == true ? snap.data!.first : null;
              return ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(15)),
                child: cover != null
                    ? AssetEntityImage(cover,
                        isOriginal: false,
                        thumbnailSize: const ThumbnailSize.square(200),
                        fit: BoxFit.cover,
                        width: double.infinity)
                    : Container(
                        color: const Color(0xFF252836),
                        child: const Icon(Icons.photo_album_outlined,
                            color: Colors.white24, size: 40)),
              );
            },
          )),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(name,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: GoogleFonts.cairo(
                          color: isSelected
                              ? AppTheme.primary
                              : AppTheme.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 12)),
                  FutureBuilder<int>(
                      future: album.assetCountAsync,
                      builder: (_, snap) => Text('${snap.data ?? '...'} صورة',
                          style: GoogleFonts.cairo(
                              color: AppTheme.textMuted, fontSize: 11))),
                ]),
          ),
        ]),
      ),
    );
  }
}

class _AlbumsSheet extends StatelessWidget {
  final List<AssetPathEntity> albums;
  final AssetPathEntity? currentAlbum;
  final void Function(AssetPathEntity) onSelected;

  const _AlbumsSheet(
      {required this.albums,
      required this.currentAlbum,
      required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final sorted = [...albums]..sort((a, b) {
        if (a.isAll) return -1;
        if (b.isAll) return 1;
        return a.name.compareTo(b.name);
      });
    return Container(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.72),
      decoration: const BoxDecoration(
          color: Color(0xFF1C1E2E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Center(
            child: Container(
                margin: const EdgeInsets.only(top: 12, bottom: 4),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2)))),
        Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
            child: Row(children: [
              Text('اختر الألبوم',
                  style: GoogleFonts.cairo(
                      color: AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                  icon: Icon(Icons.close_rounded, color: Colors.grey[400]),
                  onPressed: () => Navigator.pop(context)),
            ])),
        Divider(color: Colors.white.withValues(alpha: 0.07), height: 1),
        Flexible(
            child: ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          shrinkWrap: true,
          itemCount: sorted.length,
          separatorBuilder: (_, __) => Divider(
              color: Colors.white.withValues(alpha: 0.04),
              height: 1,
              indent: 80),
          itemBuilder: (_, i) {
            final album = sorted[i];
            final name = album.isAll || album.name == 'Recent'
                ? 'جميع الصور'
                : album.name;
            final isSel = currentAlbum?.id == album.id;
            return ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              leading: FutureBuilder<List<AssetEntity>>(
                future: album.getAssetListRange(start: 0, end: 1),
                builder: (_, snap) {
                  final cover =
                      snap.data?.isNotEmpty == true ? snap.data!.first : null;
                  return Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                        color: const Color(0xFF252836),
                        borderRadius: BorderRadius.circular(12),
                        border: isSel
                            ? Border.all(color: AppTheme.primary, width: 2)
                            : null),
                    clipBehavior: Clip.antiAlias,
                    child: cover != null
                        ? AssetEntityImage(cover,
                            isOriginal: false,
                            thumbnailSize: const ThumbnailSize.square(110),
                            fit: BoxFit.cover)
                        : const Icon(Icons.photo_album_outlined,
                            color: Colors.white24, size: 24),
                  );
                },
              ),
              title: Text(name,
                  style: GoogleFonts.cairo(
                      color: isSel ? AppTheme.primary : AppTheme.textPrimary,
                      fontWeight: isSel ? FontWeight.bold : FontWeight.w600,
                      fontSize: 15)),
              subtitle: FutureBuilder<int>(
                  future: album.assetCountAsync,
                  builder: (_, snap) => Text('${snap.data ?? '...'} صورة',
                      style: GoogleFonts.cairo(
                          color: AppTheme.textMuted, fontSize: 12))),
              trailing: isSel
                  ? const Icon(Icons.check_circle_rounded,
                      color: AppTheme.primary, size: 22)
                  : Icon(Icons.chevron_right_rounded,
                      color: Colors.grey[700], size: 20),
              onTap: () => onSelected(album),
            );
          },
        )),
      ]),
    );
  }
}

class _ImagePreviewScreen extends StatefulWidget {
  final List<AssetEntity> images;
  final int initialIndex;
  const _ImagePreviewScreen({required this.images, required this.initialIndex});
  @override
  State<_ImagePreviewScreen> createState() => _ImagePreviewScreenState();
}

class _ImagePreviewScreenState extends State<_ImagePreviewScreen>
    with SingleTickerProviderStateMixin {
  late final PageController _pageCtrl;
  late int _index;
  bool _uiVisible = true;
  late final AnimationController _uiAnim;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pageCtrl = PageController(initialPage: _index);
    _uiAnim = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 250), value: 1);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _uiAnim.dispose();
    super.dispose();
  }

  void _toggleUi() {
    setState(() => _uiVisible = !_uiVisible);
    _uiVisible ? _uiAnim.forward() : _uiAnim.reverse();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.images.isEmpty)
      // ignore: curly_braces_in_flow_control_structures
      return const Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator()));
    final asset = widget.images[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: FadeTransition(
            opacity: _uiAnim,
            child: AppBar(
              backgroundColor: Colors.black.withValues(alpha: 0.6),
              elevation: 0,
              leading: IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new_rounded,
                      color: Colors.white, size: 20),
                  onPressed: () => Navigator.pop(context)),
              title: Text('${_index + 1} / ${widget.images.length}',
                  style: GoogleFonts.cairo(color: Colors.white, fontSize: 15)),
              centerTitle: true,
            )),
      ),
      body: GestureDetector(
        onTap: _toggleUi,
        child: Stack(fit: StackFit.expand, children: [
          PageView.builder(
            controller: _pageCtrl,
            itemCount: widget.images.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) => Hero(
              tag: 'img_${widget.images[i].id}',
              child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 6,
                  child: AssetEntityImage(widget.images[i],
                      isOriginal: true, fit: BoxFit.contain)),
            ),
          ),
          Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: FadeTransition(
                  opacity: _uiAnim, child: _ImageInfoBar(asset: asset))),
        ]),
      ),
    );
  }
}

class _ImageInfoBar extends StatelessWidget {
  final AssetEntity asset;
  const _ImageInfoBar({required this.asset});

  @override
  Widget build(BuildContext context) {
    final d = asset.createDateTime;
    final dateStr =
        '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      decoration: BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
            Colors.black.withValues(alpha: 0.85),
            Colors.transparent
          ])),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (asset.title != null)
          Text(asset.title!,
              style: GoogleFonts.cairo(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        const SizedBox(height: 8),
        Row(children: [
          _chip(Icons.aspect_ratio_rounded, '${asset.width} × ${asset.height}'),
          const SizedBox(width: 12),
          _chip(Icons.calendar_today_rounded, dateStr),
          const SizedBox(width: 12),
          FutureBuilder<File?>(
              future: asset.file,
              builder: (_, snap) {
                final mb = snap.data != null
                    ? (snap.data!.lengthSync() / 1048576).toStringAsFixed(1)
                    : '…';
                return _chip(Icons.storage_rounded, '$mb MB');
              }),
        ]),
      ]),
    );
  }

  Widget _chip(IconData icon, String text) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: Colors.white60),
        const SizedBox(width: 4),
        Text(text,
            style: GoogleFonts.cairo(color: Colors.white60, fontSize: 12)),
      ]);
}
