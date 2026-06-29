/// خدمة التعرف الضوئي على الحروف (OCR) — القلب الذي يدير محرك Tesseract.
///
/// لماذا Tesseract وليس Google ML Kit؟ تحقّق مباشر من توثيق Google
/// (developers.google.com/ml-kit/vision/text-recognition/v2): محرك Text
/// Recognition v2 الرسمي يدعم فقط سكريبتات الصينية/الديفاناغاري/
/// اليابانية/الكورية/اللاتينية. سكريبت العربية غير مدعوم إطلاقاً للتعرف
/// من صورة. لذلك Tesseract (نفس محرك Text Fairy) هو الخيار العملي الوحيد
/// للعربية+الإنجليزية معاً، عبر حزمة `flutter_tesseract_ocr` (تستخدم
/// Tesseract4Android تحت الغطاء، أندرويد فقط — وهذا يطابق نطاق المشروع
/// الذي لا يحتوي بنية iOS أصلاً).
///
/// نتفوّق على Text Fairy عبر:
///   1) معالجة مسبقة أدق (انظر image_preprocessing_service.dart).
///   2) تحليل خرج HOCR إلى موديل غني بصناديق إحداثيات + اتجاه نص بدل
///      نص مسطّح فقط، يسمح بتظليل تفاعلي للكلمات وبناء PDF قابل للبحث
///      حقيقي (انظر searchable_pdf_builder_service.dart).
///
/// قيد بيئة العمل: لا تتوفر هنا بيئة تشغيل Dart/Flutter فعلية. الكود
/// تم التحقق من صحته منطقياً وبموازنة أقواس فقط؛ الرجاء بناء المشروع
/// فعلياً وإرسال أي خطأ ترجمة أو نتائج فعلية للمراجعة.
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:xml/xml.dart';

import '../models/ocr_result_model.dart';
import 'image_preprocessing_service.dart';

/// أوضاع تقسيم الصفحة (Page Segmentation Mode) في Tesseract.
enum OcrLayoutMode {
  /// كتلة نص واحدة موحّدة — مناسب فقط حين تكون الصورة مُقتَصة بدقة على
  /// فقرة واحدة متصلة (بعد خطوة الاقتصاص اليدوي مثلاً)، لا لصفحة كاملة
  /// متعددة الفقرات/العناوين.
  singleBlock,

  /// اكتشاف تلقائي كامل للتخطيط (فقرات متعددة، عناوين، فواصل) — الافتراضي
  /// الآن لأنه الأصح لمعظم المستندات الحقيقية (نفس وضع Tesseract الافتراضي
  /// الذي تستخدمه أدوات OCR الناضجة كـ Text Fairy). ⚠️ إصلاح حقيقي: كان
  /// singleBlock الافتراضي في إصدار سابق، وهذا خاطئ لأي صورة فيها أكثر
  /// من فقرة/عنوان واحد متصل (الحالة الشائعة فعلياً) — psm=6 يفترض بنية
  /// "كتلة واحدة منتظمة" فيُسيء قراءة الفواصل بين فقرات/عناوين منفصلة.
  autoLayout,

  /// سطر واحد فقط (مناسب لصورة لافتة أو عنوان قصير).
  singleLine,
}

extension OcrLayoutModeX on OcrLayoutMode {
  /// قيمة psm المقابلة في Tesseract 4.
  String get psmValue {
    switch (this) {
      case OcrLayoutMode.singleBlock:
        return '6';
      case OcrLayoutMode.autoLayout:
        return '3';
      case OcrLayoutMode.singleLine:
        return '7';
    }
  }
}

/// لغة النص المطلوب التعرف عليه — يختارها المستخدم صريحاً قبل التشغيل
/// (نفس مبدأ "لغة النص الموجود" في Text Fairy)، بدل افتراض دمج تلقائي
/// ثابت دائماً. اختيار لغة واحدة فقط حين يكون النص أحادي اللغة فعلياً
/// يرفع دقة Tesseract ملموساً (نموذج لغة واحدة أدق من نموذج مدموج عند
/// عدم وجود خلط فعلي)، وهذا تحديداً سبب سؤال Text Fairy عن اللغة أولاً.
enum OcrLanguageSelection {
  /// عربي فقط — الأدق حين يكون النص عربياً خالصاً (لا أرقام/كلمات لاتينية).
  arabicOnly,

  /// إنجليزي فقط.
  englishOnly,

  /// كلا اللغتين معاً (نموذج مدموج) — الأنسب للنصوص المختلطة فعلياً
  /// (عربي بأرقام/مصطلحات إنجليزية)، وهو السلوك الوحيد المتاح في
  /// الإصدار السابق من هذه الأداة قبل إضافة هذا الاختيار.
  both,
}

