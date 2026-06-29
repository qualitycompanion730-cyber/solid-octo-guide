// ═══════════════════════════════════════════════════════════════════════════
//  native_pdf_bridge.dart
//  ─────────────────────────────────────────────────────────────────────────
//  واجهة Dart لاستدعاء الجسر الأصلي (NativePdfBridge.kt) الذي يرسم PDF
//  فعلياً باستخدام محرك أندرويد الأصلي (Minikin → HarfBuzz → Skia) عبر
//  android.graphics.pdf.PdfDocument و android.text.StaticLayout.
//
//  هذا يستبدل أي استخدام لـ syncfusion_flutter_pdf لرسم النص في المحولات
//  الخمسة (DOCX/XLSX/PPTX/HTML/TXT). إنشاء PDF من صور فقط (pdf_service.dart)
//  لا يحتاج هذا الجسر ويبقى على Syncfusion (لا نص عربي فيه).
//
//  ⚠️ يجب استدعاء renderDocument من Main Isolate فقط (قنوات الإضافات/
//  المنصّة لا تعمل بشكل موثوق من Worker Isolates — وهذا نفس الدرس
//  المستفاد من مشكلة تحميل الخطوط في isolate_support.dart). إن كان
//  المحوّل يعمل داخل isolate، يجب جمع PdfDocSpec هناك ثم إرساله إلى
//  Main Isolate عبر SendPort لاستدعاء هذا الجسر، أو ببساطة جعل خطوة
//  "التحليل" فقط في الـ isolate وخطوة "الرسم النهائي" (سريعة نسبياً لأنها
//  أصلية ومُجمَّعة) في الخيط الرئيسي.
// ═══════════════════════════════════════════════════════════════════════════

import 'package:flutter/services.dart';

import 'pdf_layout_model.dart';

class NativePdfBridgeException implements Exception {
  final String message;
  final String? nativeStack;
  const NativePdfBridgeException(this.message, [this.nativeStack]);
  @override
  String toString() => 'NativePdfBridgeException: $message'
      '${nativeStack != null ? '\n$nativeStack' : ''}';
}

class FontRegistration {
  final String family;
  final bool bold;
  final Uint8List bytes;
  const FontRegistration(
      {required this.family, required this.bold, required this.bytes});

  Map<String, dynamic> toChannelMap() =>
      {'family': family, 'bold': bold, 'bytes': bytes};
}

class NativePdfBridge {
  NativePdfBridge._();

  static const MethodChannel _channel =
      MethodChannel('pdf_master/native_pdf');

  /// وصف خط واحد لتسجيله في الجسر الأصلي: عائلة + وزن (عادي/غامق) + بايتات.
  /// نمرّر bold صريحاً بدل تخمينه من اسم الملف لتفادي أي غموض على الجهة
  /// الأصلية (Kotlin) بخصوص أي ملف هو Regular وأي ملف هو Bold.
  static Future<void> registerFonts(List<FontRegistration> fonts) async {
    try {
      await _channel.invokeMethod('registerFonts', {
        'fonts': fonts.map((f) => f.toChannelMap()).toList(),
      });
    } on PlatformException catch (e) {
      throw NativePdfBridgeException(
          e.message ?? 'فشل تسجيل الخطوط في الجسر الأصلي', e.stacktrace);
    }
  }

