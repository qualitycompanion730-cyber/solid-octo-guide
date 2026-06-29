// isolate_support.dart
//
// ───────────────────────────────────────────────────────────────────────
// تشغيل تحويلات DOCX / PPT / XLSX الثقيلة في isolate منفصل عن الخيط
// الرئيسي (UI thread)، مع الحفاظ الكامل على تقدّم حيّ وإلغاء فعلي.
//
// ── إصلاح جذري لمشكلة DOCX عند 45% (لا يزال سارياً) ──────────────────
// المشكلة المؤكَّدة:
//   BackgroundIsolateBinaryMessenger.ensureInitialized() +
//   messenger.send('flutter/assets', ...) داخل Worker Isolate
//   → يُرجع null → type 'Null' is not a subtype of type 'List<dynamic>'
//   → TimeoutException: Timeout loading asset: assets/fonts/Amiri-Regular.ttf
//   → التوقف الكامل عند 45% (مرحلة "تحميل الخطوط").
//
// الحل المطبَّق (كما كان):
//   • حُذف BackgroundIsolateBinaryMessenger و RootIsolateToken من DOCX كلياً.
//   • الخطوط تُحمَّل في Main Isolate عبر loadAllFontsOnMainIsolate()
//     (rootBundle يعمل هنا بشكل موثوق).
//   • تُمرَّر إلى Worker Isolate كـ Map<String, Uint8List> ضمن _DocxArgs.
//
// ── تعديل إضافي عند إعادة البناء على الجسر الأصلي (NativePdfBridge) ──
// MethodChannel (المُستخدَم في NativePdfBridge.renderDocument) يعاني من
// نفس مشكلة قنوات المنصّة داخل Worker Isolate التي عانت منها rootBundle:
// لا يعمل بشكل موثوق إلا من Main Isolate. لذلك أُعيد تقسيم العمل:
//   • DocxToPdfConverter.parseToLayout() (تحليل DOCX فقط، بلا أي قناة
//     منصّة) يبقى يُنفَّذ بالكامل في Worker Isolate كما كان _convert سابقاً.
//   • نتيجته PdfDocSpec (نموذج Dart عادي بالكامل — قابل للإرسال عبر
//     SendPort مباشرة دون أي قيد، لأنه لا يحوي أي مرجع لمنصّة أو Flutter
//     binding) تُرسَل إلى Main Isolate.
//   • NativePdfBridge.renderDocument(spec) يُستدعى من Main Isolate بعد
//     استقبال PdfDocSpec، فيُنتج بايتات PDF النهائية فعلياً.
//
// PPT و XLSX: لا تعانيان من مشكلة تحميل الخطوط الأصلية، لكنهما ستحتاجان
//   نفس إعادة التقسيم (تحليل في Worker Isolate يُعيد PdfDocSpec، رسم في
//   Main Isolate) عند تحويلهما لاحقاً لاستخدام الجسر الأصلي بدل Syncfusion.
// ───────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show RootIsolateToken;

import '../pdf_engine/native_pdf_bridge.dart';
import '../pdf_engine/pdf_layout_model.dart';
import 'docx_to_pdf_converter.dart';
import 'html_to_pdf_converter.dart';
import 'ppt_to_pdf_converter.dart';
import 'txt_to_pdf_converter.dart';
import 'xlsx_to_pdf_converter.dart';

// =====================================================================
// مساعد عام: تشغيل isolate واحد مع تقدّم وإلغاء حقيقيَّين
// =====================================================================

/// رسالة الانطلاق المُمرَّرة إلى نقطة دخول isolate جديد.
/// [rootIsolateToken] اختياري — يُمرَّر لـ PPT/XLSX فقط (تحتاج BGIBM)،
/// وتكون null لـ DOCX (لا تستخدم BGIBM إطلاقاً).
class _SpawnArgs<TPayload> {
  final TPayload payload;
  final SendPort mainSendPort;
  final RootIsolateToken? rootIsolateToken; // null لـ DOCX عمداً

  const _SpawnArgs(this.payload, this.mainSendPort, this.rootIsolateToken);
}

/// خطأ داخلي لنقل فشل/إلغاء العامل إلى الكود المستدعي.
class _IsolateFailure implements Exception {
  final String message;
  final bool cancelled;
  const _IsolateFailure({required this.message, required this.cancelled});

  @override
  String toString() => message;
}

