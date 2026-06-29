import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import '../theme/app_theme.dart';

/// ⚠️ خدمة استُخرجت لتوحيد منطق حفظ الملفات الناتجة عبر كل أدوات
/// التطبيق. كان هذا المنطق (تعدد وجهات الحفظ + تحقّق فعلي بعد الكتابة +
/// تجنّب تكرار اسم الملف بالامتداد الصحيح) موجوداً ومُتقَناً فقط داخل
/// ResultScreen (المستخدَمة من أدوات PDF)، بينما كانت أدوات الصور التي
/// تُنتج عدة ملفات دفعة واحدة (ضغط الصور، تحسين دقة الصور) تستخدم منطقاً
/// أبسط بكثير ومحدوداً: حفظ مباشر في صندوق التطبيق الداخلي فقط
/// (getApplicationDocumentsDirectory) بلا أي خيار لاختيار وجهة الحفظ
/// (تنزيلات/مستندات/تخزين خارجي)، وبلا أي تحقّق فعلي من نجاح الكتابة.
/// توحيد هذا المنطق هنا يضمن نفس تجربة الحفظ المضمونة والمرنة عبر كل
/// الأدوات دون تكرار الكود.
class FileSaveService {
  /// أنواع وجهات الحفظ المتاحة — مطابقة تماماً لما تستخدمه ResultScreen.
  static Future<File> _resolveTargetDir(String type, String subFolder) async {
    Directory targetDir;
    switch (type) {
      case 'downloads':
        final legacy = Directory('/storage/emulated/0/Download');
        targetDir = legacy.existsSync()
            ? legacy
            : (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
        break;
      case 'documents':
        final legacy = Directory('/storage/emulated/0/Documents');
        targetDir = legacy.existsSync()
            ? legacy
            : (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
        break;
      case 'external':
        targetDir = (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
        break;
      default: // 'internal'
        targetDir = await getApplicationDocumentsDirectory();
    }
    final dir = Directory('${targetDir.path}/$subFolder');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File(dir.path); // نُعيد المسار كـ File فقط لاستخدام .path بسهولة؛ لن يُستخدم كملف فعلي.
  }

  /// ينسخ [source] إلى الوجهة المطلوبة، يتحقّق فعلياً من نجاح الكتابة،
  /// ويتجنّب الكتابة فوق ملف موجود بنفس الاسم عبر إضافة رقم متزايد
  /// بالامتداد الفعلي الصحيح لـ source (لا امتداداً ثابتاً).
  /// يرمي Exception برسالة عربية واضحة عند الفشل.
  static Future<File> saveCopy({
    required File source,
    required String type,
    required String subFolder,
  }) async {
    final dirFile = await _resolveTargetDir(type, subFolder);
    final dirPath = dirFile.path;

    final fileName = source.path.split('/').last;
    final extension = fileName.contains('.') ? fileName.split('.').last : '';
    final baseName = extension.isEmpty
        ? fileName
        : fileName.replaceAll(RegExp('\\.$extension\$', caseSensitive: false), '');

    var dest = File('$dirPath/$fileName');
    int suffix = 1;
    while (dest.existsSync()) {
      dest = File(extension.isEmpty
          ? '$dirPath/$baseName ($suffix)'
          : '$dirPath/$baseName ($suffix).$extension');
      suffix++;
    }

    await source.copy(dest.path);

    final actuallySaved = dest.existsSync() && dest.lengthSync() > 0;
    if (!actuallySaved) {
      throw Exception('لم يصل الملف فعلياً إلى المسار المطلوب');
    }
    return dest;
  }

  /// يعرض شاشة سفلية لاختيار وجهة الحفظ، ثم يستدعي [onSave] بنوع الوجهة
  /// المختارة. واجهة موحَّدة لكل أدوات حفظ الملفات الفردية.
  static void showSaveDestinationSheet({
    required BuildContext context,
    required String subFolder,
    required Future<void> Function(String type) onSave,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), color: isDark ? AppTheme.bgCardLight : Colors.white),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 12),
          Container(width: 40, height: 4, decoration: BoxDecoration(borderRadius: BorderRadius.circular(2), color: AppTheme.textMuted)),
          const SizedBox(height: 16),
          Text('اختر مكان الحفظ', style: GoogleFonts.cairo(fontSize: 18, fontWeight: FontWeight.w800, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
          const SizedBox(height: 4),
          Text('سيُحفظ الملف في مجلد $subFolder', style: GoogleFonts.cairo(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          _SaveOption(isDark: isDark, icon: Icons.download_rounded, title: 'مجلد التنزيلات', subtitle: '/Download/$subFolder', color: AppTheme.primary, onTap: () { Navigator.pop(context); onSave('downloads'); }),
          _SaveOption(isDark: isDark, icon: Icons.folder_rounded, title: 'مجلد المستندات', subtitle: '/Documents/$subFolder', color: AppTheme.accent, onTap: () { Navigator.pop(context); onSave('documents'); }),
          _SaveOption(isDark: isDark, icon: Icons.storage_rounded, title: 'التخزين الخارجي', subtitle: 'بطاقة SD / وحدة تخزين خارجية', color: AppTheme.accentOrange, onTap: () { Navigator.pop(context); onSave('external'); }),
          _SaveOption(isDark: isDark, icon: Icons.phone_android_rounded, title: 'التخزين الداخلي', subtitle: '/data/$subFolder (خاص بالتطبيق، مضمون دوماً)', color: const Color(0xFF9F7AEA), onTap: () { Navigator.pop(context); onSave('internal'); }),
          const SizedBox(height: 20),
        ]),
      ),
    );
  }

  /// يعرض SnackBar نجاح موحَّد مع زر "فتح" — لاستخدامه بعد saveCopy.
  static void showSavedSnackBar(BuildContext context, File dest) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('تم الحفظ في: ${dest.path}', style: GoogleFonts.cairo(fontSize: 12)),
      backgroundColor: Colors.green.shade700,
      behavior: SnackBarBehavior.floating,
      action: SnackBarAction(label: 'فتح', textColor: Colors.white, onPressed: () => OpenFilex.open(dest.path)),
    ));
  }

  /// يعرض SnackBar فشل موحَّد.
  static void showFailedSnackBar(BuildContext context, Object error) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('فشل الحفظ: $error', style: GoogleFonts.cairo()),
      backgroundColor: Colors.red.shade700,
      behavior: SnackBarBehavior.floating,
    ));
  }
}

class _SaveOption extends StatelessWidget {
  final bool isDark;
  final IconData icon;
  final String title, subtitle;
  final Color color;
  final VoidCallback onTap;
  const _SaveOption({required this.isDark, required this.icon, required this.title, required this.subtitle, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: title,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: isDark ? AppTheme.bgCard : const Color(0xFFF8F8FF), border: Border.all(color: color.withValues(alpha: 0.2))),
        child: Row(children: [
          Container(width: 44, height: 44, decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: color.withValues(alpha: 0.12)), child: Icon(icon, color: color, size: 22)),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: GoogleFonts.cairo(fontSize: 14, fontWeight: FontWeight.w700, color: isDark ? AppTheme.textPrimary : const Color(0xFF1A1A2E))),
            Text(subtitle, style: GoogleFonts.cairo(fontSize: 11, color: AppTheme.textMuted)),
          ])),
          const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppTheme.textMuted),
        ]),
      ),
    ),
  );
}