extension OcrLanguageSelectionX on OcrLanguageSelection {
  String get tesseractCode {
    switch (this) {
      case OcrLanguageSelection.arabicOnly:
        return OcrService.arabicCode;
      case OcrLanguageSelection.englishOnly:
        return OcrService.englishCode;
      case OcrLanguageSelection.both:
        return '${OcrService.arabicCode}+${OcrService.englishCode}';
    }
  }

  /// رموز اللغات التي يجب التأكد من توفّر بياناتها فعلياً (قد تكون
  /// لغة واحدة فقط، لا داعٍ لضمان توفر الإنجليزية لو اختار المستخدم
  /// عربي فقط مثلاً).
  List<String> get requiredLanguageCodes {
    switch (this) {
      case OcrLanguageSelection.arabicOnly:
        return [OcrService.arabicCode];
      case OcrLanguageSelection.englishOnly:
        return [OcrService.englishCode];
      case OcrLanguageSelection.both:
        return [OcrService.arabicCode, OcrService.englishCode];
    }
  }
}

class OcrException implements Exception {
  final String message;
  const OcrException(this.message);
  @override
  String toString() => message;
}

class OcrService {
  /// مستودع بيانات اللغة الرسمي لـ Tesseract — يُستخدم فقط كخطة بديلة
  /// (fallback) إذا تعذّر العثور على ملف اللغة في أصول التطبيق المضمَّنة
  /// (انظر تعليق ensureLanguageDataAvailable لتفصيل المسار الأساسي).
  static const String _tessdataRepoBaseUrl =
      'https://github.com/tesseract-ocr/tessdata_fast/raw/main';

  static const String arabicCode = 'ara';
  static const String englishCode = 'eng';

  /// يتحقق من وجود ملفات tessdata المطلوبة (عربي + إنجليزي فقط) في
  /// مجلد التخزين الذي يقرأ منه Tesseract4Android، ويُحضّرها إن لم تكن
  /// موجودة بعد.
  ///
  /// ⚠️ المسار الأساسي الآن: نسخ من أصول التطبيق المضمَّنة (`assets/
  /// tessdata/ara.traineddata` و `assets/tessdata/eng.traineddata`،
  /// مُضمَّنة فعلياً في pubspec.yaml) — سريع جداً (نسخ محلي بلا شبكة)
  /// ويعمل بلا اتصال إنترنت من أول تشغيل. هذا أفضل تجربة مستخدم من
  /// التحميل الديناميكي (كان المسار الوحيد في إصدار سابق) لأن المستخدم
  /// لا ينتظر تحميل ملفات كبيرة (~17-23 ميجابايت) عبر الشبكة عند أول
  /// استخدام للأداة.
  ///
  /// ⚠️ إصلاح حقيقي محفوظ من الإصدار السابق (PathNotFoundException عند
  /// أول تشغيل): مجلد tessdata نفسه غير مضمون الوجود فعلياً على القرص
  /// عند أول تشغيل — الحزمة لا تُنشئه تلقائياً. نضمن إنشاءه
  /// (create(recursive: true)، بلا خطأ إن كان موجوداً مسبقاً) قبل أي
  /// قراءة أو كتابة.
  static Future<void> ensureLanguageDataAvailable({
    List<String> languageCodes = const ['ara', 'eng'],
    void Function(String language, double progress)? onProgress,
  }) async {
    final tessdataDir = await FlutterTesseractOcr.getTessdataPath();
    await Directory(tessdataDir).create(recursive: true);

    for (final lang in languageCodes) {
      final file = File('$tessdataDir/$lang.traineddata');
      if (await file.exists() && await file.length() > 0) {
        continue;
      }

      final copiedFromAssets = await _copyLanguageDataFromAssets(lang, tessdataDir);
      if (copiedFromAssets) continue;

      // خطة بديلة: لو لم يُعثَر على الملف ضمن أصول التطبيق المضمَّنة
      // (مثلاً نسيان تضمينه في pubspec.yaml، أو لغة إضافية لم تُرفَق)،
      // نُحاول التحميل من الإنترنت كما في الإصدار السابق، حتى لا تتعطّل
      // الأداة كلياً بصرف النظر عن السبب.
      await _downloadLanguageData(lang, tessdataDir, onProgress: onProgress);
    }
  }

  /// ينسخ ملف بيانات لغة واحدة من أصول التطبيق المضمَّنة إلى مجلد
  /// tessdata الفعلي على القرص. يُعيد true إن نجحت النسخة، false إن لم
  /// يُعثَر على الأصل (ليس خطأً بالضرورة — قد يكون مقصوداً للغات غير
  /// مرفَقة، فيُكمل المستدعي بمحاولة التحميل من الإنترنت بدلاً منه).
  static Future<bool> _copyLanguageDataFromAssets(String lang, String tessdataDir) async {
    final assetPath = 'assets/tessdata/$lang.traineddata';
    try {
      final byteData = await rootBundle.load(assetPath);
      final bytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      final file = File('$tessdataDir/$lang.traineddata');
      await file.writeAsBytes(bytes, flush: true);
      return true;
    } on FlutterError {
      // الأصل غير موجود ضمن الحزمة (rootBundle.load ترمي FlutterError
      // لا استثناء ملفات، لأنها تقرأ من حزمة الأصول المُجمَّعة لا من
      // نظام الملفات مباشرة) — نتعامل معه كحالة متوقَّعة، لا عطل.
      return false;
    }
  }