/// ينفّذ [entryPoint] في isolate منفصل ويُعيد القيمة الخام كما أُرسلت من
/// العامل دون أي افتراض مسبق لنوعها (Uint8List لـ PPT، PdfDocSpec لـ
// ignore: unintended_html_in_doc_comment
/// DOCX بعد إعادة البناء على الجسر الأصلي، أو List<dynamic> لـ XLSX).
/// المستدعي مسؤول عن تحويل النتيجة (as T) إلى النوع المتوقَّع فعلياً.
Future<dynamic> _runIsolate<TPayload>({
  required TPayload payload,
  required void Function(_SpawnArgs<TPayload>) entryPoint,
  void Function(double progress, String stage)? onProgress,
  bool Function()? isCancelledNow,
  bool needsRootToken = false, // true لـ PPT/XLSX فقط
}) async {
  final RootIsolateToken? rootToken =
      needsRootToken ? RootIsolateToken.instance : null;

  if (needsRootToken && rootToken == null) {
    throw StateError(
        'تعذّر الحصول على RootIsolateToken — لا يمكن تشغيل المعالجة في خلفية منفصلة من هذا السياق.');
  }

  final mainPort = ReceivePort();
  final completer = Completer<dynamic>();
  SendPort? workerPort;
  Timer? poller;
  Isolate? isolate;
  bool finished = false;

  void cleanup() {
    finished = true;
    poller?.cancel();
    mainPort.close();
    isolate?.kill(priority: Isolate.immediate);
  }

  mainPort.listen((message) {
    if (finished) return;

    if (message is SendPort) {
      // المصافحة الأولى: SendPort الخاص بالعامل لاستقبال طلبات الإلغاء.
      workerPort = message;
      return;
    }

    if (message is List && message.isNotEmpty) {
      switch (message[0]) {
        case 'p':
          onProgress?.call(message[1] as double, message[2] as String);
          return;
        case 'r':
          // ⚠️ لا نفترض نوعاً محدداً هنا (كان سابقاً hard-cast إلى
          // Uint8List، وهذا كان يفشل بـ TypeError فوراً عند استخدام هذا
          // المسار لإرسال أي نوع آخر كـ PdfDocSpec). نُمرّر القيمة كما هي؛
          // المستدعي (مثل convertDocxInBackground) يحوّلها للنوع المتوقَّع.
          if (!completer.isCompleted) completer.complete(message[1]);
          cleanup();
          return;
        case 'rx':
          if (!completer.isCompleted) {
            completer.complete(<dynamic>[
              message[1] as Uint8List,
              message[2] as int,
              message[3] as int,
            ]);
          }
          cleanup();
          return;
        case 'e':
          if (!completer.isCompleted) {
            completer.completeError(_IsolateFailure(
              message: message[1] as String,
              cancelled: message[2] as bool,
            ));
          }
          cleanup();
          return;
      }
    }

    // رسالة غير متوقعة (انهيار في العامل قبل أي رسالة منظَّمة) —
    // نضمن أن الـ Future لا يبقى معلَّقاً للأبد.
    if (!completer.isCompleted) {
      completer.completeError(_IsolateFailure(
        message: 'فشل غير متوقع داخل المعالجة الخلفية: $message',
        cancelled: false,
      ));
    }
    cleanup();
  });

  try {
    isolate = await Isolate.spawn<_SpawnArgs<TPayload>>(
      entryPoint,
      _SpawnArgs<TPayload>(payload, mainPort.sendPort, rootToken),
      onError: mainPort.sendPort,
      errorsAreFatal: false,
    );
  } catch (e) {
    cleanup();
    rethrow;
  }

  if (isCancelledNow != null) {
    poller = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (finished) return;
      if (isCancelledNow()) {
        workerPort?.send('cancel');
      }
    });
  }

  return completer.future;
}

// =====================================================================
// DOCX — بدون BackgroundIsolateBinaryMessenger نهائياً
// =====================================================================

/// بيانات Worker Isolate الخاص بـ DOCX.
/// [preloadedFonts]: كامل الخطوط محمَّلة مسبقاً في Main Isolate،
// ignore: unintended_html_in_doc_comment
/// تُمرَّر كـ Map<String, Uint8List> — لا يُلمس rootBundle داخل الـ Isolate.
class _DocxArgs {
  final String filePath;
  final Map<String, Uint8List> preloadedFonts;
  const _DocxArgs(this.filePath, this.preloadedFonts);
}

