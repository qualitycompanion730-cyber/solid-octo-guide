import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:animated_text_kit/animated_text_kit.dart';

// ═══════════════════════════════════════════════════════════════
//  SplashScreen — PDF Master  (rewritten: modern global style)
//  Design: deep-navy base · indigo + cyan dual-accent palette
//  Signature: animated document-stack that morphs into the logo
// ═══════════════════════════════════════════════════════════════

class SplashScreen extends StatefulWidget {
  final VoidCallback onComplete;
  const SplashScreen({super.key, required this.onComplete});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // ── Controllers ──────────────────────────────────────────────
  late AnimationController _logoCtrl;      // logo scale + fade
  late AnimationController _orbCtrl;       // ambient glow orbs
  late AnimationController _docsCtrl;      // flying doc sheets
  late AnimationController _contentCtrl;   // text + chips slide-in
  late AnimationController _ctaCtrl;       // CTA button reveal
  late AnimationController _shineCtrl;     // logo shine sweep

  // ── Animations ───────────────────────────────────────────────
  late Animation<double> _logoScale;
  late Animation<double> _logoFade;
  late Animation<double> _contentFade;
  late Animation<Offset> _contentSlide;
  late Animation<double> _ctaFade;
  late Animation<Offset> _ctaSlide;
  late Animation<double> _shineAnim;

  // ── Floating doc sheets ──────────────────────────────────────
  final List<_DocSheet> _sheets = [];

  // ── State flags ──────────────────────────────────────────────
  bool _showContent = false;
  bool _showCta = false;