  /// يرسم مستنداً كاملاً ويُعيد بايتات PDF جاهزة.
  /// [onProgress] اختياري: الجسر يرسل نسبة تقدّم (0..1) عبر EventChannel
  /// مصاحب أثناء معالجة الصفحات الطويلة — انظر `_progressChannel` أدناه.
  static Future<Uint8List> renderDocument(
    PdfDocSpec spec, {
    void Function(double progress, String stage)? onProgress,
  }) async {
    final sub = onProgress == null
        ? null
        : _progressEvents.receiveBroadcastStream().listen((event) {
            if (event is Map) {
              final p = (event['progress'] as num?)?.toDouble() ?? 0;
              final stage = (event['stage'] as String?) ?? '';
              onProgress(p, stage);
            }
          });

    try {
      final args = spec.toChannelArgs();

      // الصور: تُمرَّر كـ binary فعلي ضمن نفس الـ args map، لأن
      // StandardMethodCodec يدعم Uint8List/Map<Object?,Object?> أصلياً
      // دون أي حاجة لـ Base64 (أسرع وأخف بكثير). الخطوط لا تُمرَّر هنا؛
      // تُسجَّل مرة واحدة مسبقاً عبر registerFonts() قبل أول استدعاء رسم.
      final imageAssets = <String, Uint8List>{};

      void collectFrom(PdfBlock block) {
        if (block is PdfBlockImage) {
          imageAssets[block.assetRefId] = block.bytes;
        } else if (block is PdfBlockGroup) {
          for (final child in block.children) {
            collectFrom(child);
          }
        } else if (block is PdfBlockTable) {
          // ⚠️ إصلاح حقيقي: صور خلايا الجدول (انظر PdfTableCell.imageBytes
          // في pdf_layout_model.dart) كانت مفقودة كلياً من خريطة
          // imageAssets المُرسَلة فعلياً عبر القناة، فحتى لو حمل JSON
          // إشارة imageAssetRef صحيحة، الجسر الأصلي لن يجد بايتات الصورة
          // المطابقة في الخريطة. نجمعها هنا بنفس مفتاحها (imageAssetRefId)
          // المضبوط مسبقاً من DocxToPdfConverter._mapBlocksToDocSpec.
          for (final row in block.rows) {
            for (final cell in row) {
              if (cell.imageAssetRefId != null && cell.imageBytes != null) {
                imageAssets[cell.imageAssetRefId!] = cell.imageBytes!;
              }
            }
          }
        }
      }

      for (final page in spec.pages) {
        for (final block in page.blocks) {
          collectFrom(block);
        }
        for (final overlay in page.overlayBlocks) {
          collectFrom(overlay.block);
        }
        // ⚠️ إضافة جديدة (خلفية صفحة OCR القابلة للبحث): صورة خلفية
        // الصفحة الكاملة (page.backgroundImageBytes) لم تكن تُجمَع هنا
        // إطلاقاً من قبل لأن لا مستهلك سابق لها كان يضبط
        // backgroundImageAssetRefId (انظر PdfPageSpec.toChannelArgs في
        // pdf_layout_model.dart، الذي يضبط هذا المعرّف الآن فعلياً).
        // بدون هذا التجميع هنا، JSON الصفحة يحمل إشارة
        // 'backgroundImageAssetRef' صحيحة لكن الجسر الأصلي (Kotlin)
        // لن يجد بايتات الصورة المطابقة في imageAssets أبداً.
        if (page.backgroundImageAssetRefId != null &&
            page.backgroundImageBytes != null) {
          imageAssets[page.backgroundImageAssetRefId!] =
              page.backgroundImageBytes!;
        }
      }
      args['_imageAssets'] = imageAssets;

      final result = await _channel.invokeMethod('renderDocument', args);
      if (result is Uint8List) return result;
      if (result is Map && result['bytes'] is Uint8List) {
        return result['bytes'] as Uint8List;
      }
      throw const NativePdfBridgeException(
          'استجابة غير متوقعة من الجسر الأصلي (نوع غير صحيح)');
    } on PlatformException catch (e) {
      throw NativePdfBridgeException(
          e.message ?? 'فشل الرسم في الجسر الأصلي', e.stacktrace);
    } finally {
      await sub?.cancel();
    }
  }

  static const EventChannel _progressEvents =
      EventChannel('pdf_master/native_pdf_progress');

  /// فحص بسيط متاح عند الإقلاع لمعرفة هل النظام يدعم الميزات المطلوبة
  /// (StaticLayout.Builder متاح من API 23+، والتطبيق min_sdk=21 — لذلك
  /// نوفّر تحققاً صريحاً ونرجع لرسالة خطأ واضحة إن فشل بدل تعطّل غامض).
  static Future<bool> isSupported() async {
    try {
      final result = await _channel.invokeMethod<bool>('isSupported');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }
}
