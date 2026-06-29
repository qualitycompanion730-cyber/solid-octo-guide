import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'theme/app_theme.dart';
import 'providers/theme_provider.dart';
import 'screens/splash_screen.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  final prefs = await SharedPreferences.getInstance();
  final isFirstLaunch = prefs.getBool('first_launch') ?? true;

  // ⚠️ إصلاح مرتبط بإعادة كتابة settings_screen.dart: ThemeProvider أصبح
  // يحفظ اختيار المستخدم (ليلي/نهاري) في SharedPreferences. هذا السطر
  // ضروري لتحميل ذلك الاختيار المحفوظ عند الإقلاع — بدونه يبقى الإصلاح في
  // ThemeProvider بلا أثر فعلي، لأن وضع المظهر سيبدأ افتراضياً (ليلي) في
  // كل مرة بصرف النظر عن ما حُفِظ.
  final themeProvider = ThemeProvider();
  await themeProvider.loadSaved();

  runApp(
    ChangeNotifierProvider.value(
      value: themeProvider,
      child: PdfMasterApp(showSplash: isFirstLaunch),
    ),
  );
}

class PdfMasterApp extends StatelessWidget {
  final bool showSplash;
  const PdfMasterApp({super.key, required this.showSplash});

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    return MaterialApp(
      title: 'PDF Master',
      debugShowCheckedModeBanner: false,
      themeMode: themeProvider.themeMode,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      home: showSplash ? const _SplashWrapper() : const HomeScreen(),
    );
  }
}

class _SplashWrapper extends StatefulWidget {
  const _SplashWrapper();

  @override
  State<_SplashWrapper> createState() => _SplashWrapperState();
}

class _SplashWrapperState extends State<_SplashWrapper> {
  bool _goHome = false;

  void _onSplashComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('first_launch', false);
    setState(() => _goHome = true);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 600),
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(-0.1, 0),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            )),
            child: child,
          ),
        );
      },
      child: _goHome
          ? const HomeScreen(key: ValueKey('home'))
          : SplashScreen(
              key: const ValueKey('splash'),
              onComplete: _onSplashComplete,
            ),
    );
  }
}