/// نقطة دخول Worker Isolate الخاص بـ DOCX.
/// ⚠️ لا يوجد BackgroundIsolateBinaryMessenger.ensureInitialized هنا —
/// الخطوط وصلت جاهزة عبر args.payload.preloadedFonts.
/// ⚠️ يُعيد PdfDocSpec فقط (تحليل بلا رسم) — لا يستدعي NativePdfBridge
/// إطلاقاً لأن MethodChannel لا يعمل بشكل موثوق من Worker Isolate.
void _docxIsolateEntry(_SpawnArgs<_DocxArgs> args) async {
  // لا نستدعي BackgroundIsolateBinaryMessenger.ensureInitialized عمداً —
  // هذا هو جوهر الإصلاح: لا حاجة لأي قناة flutter/assets هنا، ولا لأي
  // MethodChannel (الرسم الفعلي ينتقل إلى Main Isolate بعد هذه الدالة).

  final workerPort = ReceivePort();
  args.mainSendPort.send(workerPort.sendPort); // المصافحة

  final cancelToken = DocxCancelToken();
  workerPort.listen((msg) {
    if (msg == 'cancel') cancelToken.cancel();
  });

  try {
    final spec = await DocxToPdfConverter.parseToLayout(
      File(args.payload.filePath),
      cancelToken: cancelToken,
      preloadedFonts: args.payload.preloadedFonts, // الخطوط جاهزة
      onProgress: (p) => args.mainSendPort.send(['p', p.progress, p.stage]),
    );
    // PdfDocSpec كائن Dart عادي بالكامل (بلا أي مرجع لمنصّة/Flutter
    // binding)، فهو قابل للإرسال مباشرة عبر SendPort بلا أي تحويل إضافي.
    args.mainSendPort.send(['r', spec]);
  } on DocxCancelledException {
    args.mainSendPort.send(['e', 'تم إلغاء التحويل', true]);
  } catch (e) {
    args.mainSendPort.send(['e', e.toString(), false]);
  } finally {
    workerPort.close();
  }
}

/// يحوّل ملف Word إلى PDF.
///
/// التدفّق الكامل:
///   1. تحميل الخطوط في Main Isolate عبر [loadAllFontsOnMainIsolate]
///      (rootBundle يعمل هنا بشكل موثوق).
///   2. تسجيل هذه الخطوط في الجسر الأصلي عبر NativePdfBridge.registerFonts
///      (يجب أن يحدث من Main Isolate أيضاً — MethodChannel).
///   3. تشغيل التحليل الثقيل (ZIP/XML/بناء PdfDocSpec) في Worker Isolate
///      عبر [_docxIsolateEntry] — لا يلمس rootBundle ولا MethodChannel.
///   4. استقبال PdfDocSpec من العامل في Main Isolate.
///   5. استدعاء NativePdfBridge.renderDocument(spec) من Main Isolate —
///      هذا ما يولِّد بايتات PDF الفعلية عبر Minikin/HarfBuzz/Skia.
Future<Uint8List> convertDocxInBackground(
  File file, {
  void Function(DocxConversionProgress)? onProgress,
  DocxCancelToken? cancelToken,
}) async {
  // ── المرحلة 1: تحميل الخطوط في Main Isolate ─────────────────────────
  onProgress?.call(const DocxConversionProgress(0.03, 'تحضير الخطوط...'));

  final Map<String, Uint8List> fonts;
  try {
    fonts = await loadAllFontsOnMainIsolate();
  } catch (e) {
    throw DocxConversionException('فشل تحميل الخطوط قبل بدء التحويل: $e');
  }

  if (cancelToken?.isCancelled == true) throw const DocxCancelledException();

  // ── المرحلة 2: تسجيل الخطوط في الجسر الأصلي (Main Isolate) ──────────
  // نُسجّل وفق _FontReg.catalog (مصدر الحقيقة الوحيد لربط مفتاح العائلة
  // بمسار ملف الأصل)، بدل أي تخمين من اسم الملف، لضمان تطابق المفاتيح
  // تماماً مع ما يُعيده runFamily()/_FontReg.resolve() في DocxToPdfConverter.
  try {
    await NativePdfBridge.registerFonts(
      DocxToPdfConverter.buildFontRegistrationsFromCatalog(fonts),
    );
  } catch (e) {
    throw DocxConversionException('فشل تسجيل الخطوط في الجسر الأصلي: $e');
  }

  if (cancelToken?.isCancelled == true) throw const DocxCancelledException();

  // ── المرحلة 3: تشغيل Worker Isolate للتحليل فقط (يُعيد PdfDocSpec) ──
  final PdfDocSpec spec;
  try {
    final result = await _runIsolate<_DocxArgs>(
      payload: _DocxArgs(file.path, fonts),
      entryPoint: _docxIsolateEntry,
      onProgress: (p, stage) =>
          onProgress?.call(DocxConversionProgress(p * 0.7, stage)),
      isCancelledNow:
          cancelToken == null ? null : () => cancelToken.isCancelled,
      needsRootToken: false, // DOCX لا يحتاج RootIsolateToken
    );
    spec = result as PdfDocSpec;
  } on _IsolateFailure catch (f) {
    if (f.cancelled) throw const DocxCancelledException();
    throw DocxConversionException(f.message);
  }

  if (cancelToken?.isCancelled == true) throw const DocxCancelledException();

  // ── المرحلة 4: الرسم الفعلي في الجسر الأصلي (Main Isolate) ──────────
  onProgress?.call(const DocxConversionProgress(0.75, 'رسم المستند...'));
  try {
    final bytes = await NativePdfBridge.renderDocument(
      spec,
      onProgress: (p, stage) =>
          onProgress?.call(DocxConversionProgress(0.75 + p * 0.25, stage)),
    );
    onProgress?.call(const DocxConversionProgress(1.0, 'اكتمل التحويل!'));
    return bytes;
  } on NativePdfBridgeException catch (e) {
    throw DocxConversionException('فشل الرسم في الجسر الأصلي: ${e.message}');
  }
}