  static Future<void> _downloadLanguageData(
    String lang,
    String tessdataDir, {
    void Function(String language, double progress)? onProgress,
  }) async {
    final uri = Uri.parse('$_tessdataRepoBaseUrl/$lang.traineddata');
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw OcrException(
          'فشل تحميل بيانات لغة "$lang" (HTTP ${response.statusCode}). تحقق من الاتصال بالإنترنت.',
        );
      }

      final total = response.contentLength;
      final bytes = <int>[];
      var received = 0;
      await for (final chunk in response) {
        bytes.addAll(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress?.call(lang, received / total);
        }
      }

      final file = File('$tessdataDir/$lang.traineddata');
      await file.writeAsBytes(bytes, flush: true);
    } finally {
      client.close();
    }
  }

  /// ينفذ OCR على صورة واحدة بعد معالجتها المسبقة، ويُعيد نتيجة منظمة
  /// كاملة بصناديق الإحداثيات والاتجاه، بدل نص مسطّح فقط.
  ///
  /// ⚠️ ملاحظة أداء مهمة: استدعاء extractHocr يعمل عبر MethodChannel
  /// إلى Tesseract4Android (كود أصلي/native)، وهو CPU-heavy (قد يستغرق
  /// ثواني لصورة كبيرة). بخلاف DOCX/XLSX (انظر isolate_support.dart)،
  /// لا حاجة لتشغيله في Isolate منفصل لأن المعالجة الفعلية تحدث في
  /// Thread أصلي على جهة Kotlin/Java داخل المكوّن الإضافي نفسه (الـ
  /// MethodChannel call غير حاجز/non-blocking لواجهة Flutter)، فلا
  /// تتجمّد الواجهة أثناء التنفيذ رغم استدعائه من Main Isolate مباشرة.
  static Future<OcrPageResult> recognizeImage(
    File imageFile, {
    /// ⚠️ إصلاح حقيقي: الافتراضي السابق كان singleBlock (psm=6، يفترض
    /// بنية "كتلة نص واحدة منتظمة")، وهذا خاطئ لمعظم الصور الحقيقية
    /// (صفحة فيها عنوان + فقرات متعددة + نقاط منفصلة، كحالة صورتك
    /// التجريبية فعلياً) — Tesseract يُسيء قراءة الفواصل بين الفقرات
    /// تحت هذا الافتراض. autoLayout (psm=3) هو الوضع الذي تستخدمه أدوات
    /// OCR الناضجة كـ Text Fairy افتراضياً، فهو الأصح هنا أيضاً.
    OcrLayoutMode layoutMode = OcrLayoutMode.autoLayout,
    ImagePreprocessingOptions preprocessingOptions = const ImagePreprocessingOptions(),
    /// ⚠️ إضافة جديدة: لغة محدَّدة يختارها المستخدم صريحاً (نفس مبدأ
    /// "لغة النص الموجود" في Text Fairy)، بدل الدمج الثابت ara+eng
    /// دائماً. الافتراضي both يحافظ على سلوك الإصدار السابق لو لم
    /// يُمرَّر شيء.
    OcrLanguageSelection language = OcrLanguageSelection.both,
  }) async {
    final stopwatch = Stopwatch()..start();

    await ensureLanguageDataAvailable(languageCodes: language.requiredLanguageCodes);

    final preprocessed = await ImagePreprocessingService.process(
      imageFile,
      options: preprocessingOptions,
    );

    final hocr = await FlutterTesseractOcr.extractHocr(
      preprocessed.savedFile.path,
      language: language.tesseractCode,
      args: {
        'psm': layoutMode.psmValue,
        'preserve_interword_spaces': '1',
      },
    );

    final blocks = _parseHocrToBlocks(hocr);

    stopwatch.stop();

    return OcrPageResult(
      sourceImagePath: preprocessed.savedFile.path,
      imageWidthPx: preprocessed.widthPx,
      imageHeightPx: preprocessed.heightPx,
      blocks: blocks,
      processingTimeMs: stopwatch.elapsedMilliseconds,
    );
  }

  /// يحلل خرج HOCR (تنسيق HTML خاص بـ Tesseract يحتوي صناديق إحداثيات
  /// كل عنصر) إلى قائمة كتل نصية منظمة، مع تحديد اتجاه كل سطر تلقائياً.
  static List<OcrBlock> _parseHocrToBlocks(String hocrHtml) {
    final document = XmlDocument.parse(_sanitizeHocrForXmlParsing(hocrHtml));
    final blocks = <OcrBlock>[];

    final blockElements = document.findAllElements('div').where(
          (e) => (e.getAttribute('class') ?? '').contains('ocr_carea'),
        );

    for (final blockEl in blockElements) {
      final lines = <OcrLine>[];
      final lineElements = blockEl.findAllElements('span').where(
            (e) => (e.getAttribute('class') ?? '') == 'ocr_line',
          );

      for (final lineEl in lineElements) {
        final words = <OcrWord>[];
        final wordElements = lineEl.findAllElements('span').where(
              (e) => (e.getAttribute('class') ?? '') == 'ocrx_word',
            );

        for (final wordEl in wordElements) {
          final title = wordEl.getAttribute('title') ?? '';
          final box = _parseHocrBoundingBox(title);
          final confidence = _parseHocrConfidence(title);
          final text = wordEl.innerText.trim();
          if (text.isEmpty || box == null) continue;
          words.add(OcrWord(text: text, boundingBox: box, confidence: confidence));
        }

        if (words.isEmpty) continue;

        final lineBox = _parseHocrBoundingBox(lineEl.getAttribute('title') ?? '') ??
            _unionBoundingBox(words.map((w) => w.boundingBox).toList());

        final direction = _detectDirection(words.map((w) => w.text).join(' '));

        lines.add(OcrLine(words: words, boundingBox: lineBox, direction: direction));
      }

      if (lines.isEmpty) continue;

      final blockBox = _parseHocrBoundingBox(blockEl.getAttribute('title') ?? '') ??
          _unionBoundingBox(lines.map((l) => l.boundingBox).toList());

      blocks.add(OcrBlock(lines: lines, boundingBox: blockBox));
    }

    return blocks;
  }

  /// HOCR من Tesseract قد يحتوي وسوماً غير مُغلَقة بصرامة XML (كـ <br>
  /// أو <meta> بدون إغلاق ذاتي)، لذا نُطبّع الخرج قبل تحليله.
  static String _sanitizeHocrForXmlParsing(String hocr) {
    return hocr
        .replaceAll(RegExp(r'<br\s*>', caseSensitive: false), '<br/>')
        .replaceAll(RegExp(r'<meta([^>]*)(?<!/)>', caseSensitive: false), '<meta\$1/>');
  }

  /// يحلل سلسلة "title" في عنصر HOCR لاستخراج صندوق الإحداثيات، بصيغة:
  /// "bbox 10 20 100 50; x_wconf 87".
  static OcrBoundingBox? _parseHocrBoundingBox(String title) {
    final match = RegExp(r'bbox (\d+) (\d+) (\d+) (\d+)').firstMatch(title);
    if (match == null) return null;
    final left = double.parse(match.group(1)!);
    final top = double.parse(match.group(2)!);
    final right = double.parse(match.group(3)!);
    final bottom = double.parse(match.group(4)!);
    return OcrBoundingBox(left: left, top: top, width: right - left, height: bottom - top);
  }

  static double _parseHocrConfidence(String title) {
    final match = RegExp(r'x_wconf (\d+)').firstMatch(title);
    if (match == null) return 0;
    return double.parse(match.group(1)!);
  }

  static OcrBoundingBox _unionBoundingBox(List<OcrBoundingBox> boxes) {
    if (boxes.isEmpty) {
      return const OcrBoundingBox(left: 0, top: 0, width: 0, height: 0);
    }
    double left = boxes.first.left, top = boxes.first.top;
    double right = boxes.first.right, bottom = boxes.first.bottom;
    for (final b in boxes.skip(1)) {
      if (b.left < left) left = b.left;
      if (b.top < top) top = b.top;
      if (b.right > right) right = b.right;
      if (b.bottom > bottom) bottom = b.bottom;
    }
    return OcrBoundingBox(left: left, top: top, width: right - left, height: bottom - top);
  }

  /// يحدد اتجاه الكتابة (RTL/LTR) لسطر نصي حسب نسبة الأحرف العربية فيه
  /// (نطاق يونيكود U+0600–U+06FF، يشمل التشكيل والأرقام الهندية العربية).
  static OcrTextDirection _detectDirection(String text) {
    final arabicMatches = RegExp(r'[\u0600-\u06FF]').allMatches(text).length;
    final latinMatches = RegExp(r'[A-Za-z]').allMatches(text).length;
    if (arabicMatches == 0 && latinMatches == 0) return OcrTextDirection.ltr;
    return arabicMatches >= latinMatches ? OcrTextDirection.rtl : OcrTextDirection.ltr;
  }
}
