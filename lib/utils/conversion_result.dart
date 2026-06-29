// ═══════════════════════════════════════════════════════════════════════════
//  conversion_result.dart
//  ───────────────────────────────────────────────────────────────────────────
//  نموذج موحَّد لنتيجة أي عملية تحويل في التطبيق.
//
//  بدلاً من تمرير (Uint8List?, String? error) المتفرقة بين الشاشات،
//  كل عملية تُعيد ConversionResult الذي يحمل إما نجاحاً أو فشلاً
//  مصنَّفاً بنوع خطأ محدد — مما يسهّل عرض رسائل خطأ دقيقة للمستخدم.
//
//  الاستخدام:
//    final result = await MyConverter.convert(file);
//    switch (result) {
//      case ConversionSuccess(:final bytes, :final outputPath):
//        // استخدم bytes أو outputPath
//      case ConversionFailure(:final message, :final type):
//        // عرض رسالة مناسبة حسب type
//    }
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:typed_data';

// ─────────────────────────────────────────────────────────────────────────────
//  أنواع أخطاء التحويل
// ─────────────────────────────────────────────────────────────────────────────

enum ConversionErrorType {
  /// الملف المدخَل تالف أو غير مدعوم
  invalidInput,

  /// نفدت الذاكرة أثناء التحويل (ملف ضخم جداً)
  outOfMemory,

  /// فشل في تحليل الملف (بنية غير صحيحة)
  parseError,

  /// فشل الجسر الأصلي (NativePdfBridge)
  nativeBridgeError,

  /// ألغى المستخدم العملية
  cancelled,

  /// فشل حفظ الملف الناتج
  saveError,

  /// خطأ غير محدد
  unknown,
}

// ─────────────────────────────────────────────────────────────────────────────
//  Sealed class — النتيجة
// ─────────────────────────────────────────────────────────────────────────────

sealed class ConversionResult {
  const ConversionResult();
}

/// نجاح — يحمل بايتات PDF الناتجة ومسار الملف المحفوظ
class ConversionSuccess extends ConversionResult {
  const ConversionSuccess({
    required this.bytes,
    required this.outputPath,
    this.pageCount,
  });

  final Uint8List bytes;

  /// المسار الكامل للملف المحفوظ على القرص
  final String outputPath;

  /// عدد الصفحات (اختياري — إن أُتيح من المحوّل)
  final int? pageCount;
}

/// فشل — يحمل رسالة الخطأ ونوعه
class ConversionFailure extends ConversionResult {
  const ConversionFailure({
    required this.message,
    this.type = ConversionErrorType.unknown,
    this.technicalDetails,
  });

  final String message;
  final ConversionErrorType type;

  /// تفاصيل تقنية (stack trace مثلاً) للتشخيص — لا تُعرض للمستخدم
  final String? technicalDetails;

  /// هل ألغى المستخدم العملية؟
  bool get isCancelled => type == ConversionErrorType.cancelled;

  /// رسالة مناسبة للعرض حسب نوع الخطأ
  String get userMessage {
    switch (type) {
      case ConversionErrorType.outOfMemory:
        return 'الملف كبير جداً على ذاكرة الجهاز المتاحة. جرّب ملفاً أصغر.';
      case ConversionErrorType.invalidInput:
        return 'الملف تالف أو غير مدعوم. تحقق من الملف وحاول مجدداً.';
      case ConversionErrorType.parseError:
        return 'تعذّر قراءة محتوى الملف. قد يكون تالفاً أو محمياً.';
      case ConversionErrorType.nativeBridgeError:
        return 'حدث خطأ في محرك التحويل. حاول مجدداً.';
      case ConversionErrorType.cancelled:
        return 'تم إلغاء التحويل.';
      case ConversionErrorType.saveError:
        return 'تعذّر حفظ الملف. تحقق من مساحة التخزين.';
      case ConversionErrorType.unknown:
        return message;
    }
  }

  /// بناء ConversionFailure من Exception
  factory ConversionFailure.fromException(Object error, [StackTrace? stack]) {
    final msg = error.toString();
    ConversionErrorType type;

    if (error is OutOfMemoryError || msg.contains('OUT_OF_MEMORY')) {
      type = ConversionErrorType.outOfMemory;
    } else if (msg.contains('cancel') || msg.contains('إلغاء')) {
      type = ConversionErrorType.cancelled;
    } else if (msg.contains('parse') || msg.contains('XML') || msg.contains('ZIP')) {
      type = ConversionErrorType.parseError;
    } else if (msg.contains('NativePdfBridge') || msg.contains('RENDER_FAILED')) {
      type = ConversionErrorType.nativeBridgeError;
    } else {
      type = ConversionErrorType.unknown;
    }

    return ConversionFailure(
      message: msg,
      type: type,
      technicalDetails: stack?.toString(),
    );
  }
}