// =====================================================================
// PPT — أُعيد بناؤه على نفس نمط DOCX/XLSX (تحليل في Worker Isolate يُعيد
// PdfDocSpec، رسم فعلي عبر NativePdfBridge من Main Isolate). لم يكن هذا
// الملف يستدعي rootBundle أصلاً (الشاشة كانت تُحمّل خط NotoNaskhArabic في
// Main Isolate مسبقاً وتُمرّر مساره على القرص كنص)، لكن بعد إعادة البناء
// لم تعد هناك حاجة لهذا التمرير عبر القرص: نُسجّل خطوط الجسر الأصلي مرة
// واحدة (نفس كتالوج DOCX، يحوي NotoNaskhArabic/LiberationSans المطلوبَين
// هنا) قبل استدعاء التحليل، فتُصبح متاحة للرسم النهائي مباشرة.
// =====================================================================

class _PptArgs {
  final String filePath;
  final PptConversionOptions options;
  const _PptArgs(this.filePath, this.options);
}

/// نقطة دخول Worker Isolate الخاص بـ PPT.
/// ⚠️ لا BackgroundIsolateBinaryMessenger، لا rootBundle — يُعيد PdfDocSpec
/// فقط (تحليل بلا رسم)؛ الرسم الفعلي ينتقل إلى Main Isolate بعد هذه الدالة.
void _pptIsolateEntry(_SpawnArgs<_PptArgs> args) async {
  final workerPort = ReceivePort();
  args.mainSendPort.send(workerPort.sendPort);

  final cancelToken = PptCancelToken();
  workerPort.listen((msg) {
    if (msg == 'cancel') cancelToken.cancel();
  });

  try {
    final spec = await PptToPdfConverter.parseToLayout(
      File(args.payload.filePath),
      options: args.payload.options,
      cancelToken: cancelToken,
      onProgress: (p) => args.mainSendPort.send(['p', p.progress, p.stage]),
    );
    // PdfDocSpec كائن Dart عادي بالكامل — قابل للإرسال مباشرة عبر SendPort.
    args.mainSendPort.send(['r', spec]);
  } on PptCancelledException {
    args.mainSendPort.send(['e', 'تم إلغاء التحويل', true]);
  } catch (e) {
    args.mainSendPort.send(['e', e.toString(), false]);
  } finally {
    workerPort.close();
  }
}

