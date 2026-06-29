// ═══════════════════════════════════════════════════════════════════════════
//  file_type_utils.dart
//  ───────────────────────────────────────────────────────────────────────────
//  أدوات مشتركة للتعامل مع أنواع الملفات وامتداداتها.
//  يُجمِّع منطق التحقق من النوع المتكرر في شاشات متعددة في مكان واحد.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'package:path/path.dart' as p;

// ─────────────────────────────────────────────────────────────────────────────
//  ثوابت الامتدادات
// ─────────────────────────────────────────────────────────────────────────────

class FileExtensions {
  FileExtensions._();

  // PDF
  static const Set<String> pdf = {'.pdf'};

  // مستندات Word
  static const Set<String> word = {'.doc', '.docx'};

  // جداول البيانات
  static const Set<String> excel = {'.xls', '.xlsx', '.xlsm', '.ods'};

  // العروض التقديمية
  static const Set<String> powerpoint = {'.ppt', '.pptx', '.odp'};

  // HTML
  static const Set<String> html = {'.html', '.htm'};

  // نصوص
  static const Set<String> text = {'.txt', '.md', '.markdown'};

  // صور
  static const Set<String> images = {
    '.jpg', '.jpeg', '.png', '.webp', '.bmp',
    '.gif', '.tiff', '.tif', '.heic', '.heif',
  };

  // أرشيف
  static const Set<String> archive = {'.zip', '.rar', '.7z', '.tar', '.gz'};
}

// ─────────────────────────────────────────────────────────────────────────────
//  FileTypeUtils — الدوال المساعدة
// ─────────────────────────────────────────────────────────────────────────────

class FileTypeUtils {
  FileTypeUtils._();

  /// يُعيد امتداد الملف بأحرف صغيرة مع النقطة (مثال: '.pdf')
  static String ext(String path) => p.extension(path).toLowerCase();

  /// تحقق بسيط من امتداد الملف
  static bool isPdf(String path)         => ext(path) == '.pdf';
  static bool isWord(String path)        => FileExtensions.word.contains(ext(path));
  static bool isExcel(String path)       => FileExtensions.excel.contains(ext(path));
  static bool isPowerPoint(String path)  => FileExtensions.powerpoint.contains(ext(path));
  static bool isHtml(String path)        => FileExtensions.html.contains(ext(path));
  static bool isText(String path)        => FileExtensions.text.contains(ext(path));
  static bool isImage(String path)       => FileExtensions.images.contains(ext(path));
  static bool isArchive(String path)     => FileExtensions.archive.contains(ext(path));

  /// نوع الملف كنص قابل للعرض (للمستخدم)
  static String typeName(String path) {
    final e = ext(path);
    if (FileExtensions.pdf.contains(e))         return 'PDF';
    if (FileExtensions.word.contains(e))        return 'Word';
    if (FileExtensions.excel.contains(e))       return 'Excel';
    if (FileExtensions.powerpoint.contains(e))  return 'PowerPoint';
    if (FileExtensions.html.contains(e))        return 'HTML';
    if (FileExtensions.text.contains(e))        return 'نص';
    if (FileExtensions.images.contains(e))      return 'صورة';
    if (FileExtensions.archive.contains(e))     return 'أرشيف';
    return e.isNotEmpty ? e.substring(1).toUpperCase() : 'غير معروف';
  }

  /// حجم الملف كنص مقروء (بايت / KB / MB)
  static String readableSize(int bytes) {
    if (bytes < 1024) return '$bytes بايت';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// حجم ملف من File object
  static String readableFileSize(File file) {
    try {
      return readableSize(file.lengthSync());
    } catch (_) {
      return '';
    }
  }

  /// يستخرج اسم الملف بدون امتداد (للاستخدام كاسم افتراضي للملف الناتج)
  static String baseName(String path) => p.basenameWithoutExtension(path);

  /// يبني اسم ملف الخرج: {baseName}_{suffix}.pdf
  static String outputName(String inputPath, {String suffix = 'converted'}) {
    final base = baseName(inputPath);
    return '${base}_$suffix.pdf';
  }

  /// التحقق من أن الملف موجود فعلاً على القرص
  static bool exists(String path) => File(path).existsSync();

  /// يُعيد true إذا كان الامتداد مقبولاً من قائمة مُعطاة
  static bool hasAllowedExtension(String path, Set<String> allowed) =>
      allowed.contains(ext(path));
}
