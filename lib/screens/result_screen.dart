import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_filex/open_filex.dart';

class ResultScreen extends StatefulWidget {
  final File file;
  final String title;
  final String subtitle;
  final String toolId;
  final String toolName;
  final Map<String, String> settings;

  const ResultScreen({
    super.key,
    required this.file,
    required this.title,
    required this.subtitle,
    required this.toolId,
    required this.toolName,
    required this.settings,
  });

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scaleAnim;
  late Animation<double> _fadeAnim;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _scaleAnim = CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut);
    _fadeAnim = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String _fmt(int b) {
    if (b > 1048576) return '${(b / 1048576).toStringAsFixed(1)} MB';
    return '${(b / 1024).toStringAsFixed(0)} KB';
  }

  Future<void> _save() async {
    try {
      final dir = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final dest = File('${dir.path}/${widget.file.path.split('/').last}');
      await widget.file.copy(dest.path);
      if (!mounted) return;
      setState(() => _saved = true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('تم الحفظ في: ${dest.path}',
            style: GoogleFonts.cairo()),
        backgroundColor: const Color(0xFF276749),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('فشل الحفظ: $e', style: GoogleFonts.cairo()),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _open() async {
    await OpenFilex.open(widget.file.path);
  }

  Future<void> _share() async {
    await Share.shareXFiles([XFile(widget.file.path)],
        text: 'ملف PDF - ${widget.toolName}');
  }

  @override
  Widget build(BuildContext context) {
    final fileName = widget.file.path.split('/').last;
    int fileSize = 0;
    try { fileSize = widget.file.lengthSync(); } catch (_) {}

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D1A),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0D0D1A), Color(0xFF0A1628)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: FadeTransition(
            opacity: _fadeAnim,
            child: Column(
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: GestureDetector(
                      onTap: () => Navigator.of(context)
                          .popUntil((r) => r.isFirst),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1E30),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF2A2A40)),
                        ),
                        child: const Icon(Icons.close_rounded,
                            color: Color(0xFFB0B0C8), size: 20),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                // Success icon
                ScaleTransition(
                  scale: _scaleAnim,
                  child: Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        colors: [Color(0xFF38A169), Color(0xFF2F9E44)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF38A169).withOpacity(0.4),
                          blurRadius: 30,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.check_rounded,
                        color: Colors.white, size: 50),
                  ),
                ),

                const SizedBox(height: 28),

                Text(
                  widget.title,
                  style: GoogleFonts.cairo(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    widget.subtitle,
                    style: GoogleFonts.cairo(
                      fontSize: 14,
                      color: const Color(0xFFB0B0C8),
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),

                const SizedBox(height: 28),

                // File card
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A2E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF2A2A40)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            gradient: const LinearGradient(
                              colors: [Color(0xFFE53E3E), Color(0xFFC53030)],
                            ),
                          ),
                          child: const Icon(Icons.picture_as_pdf_rounded,
                              color: Colors.white, size: 28),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                fileName,
                                style: GoogleFonts.cairo(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _fmt(fileSize),
                                style: GoogleFonts.cairo(
                                  fontSize: 12,
                                  color: const Color(0xFF6B6B8A),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 28),

                // Action buttons
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      _ActionButton(
                        label: 'حفظ في الجهاز',
                        icon: Icons.download_rounded,
                        gradient: const LinearGradient(
                          colors: [Color(0xFF6B46C1), Color(0xFF553C9A)],
                        ),
                        onTap: _save,
                      ),
                      const SizedBox(height: 10),
                      _ActionButton(
                        label: 'فتح الملف',
                        icon: Icons.open_in_new_rounded,
                        gradient: const LinearGradient(
                          colors: [Color(0xFF5A67D8), Color(0xFF434190)],
                        ),
                        onTap: _open,
                      ),
                      const SizedBox(height: 10),
                      _ActionButton(
                        label: 'مشاركة الملف',
                        icon: Icons.share_rounded,
                        gradient: const LinearGradient(
                          colors: [Color(0xFF319795), Color(0xFF2C7A7B)],
                        ),
                        onTap: _share,
                      ),
                      const SizedBox(height: 10),
                      GestureDetector(
                        onTap: () =>
                            Navigator.of(context).popUntil((r) => r.isFirst),
                        child: Container(
                          width: double.infinity,
                          padding:
                              const EdgeInsets.symmetric(vertical: 16),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: const Color(0xFF2A2A40),
                              width: 1.5,
                            ),
                          ),
                          child: Text(
                            'العودة للرئيسية',
                            style: GoogleFonts.cairo(
                              color: const Color(0xFFB0B0C8),
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                if (_saved) ...[
                  const SizedBox(height: 16),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF276749),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.check_circle_rounded,
                            color: Colors.white, size: 16),
                        const SizedBox(width: 8),
                        Text('تم الحفظ بنجاح',
                            style: GoogleFonts.cairo(
                                color: Colors.white,
                                fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Gradient gradient;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.gradient,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Text(
              label,
              style: GoogleFonts.cairo(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