/// يحوّل ملف PowerPoint/ODP إلى PDF.
///
/// التدفّق: تسجيل خطوط الجسر الأصلي في Main Isolate → تشغيل التحليل
/// الثقيل في Worker Isolate (يُعيد PdfDocSpec) → استدعاء
/// NativePdfBridge.renderDocument من Main Isolate لتوليد بايتات PDF
/// الفعلية.
Future<Uint8List> convertPptInBackground(
  File file, {
  PptConversionOptions options = const PptConversionOptions(),
  void Function(PptConversionProgress)? onProgress,
  PptCancelToken? cancelToken,
}) async {
  // ── المرحلة 1: تحميل وتسجيل الخطوط في Main Isolate ──────────────────
  onProgress?.call(const PptConversionProgress(0.01, 'تحضير الخطوط...'));
  final Map<String, Uint8List> fonts;
  try {
    fonts = await loadAllFontsOnMainIsolate();
  } catch (e) {
    throw PptConversionException('فشل تحميل الخطوط قبل بدء التحويل: $e');
  }

  if (cancelToken?.isCancelled == true) throw const PptCancelledException();

  try {
    await NativePdfBridge.registerFonts(
      DocxToPdfConverter.buildFontRegistrationsFromCatalog(fonts),
    );
  } catch (e) {
    throw PptConversionException('فشل تسجيل الخطوط في الجسر الأصلي: $e');
  }

  if (cancelToken?.isCancelled == true) throw const PptCancelledException();

  // ── المرحلة 2: تشغيل Worker Isolate للتحليل فقط ──────────────────────
  final PdfDocSpec spec;
  try {
    final result = await _runIsolate<_PptArgs>(
      payload: _PptArgs(file.path, options),
      entryPoint: _pptIsolateEntry,
      onProgress: (p, stage) =>
          onProgress?.call(PptConversionProgress(p * 0.65, stage)),
      isCancelledNow:
          cancelToken == null ? null : () => cancelToken.isCancelled,
      needsRootToken: false, // لم تعد هناك حاجة لـ BackgroundIsolateBinaryMessenger
    );
    spec = result as PdfDocSpec;
  } on _IsolateFailure catch (f) {
    if (f.cancelled) throw const PptCancelledException();
    throw PptConversionException(f.message);
  }

  if (cancelToken?.isCancelled == true) throw const PptCancelledException();

  // ── المرحلة 3: الرسم الفعلي في الجسر الأصلي (Main Isolate) ──────────
  onProgress?.call(const PptConversionProgress(0.70, 'رسم الشرائح...'));
  try {
    final bytes = await NativePdfBridge.renderDocument(
      spec,
      onProgress: (p, stage) =>
          onProgress?.call(PptConversionProgress(0.70 + p * 0.30, stage)),
    );
    onProgress?.call(const PptConversionProgress(1.0, 'اكتمل التحويل!'));
    return bytes;
  } on NativePdfBridgeException catch (e) {
    throw PptConversionException('فشل الرسم في الجسر الأصلي: ${e.message}');
  }
}

// =====================================================================
// XLSX — أُعيد بناؤه على نفس نمط DOCX (تحليل في Worker Isolate يُعيد
// PdfDocSpec، رسم فعلي عبر NativePdfBridge من Main Isolate). كان يستخدم
// BackgroundIsolateBinaryMessenger سابقاً لأن PdfFontManager.initialize()
// كان يستدعي rootBundle مباشرة داخل Worker Isolate — نفس فئة المشكلة التي
// شُخِّصت وأُصلحت لـ DOCX. الإصلاح هنا مماثل: الخطوط تُحمَّل في Main
// Isolate (نُعيد استخدام loadAllFontsOnMainIsolate من docx_to_pdf_converter.dart
// لأنها تحمّل Cairo/LiberationSans المطلوبَين هنا أيضاً ضمن كتالوجها
// الكامل) وتُمرَّر جاهزة، فلا حاجة لـ BackgroundIsolateBinaryMessenger
// إطلاقاً بعد الآن.
// =====================================================================

class _XlsxArgs {
  final String filePath;
  final List<String> selectedSheetNames;
  final Map<String, Uint8List> preloadedFonts;
  const _XlsxArgs(
      this.filePath, this.selectedSheetNames, this.preloadedFonts);
}

/// نقطة دخول Worker Isolate الخاص بـ XLSX.
/// ⚠️ لا BackgroundIsolateBinaryMessenger، لا rootBundle — الخطوط جاهزة
/// عبر args.payload.preloadedFonts. يُعيد XlsxLayoutResult فقط (تحليل
/// بلا رسم)؛ الرسم الفعلي ينتقل إلى Main Isolate بعد هذه الدالة.
void _xlsxIsolateEntry(_SpawnArgs<_XlsxArgs> args) async {
  final workerPort = ReceivePort();
  args.mainSendPort.send(workerPort.sendPort);

  final cancelToken = XlsxCancelToken();
  workerPort.listen((msg) {
    if (msg == 'cancel') cancelToken.cancel();
  });

  try {
    final result = await XlsxToPdfConverter.parseSheetsToLayout(
      File(args.payload.filePath),
      selectedSheetNames: args.payload.selectedSheetNames,
      cancelToken: cancelToken,
      preloadedFonts: args.payload.preloadedFonts,
      onProgress: (p) => args.mainSendPort.send(['p', p.progress, p.stage]),
    );
    // XlsxLayoutResult (يحوي PdfDocSpec + rowCount) كائن Dart عادي بالكامل
    // — قابل للإرسال مباشرة عبر SendPort بلا أي تحويل إضافي.
    args.mainSendPort.send(['r', result]);
  } on XlsxCancelledException {
    args.mainSendPort.send(['e', 'تم إلغاء التحويل', true]);
  } catch (e) {
    args.mainSendPort.send(['e', e.toString(), false]);
  } finally {
    workerPort.close();
  }
}