  // ── Palette (local constants for clarity) ───────────────────
  static const Color _navy     = Color(0xFF0A0E27);
  static const Color _navyMid  = Color(0xFF0F1535);
  static const Color _indigo   = Color(0xFF4F46E5);
  static const Color _indigoLt = Color(0xFF818CF8);
  static const Color _cyan     = Color(0xFF06B6D4);
  static const Color _amber    = Color(0xFFF59E0B);
  static const Color _pearl    = Color(0xFFF8FAFC);
  static const Color _muted    = Color(0xFF94A3B8);

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));
    _initSheets();
    _initAnimations();
    _runSequence();
  }

  // ── Floating document sheets (replaces generic particles) ────
  void _initSheets() {
    final rng = Random();
    // 8 semi-transparent PDF page silhouettes at varied positions
    for (int i = 0; i < 8; i++) {
      _sheets.add(_DocSheet(
        x: rng.nextDouble(),
        startY: rng.nextDouble(),
        width: rng.nextDouble() * 30 + 20,
        rotationSeed: rng.nextDouble() * 2 * pi,
        speed: rng.nextDouble() * 0.12 + 0.06,
        opacity: rng.nextDouble() * 0.18 + 0.06,
        colorIndex: rng.nextInt(3),
      ));
    }
  }

  void _initAnimations() {
    _logoCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));
    _orbCtrl  = AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat(reverse: true);
    _docsCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 12))..repeat();
    _contentCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _ctaCtrl     = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _shineCtrl   = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

    _logoScale = CurvedAnimation(parent: _logoCtrl, curve: Curves.easeOutBack);
    _logoFade  = CurvedAnimation(parent: _logoCtrl, curve: const Interval(0.0, 0.5, curve: Curves.easeIn));

    _contentFade  = CurvedAnimation(parent: _contentCtrl, curve: Curves.easeOut);
    _contentSlide = Tween<Offset>(begin: const Offset(0, 0.25), end: Offset.zero)
        .animate(CurvedAnimation(parent: _contentCtrl, curve: Curves.easeOutCubic));

    _ctaFade  = CurvedAnimation(parent: _ctaCtrl, curve: Curves.easeOut);
    _ctaSlide = Tween<Offset>(begin: const Offset(0, 0.2), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctaCtrl, curve: Curves.easeOutCubic));

    _shineAnim = Tween<double>(begin: -1.0, end: 2.0)
        .animate(CurvedAnimation(parent: _shineCtrl, curve: Curves.easeInOut));
  }

  Future<void> _runSequence() async {
    await Future.delayed(const Duration(milliseconds: 250));
    _logoCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 800));
    _shineCtrl.forward();          // shine sweep across logo
    await Future.delayed(const Duration(milliseconds: 200));
    setState(() => _showContent = true);
    _contentCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 2200));
    setState(() => _showCta = true);
    _ctaCtrl.forward();
  }

  @override
  void dispose() {
    _logoCtrl.dispose();
    _orbCtrl.dispose();
    _docsCtrl.dispose();
    _contentCtrl.dispose();
    _ctaCtrl.dispose();
    _shineCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [_navy, _navyMid, Color(0xFF131B3A)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Stack(
          children: [
            // Layer 1 — ambient glow orbs
            _buildAmbientOrbs(size),
            // Layer 2 — floating document sheets
            AnimatedBuilder(
              animation: _docsCtrl,
              builder: (_, __) => CustomPaint(
                size: Size(size.width, size.height),
                painter: _DocSheetPainter(sheets: _sheets, progress: _docsCtrl.value),
              ),
            ),
            // Layer 3 — subtle dot grid
            CustomPaint(
              size: Size(size.width, size.height),
              painter: _DotGridPainter(),
            ),
            // Layer 4 — main content
            SafeArea(
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  // Logo
                  ScaleTransition(
                    scale: _logoScale,
                    child: FadeTransition(
                      opacity: _logoFade,
                      child: _buildLogo(),
                    ),
                  ),
                  const SizedBox(height: 36),
                  // Text content
                  if (_showContent)
                    SlideTransition(
                      position: _contentSlide,
                      child: FadeTransition(
                        opacity: _contentFade,
                        child: _buildTextContent(),
                      ),
                    ),
                  const Spacer(flex: 3),
                  // CTA
                  if (_showCta)
                    SlideTransition(
                      position: _ctaSlide,
                      child: FadeTransition(
                        opacity: _ctaFade,
                        child: _buildCTAButton(),
                      ),
                    )
                  else
                    const SizedBox(height: 90),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Ambient glow orbs ────────────────────────────────────────
  Widget _buildAmbientOrbs(Size size) {
    return AnimatedBuilder(
      animation: _orbCtrl,
      builder: (_, __) {
        final t = _orbCtrl.value;
        return Stack(
          children: [
            Positioned(
              top: -100 + t * 20,
              left: -80 + t * 10,
              child: _Orb(size: 320, color: _indigo, opacity: 0.18 + t * 0.06),
            ),
            Positioned(
              bottom: -120 + t * 15,
              right: -70,
              child: _Orb(size: 280, color: _cyan, opacity: 0.14 + t * 0.05),
            ),
            Positioned(
              top: size.height * 0.4 - t * 20,
              left: size.width * 0.5 - 100,
              child: _Orb(size: 200, color: _amber, opacity: 0.06 + t * 0.04),
            ),
          ],
        );
      },
    );
  }

  // ── Logo with shine sweep ────────────────────────────────────
  Widget _buildLogo() {
    return AnimatedBuilder(
      animation: _shineAnim,
      builder: (_, child) {
        return Container(
          width: 116,
          height: 116,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(32),
            gradient: const LinearGradient(
              colors: [Color(0xFF4338CA), _indigo, Color(0xFF7C3AED)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(color: _indigo.withValues(alpha: 0.55), blurRadius: 48, spreadRadius: 4),
              BoxShadow(color: _cyan.withValues(alpha: 0.25), blurRadius: 80, spreadRadius: 10),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(32),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Shine sweep
                Positioned.fill(
                  child: Transform.translate(
                    offset: Offset(_shineAnim.value * 160, 0),
                    child: Transform.rotate(
                      angle: -0.4,
                      child: Container(
                        width: 40,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.white.withValues(alpha: 0.0),
                              Colors.white.withValues(alpha: 0.28),
                              Colors.white.withValues(alpha: 0.0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Icon
                const Icon(Icons.picture_as_pdf_rounded, size: 58, color: Colors.white),
                // Corner accent dot
                Positioned(
                  top: 14,
                  right: 14,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _cyan.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Text content ─────────────────────────────────────────────
  Widget _buildTextContent() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        children: [
          // App name with dual-color treatment
          RichText(
            textAlign: TextAlign.center,
            text: TextSpan(children: [
              TextSpan(
                text: 'PDF ',
                style: GoogleFonts.cairo(
                  fontSize: 40,
                  fontWeight: FontWeight.w900,
                  color: _pearl,
                  letterSpacing: -0.5,
                ),
              ),
              TextSpan(
                text: 'Master',
                style: GoogleFonts.cairo(
                  fontSize: 40,
                  fontWeight: FontWeight.w900,
                  foreground: Paint()
                    ..shader = const LinearGradient(
                      colors: [_indigoLt, _cyan],
                    ).createShader(const Rect.fromLTWH(0, 0, 160, 50)),
                  letterSpacing: -0.5,
                ),
              ),
            ]),
          ),
          const SizedBox(height: 14),
          // Animated tagline
          SizedBox(
            height: 28,
            child: DefaultTextStyle(
              style: GoogleFonts.cairo(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: _muted,
              ),
              child: AnimatedTextKit(
                animatedTexts: [
                  TypewriterAnimatedText(
                    'أداتك الذكية لملفات PDF',
                    speed: const Duration(milliseconds: 75),
                  ),
                  TypewriterAnimatedText(
                    'تحويل · دمج · تقسيم · حماية',
                    speed: const Duration(milliseconds: 75),
                  ),
                  TypewriterAnimatedText(
                    'كل ما تحتاجه في مكان واحد',
                    speed: const Duration(milliseconds: 75),
                  ),
                ],
                repeatForever: true,
                pause: const Duration(milliseconds: 1400),
              ),
            ),
          ),
          const SizedBox(height: 32),
          // Feature chips — cleaner, icon-led
          _buildFeatureChips(),
          const SizedBox(height: 24),
          // Trust badge
          _buildTrustBadge(),
        ],
      ),
    );
  }

  Widget _buildFeatureChips() {
    final features = [
      (Icons.swap_horiz_rounded, _indigoLt, 'تحويل سريع'),
      (Icons.lock_outline_rounded, _cyan,    'حماية قوية'),
      (Icons.content_cut_rounded, _amber,   'تقسيم ودمج'),
      (Icons.auto_fix_high_rounded, _indigoLt, 'واجهة أنيقة'),
    ];

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 10,
      runSpacing: 10,
      children: features.map((f) => _FeatureChip(icon: f.$1, accent: f.$2, label: f.$3)).toList(),
    );
  }

  Widget _buildTrustBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withValues(alpha: 0.05),
        border: Border.all(color: _cyan.withValues(alpha: 0.22), width: 1),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _cyan.withValues(alpha: 0.15),
            ),
            child: const Icon(Icons.verified_rounded, color: _cyan, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'مجاني 100% • بدون إعلانات',
                  style: GoogleFonts.cairo(fontSize: 13, fontWeight: FontWeight.w700, color: _cyan),
                ),
                Text(
                  'جميع أدوات PDF في تطبيق واحد آمن',
                  style: GoogleFonts.cairo(fontSize: 12, color: _muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── CTA button ───────────────────────────────────────────────
  Widget _buildCTAButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          // Primary button
          GestureDetector(
            onTap: () {
              HapticFeedback.mediumImpact();
              widget.onComplete();
            },
            child: Container(
              width: double.infinity,
              height: 60,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: const LinearGradient(
                  colors: [_indigo, Color(0xFF7C3AED)],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: _indigo.withValues(alpha: 0.5),
                    blurRadius: 30,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'ابدأ الآن',
                    style: GoogleFonts.cairo(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 22),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Social proof line
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.star_rounded, color: _amber, size: 16),
              const SizedBox(width: 4),
              Text(
                'تقييم 4.9 · أكثر من 50,000 مستخدم',
                style: GoogleFonts.cairo(fontSize: 13, color: _muted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  Supporting Widgets
// ═══════════════════════════════════════════════════════════════

class _Orb extends StatelessWidget {
  final double size;
  final Color color;
  final double opacity;
  const _Orb({required this.size, required this.color, required this.opacity});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withValues(alpha: opacity), color.withValues(alpha: 0.0)],
        ),
      ),
    );
  }
}

class _FeatureChip extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String label;
  const _FeatureChip({required this.icon, required this.accent, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(50),
        color: accent.withValues(alpha: 0.08),
        border: Border.all(color: accent.withValues(alpha: 0.28), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: accent),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.cairo(fontSize: 13, fontWeight: FontWeight.w600, color: const Color(0xFFCBD5E1)),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  Custom Painters
// ═══════════════════════════════════════════════════════════════

/// Floating document sheet silhouettes — the signature element
class _DocSheet {
  double x, startY, width, rotationSeed, speed, opacity;
  int colorIndex;
  _DocSheet({
    required this.x,
    required this.startY,
    required this.width,
    required this.rotationSeed,
    required this.speed,
    required this.opacity,
    required this.colorIndex,
  });
}

class _DocSheetPainter extends CustomPainter {
  final List<_DocSheet> sheets;
  final double progress;

  static const List<Color> _colors = [
    Color(0xFF4F46E5), // indigo
    Color(0xFF06B6D4), // cyan
    Color(0xFFF59E0B), // amber
  ];

  _DocSheetPainter({required this.sheets, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in sheets) {
      final y = (s.startY - progress * s.speed) % 1.0;
      final px = s.x * size.width;
      final py = y * size.height;
      final w = s.width;
      final h = w * 1.35;  // A4-ish ratio
      final color = _colors[s.colorIndex].withValues(alpha: s.opacity);
      final rotation = s.rotationSeed + progress * 0.4;

      canvas.save();
      canvas.translate(px, py);
      canvas.rotate(rotation);

      // Page rectangle
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(-w / 2, -h / 2, w, h),
        const Radius.circular(3),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );

      // Simulated text lines inside page
      final linePaint = Paint()
        ..color = color.withValues(alpha: s.opacity * 0.6)
        ..strokeWidth = 1.0;
      for (int i = 0; i < 4; i++) {
        final lineY = -h / 2 + h * 0.25 + i * (h * 0.13);
        canvas.drawLine(
          Offset(-w / 2 + w * 0.15, lineY),
          Offset(-w / 2 + w * (i % 2 == 0 ? 0.82 : 0.65), lineY),
          linePaint,
        );
      }

      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_DocSheetPainter old) => true;
}

/// Subtle dot-grid background (replaces line grid — more modern)
class _DotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const spacing = 36.0;
    final paint = Paint()
      ..color = const Color(0xFF4F46E5).withValues(alpha: 0.07);
    for (double x = spacing / 2; x < size.width; x += spacing) {
      for (double y = spacing / 2; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), 1.2, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotGridPainter old) => false;
}