/// يحوّل أوراق Excel/CSV/TSV المختارة إلى PDF.
///
/// التدفّق: تحميل خطوط القياس في Main Isolate → تشغيل التحليل الثقيل في
/// Worker Isolate (يُعيد XlsxLayoutResult) → استدعاء
/// NativePdfBridge.renderDocument من Main Isolate لتوليد بايتات PDF
/// الفعلية → تجميع XlsxConversionResult النهائي للواجهة.
Future<XlsxConversionResult> convertXlsxSheetsInBackground(
  File file, {
  required List<String> selectedSheetNames,
  XlsxCancelToken? cancelToken,
  void Function(XlsxConversionProgress)? onProgress,
}) async {
  // ── المرحلة 1: تحميل خطوط القياس في Main Isolate ────────────────────
  onProgress?.call(const XlsxConversionProgress(0.01, 'تحضير الخطوط...'));
  final Map<String, Uint8List> fonts;
  try {
    fonts = await loadAllFontsOnMainIsolate();
  } catch (e) {
    throw XlsxConversionException('فشل تحميل الخطوط قبل بدء التحويل: $e');
  }

  if (cancelToken?.isCancelled == true) throw const XlsxCancelledException();

  // ── المرحلة 2: تسجيل خطوط الرسم الفعلي في الجسر الأصلي ───────────────
  // نسجّل نفس كتالوج DOCX الكامل (لا كتالوج خاص بـ XLSX) لأن خلايا XLSX
  // قد تحتاج أي عائلة عربية كانت متاحة في المستند الأصلي مستقبلاً، ولأن
  // إعادة تسجيل خطوط مسجَّلة سلفاً غير مكلفة. هذا يضمن أيضاً تطابق أسماء
  // العائلات بين DOCX و XLSX إن استُخدم كلاهما بنفس التطبيق بالتتابع.
  try {
    await NativePdfBridge.registerFonts(
      DocxToPdfConverter.buildFontRegistrationsFromCatalog(fonts),
    );
  } catch (e) {
    throw XlsxConversionException('فشل تسجيل الخطوط في الجسر الأصلي: $e');
  }

  if (cancelToken?.isCancelled == true) throw const XlsxCancelledException();

  // ── المرحلة 3: تشغيل Worker Isolate للتحليل فقط ──────────────────────
  final XlsxLayoutResult layoutResult;
  try {
    final raw = await _runIsolate<_XlsxArgs>(
      payload: _XlsxArgs(file.path, selectedSheetNames, fonts),
      entryPoint: _xlsxIsolateEntry,
      onProgress: (p, stage) =>
          onProgress?.call(XlsxConversionProgress(p * 0.6, stage)),
      isCancelledNow:
          cancelToken == null ? null : () => cancelToken.isCancelled,
      needsRootToken: false, // لم تعد هناك حاجة لـ BackgroundIsolateBinaryMessenger
    );
    layoutResult = raw as XlsxLayoutResult;
  } on _IsolateFailure catch (f) {
    if (f.cancelled) throw const XlsxCancelledException();
    throw XlsxConversionException(f.message);
  }

  if (cancelToken?.isCancelled == true) throw const XlsxCancelledException();

  // ── المرحلة 4: الرسم الفعلي في الجسر الأصلي (Main Isolate) ──────────
  onProgress?.call(const XlsxConversionProgress(0.65, 'رسم الملف...'));
  try {
    final bytes = await NativePdfBridge.renderDocument(
      layoutResult.spec,
      onProgress: (p, stage) =>
          onProgress?.call(XlsxConversionProgress(0.65 + p * 0.35, stage)),
    );
    onProgress?.call(const XlsxConversionProgress(1.0, 'اكتمل التحويل!'));
    return XlsxConversionResult(
      bytes: bytes,
      rowCount: layoutResult.rowCount,
      // كل صفحة في layoutResult.spec.pages تقابل صفحة PDF فعلية واحدة
      // بالضبط لأن isPrecomposed=true (لا تجزئة إضافية تحدث في الجسر
      // الأصلي لهذا النوع من الصفحات) — فعدد الصفحات معروف مسبقاً بدقة.
      pageCount: layoutResult.spec.pages.length,
    );
  } on NativePdfBridgeException catch (e) {
    throw XlsxConversionException('فشل الرسم في الجسر الأصلي: ${e.message}');
  }
}

// =====================================================================
// HTML — جديد بالكامل. لم يكن هذا الملف مُغلَّفاً بـ Isolate من قبل
// إطلاقاً (لأن lib/screens/tools/html_to_pdf_screen.dart لم يكن يستخدم
// html_to_pdf_converter.dart أصلاً — كان يحتوي منطق Regex مستقلاً يعمل
// على Main Isolate مباشرة، فيُجمِّد واجهة المستخدم على ملفات كبيرة). هذا
// القسم يُصلح ذلك عبر نفس نمط DOCX/XLSX/PPT: تحليل في Worker Isolate
// يُعيد PdfDocSpec، رسم فعلي عبر NativePdfBridge من Main Isolate.
// =====================================================================

class _HtmlArgs {
  final String htmlContent;
  final HtmlConversionOptions options;
  const _HtmlArgs(this.htmlContent, this.options);
}

void _htmlIsolateEntry(_SpawnArgs<_HtmlArgs> args) async {
  final workerPort = ReceivePort();
  args.mainSendPort.send(workerPort.sendPort);

  final cancelToken = HtmlCancelToken();
  workerPort.listen((msg) {
    if (msg == 'cancel') cancelToken.cancel();
  });

  try {
    final spec = await HtmlToPdfConverter.parseToLayout(
      args.payload.htmlContent,
      options: args.payload.options,
      cancelToken: cancelToken,
      onProgress: (p) => args.mainSendPort.send(['p', p.progress, p.stage]),
    );
    args.mainSendPort.send(['r', spec]);
  } on HtmlCancelledException {
    args.mainSendPort.send(['e', 'تم إلغاء التحويل', true]);
  } catch (e) {
    args.mainSendPort.send(['e', e.toString(), false]);
  } finally {
    workerPort.close();
  }
}

/// يحوّل ملف HTML إلى PDF.
///
/// يقرأ الملف كنص في Main Isolate (قراءة ملف عادية، لا rootBundle)، ثم
/// يُشغّل التحليل الثقيل (تحليل وسوم HTML، استخراج الكتل) في Worker
/// Isolate، ثم يستدعي NativePdfBridge.renderDocument من Main Isolate
/// لتوليد بايتات PDF الفعلية.
Future<Uint8List> convertHtmlInBackground(
  File file, {
  HtmlConversionOptions options = const HtmlConversionOptions(),
  void Function(HtmlConversionProgress)? onProgress,
  HtmlCancelToken? cancelToken,
}) async {
  onProgress?.call(const HtmlConversionProgress(0.02, 'قراءة الملف...'));
  final String htmlContent;
  try {
    htmlContent = await file.readAsString();
  } catch (e) {
    throw HtmlConversionException('تعذّر قراءة الملف: $e');
  }

  if (cancelToken?.isCancelled == true) throw const HtmlCancelledException();

  // الخطوط: تُسجَّل في الجسر الأصلي من نفس كتالوج DOCX المشترك (يحوي
  // Cairo/Amiri/NotoNaskhArabic — أي منها كافٍ هنا فالمحتوى العربي يُرسم
  // بعائلة واحدة محدَّدة في _mapBlocksToDocSpec وهي NotoNaskhArabic).
  final Map<String, Uint8List> fonts;
  try {
    fonts = await loadAllFontsOnMainIsolate();
  } catch (e) {
    throw HtmlConversionException('فشل تحميل الخطوط قبل بدء التحويل: $e');
  }
  if (cancelToken?.isCancelled == true) throw const HtmlCancelledException();

  try {
    await NativePdfBridge.registerFonts(
      DocxToPdfConverter.buildFontRegistrationsFromCatalog(fonts),
    );
  } catch (e) {
    throw HtmlConversionException('فشل تسجيل الخطوط في الجسر الأصلي: $e');
  }
  if (cancelToken?.isCancelled == true) throw const HtmlCancelledException();

  final PdfDocSpec spec;
  try {
    final result = await _runIsolate<_HtmlArgs>(
      payload: _HtmlArgs(htmlContent, options),
      entryPoint: _htmlIsolateEntry,
      onProgress: (p, stage) =>
          onProgress?.call(HtmlConversionProgress(p * 0.6, stage)),
      isCancelledNow:
          cancelToken == null ? null : () => cancelToken.isCancelled,
      needsRootToken: false,
    );
    spec = result as PdfDocSpec;
  } on _IsolateFailure catch (f) {
    if (f.cancelled) throw const HtmlCancelledException();
    throw HtmlConversionException(f.message);
  }

  if (cancelToken?.isCancelled == true) throw const HtmlCancelledException();

  onProgress?.call(const HtmlConversionProgress(0.65, 'رسم المستند...'));
  try {
    final bytes = await NativePdfBridge.renderDocument(
      spec,
      onProgress: (p, stage) =>
          onProgress?.call(HtmlConversionProgress(0.65 + p * 0.35, stage)),
    );
    onProgress?.call(const HtmlConversionProgress(1.0, 'اكتمل التحويل!'));
    return bytes;
  } on NativePdfBridgeException catch (e) {
    throw HtmlConversionException('فشل الرسم في الجسر الأصلي: ${e.message}');
  }
}

// =====================================================================
// TXT — جديد بالكامل، بنفس مبرر إضافة HTML أعلاه: txt_to_pdf_converter.dart
// لم يكن مُغلَّفاً بـ Isolate من قبل (راجع الشاشة المقابلة؛ نفس فئة
// المشكلة المحتملة لملفات نصية كبيرة).
// =====================================================================

class _TxtArgs {
  final String textContent;
  final TxtConversionOptions options;
  const _TxtArgs(this.textContent, this.options);
}

void _txtIsolateEntry(_SpawnArgs<_TxtArgs> args) async {
  final workerPort = ReceivePort();
  args.mainSendPort.send(workerPort.sendPort);

  final cancelToken = TxtCancelToken();
  workerPort.listen((msg) {
    if (msg == 'cancel') cancelToken.cancel();
  });

  try {
    final spec = await TxtToPdfConverter.parseToLayout(
      args.payload.textContent,
      options: args.payload.options,
      cancelToken: cancelToken,
      onProgress: (p) => args.mainSendPort.send(['p', p.progress, p.stage]),
    );
    args.mainSendPort.send(['r', spec]);
  } on TxtCancelledException {
    args.mainSendPort.send(['e', 'تم إلغاء التحويل', true]);
  } catch (e) {
    args.mainSendPort.send(['e', e.toString(), false]);
  } finally {
    workerPort.close();
  }
}

/// يحوّل ملف نصي (TXT) إلى PDF.
Future<Uint8List> convertTxtInBackground(
  File file, {
  TxtConversionOptions options = const TxtConversionOptions(),
  void Function(TxtConversionProgress)? onProgress,
  TxtCancelToken? cancelToken,
}) async {
  onProgress?.call(const TxtConversionProgress(0.02, 'قراءة الملف...'));
  final String textContent;
  try {
    textContent = await file.readAsString();
  } catch (e) {
    throw TxtConversionException('تعذّر قراءة الملف: $e');
  }

  if (cancelToken?.isCancelled == true) throw const TxtCancelledException();

  final Map<String, Uint8List> fonts;
  try {
    fonts = await loadAllFontsOnMainIsolate();
  } catch (e) {
    throw TxtConversionException('فشل تحميل الخطوط قبل بدء التحويل: $e');
  }
  if (cancelToken?.isCancelled == true) throw const TxtCancelledException();

  try {
    await NativePdfBridge.registerFonts(
      DocxToPdfConverter.buildFontRegistrationsFromCatalog(fonts),
    );
  } catch (e) {
    throw TxtConversionException('فشل تسجيل الخطوط في الجسر الأصلي: $e');
  }
  if (cancelToken?.isCancelled == true) throw const TxtCancelledException();

  final PdfDocSpec spec;
  try {
    final result = await _runIsolate<_TxtArgs>(
      payload: _TxtArgs(textContent, options),
      entryPoint: _txtIsolateEntry,
      onProgress: (p, stage) =>
          onProgress?.call(TxtConversionProgress(p * 0.6, stage)),
      isCancelledNow:
          cancelToken == null ? null : () => cancelToken.isCancelled,
      needsRootToken: false,
    );
    spec = result as PdfDocSpec;
  } on _IsolateFailure catch (f) {
    if (f.cancelled) throw const TxtCancelledException();
    throw TxtConversionException(f.message);
  }

  if (cancelToken?.isCancelled == true) throw const TxtCancelledException();

  onProgress?.call(const TxtConversionProgress(0.65, 'رسم المستند...'));
  try {
    final bytes = await NativePdfBridge.renderDocument(
      spec,
      onProgress: (p, stage) =>
          onProgress?.call(TxtConversionProgress(0.65 + p * 0.35, stage)),
    );
    onProgress?.call(const TxtConversionProgress(1.0, 'اكتمل التحويل!'));
    return bytes;
  } on NativePdfBridgeException catch (e) {
    throw TxtConversionException('فشل الرسم في الجسر الأصلي: ${e.message}');
  }
}
