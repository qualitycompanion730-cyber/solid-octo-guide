// ═══════════════════════════════════════════════════════════════════════════
//  DocxToPdfConverter — تحويل DOCX إلى PDF عبر الجسر الأصلي لأندرويد
//  المكتبات: archive + xml (تحليل) + NativePdfBridge (رسم عبر Minikin/
//  HarfBuzz/Skia الحقيقي — بديل Syncfusion الذي كان يُفسد تشكيل العربي)
// ═══════════════════════════════════════════════════════════════════════════
//
//  ── ملخص إعادة البناء ──────────────────────────────────────────────────
//  • التحليل (ZIP→XML→نموذج _Block/_Paragraph/_Run/_Table/...) لم يتغيّر:
//    هذا منطق OOXML بحت لا علاقة له بمحرك الرسم، ويبقى كما كان بالضبط.
//  • حُذف بالكامل: _PdfWriter وكل ما فيها (رسم Syncfusion المباشر)، ومحرك
//    التشكيل/الترتيب البصري اليدوي _Arabic (كان معطوباً جزئياً — يُستبدل
//    حروفاً بـ ﷺ ويُسقط أخرى، انظر التعليق التاريخي أسفل تعريف hasArabic في arabic_text_utils.dart).
//  • أُضيف: _mapBlocksToDocSpec(...) يحوّل List<_Block> إلى PdfDocSpec
//    (نموذج تصريحي)، يُمرَّر إلى NativePdfBridge.renderDocument() الذي
//    يرسم فعلياً عبر StaticLayout على الجهة الأصلية (Kotlin)، فيستفيد من
//    اكتشاف الاتجاه والتشكيل العربي الحقيقي لنظام أندرويد نفسه.
//  • أُعيد ترتيب الـ Isolates: التحليل وبناء PdfDocSpec يبقيان في Worker
//    Isolate كما كانا (لا يحتاجان rootBundle أو أي قناة منصّة)، لكن
//    NativePdfBridge.renderDocument() (الذي يستخدم MethodChannel) يجب أن
//    يُستدعى من Main Isolate فقط — قنوات المنصّة لا تعمل بشكل موثوق من
//    Worker Isolates (نفس الدرس المستفاد من مشكلة تحميل الخطوط السابقة في
//    isolate_support.dart). لذلك convertDocxInBackground() الآن: يُشغّل
//    التحليل في Worker Isolate وتُعاد PdfDocSpec عبر SendPort، ثم يُستدعى
//    الجسر الأصلي من Main Isolate بعد استقبالها.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as imglib;
import 'package:xml/xml.dart';

import '../pdf_engine/native_pdf_bridge.dart' show FontRegistration;
import '../pdf_engine/pdf_layout_model.dart';
import 'shared/arabic_text_utils.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  تحميل الأصول — يعمل فقط في الخيط الرئيسي (Main Isolate)
// ─────────────────────────────────────────────────────────────────────────────
//  ⚠️ هذه الدالة مخصصة للاستدعاء من Main Isolate فقط قبل إطلاق Worker Isolate.
//  لا يجوز استدعاؤها من داخل أي Worker Isolate لأن rootBundle يتطلب
//  ServicesBinding المتوفر في الخيط الرئيسي فقط.
//  الخطوط تُحمَّل هنا ثم تُمرَّر كـ Uint8List عبر DocxIsolateArgs.
// ─────────────────────────────────────────────────────────────────────────────

/// تحميل asset من الخيط الرئيسي فقط.
Future<Uint8List?> loadFontAssetOnMainIsolate(String key) async {
  try {
    final data = await rootBundle.load(key);
    return data.buffer.asUint8List();
  } catch (e) {
    // ⚠️ إصلاح خلل تشخيصي حقيقي: كان الفشل هنا صامتاً تماماً (catch (_))
    // بلا أي أثر، فكان فشل تحميل خط عريض (Bold) معيّن يتسبب بصمت بتراجع
    // resolveTypeface في NativePdfRenderer.kt إلى "بدّل سميك" (faux-bold
    // عبر Typeface.create(..., Typeface.BOLD))، الذي يُظهر هالة/تخطيطاً
    // مزدوجاً حول الحروف الغامقة — هذا الخلل بالضبط ظهر فعلياً في اختبار
    // PPTX على جهاز حقيقي (عنوان الشريحة الأولى وعناوين الجداول الغامقة)
    // دون أي رسالة تشرح السبب. الآن نسجّل تحذيراً واضحاً بدل الصمت.
    debugPrint('⚠️ فشل تحميل أصل الخط "$key": $e — سيُستخدَم بدّل سميك '
        'تركيبي (faux-bold) إن كان هذا مساراً لخط عريض، مما يُظهر هالة '
        'حول الحروف. تحقق من وجود الملف فعلياً في assets/fonts/ ومطابقة '
        'الاسم تماماً (حساس لحالة الأحرف).');
    return null;
  }
}

/// تحميل كامل سجل الخطوط في الخيط الرئيسي.
/// يُستدعى قبل إطلاق Worker Isolate ويُمرَّر نتيجته عبر DocxIsolateArgs.
Future<Map<String, Uint8List>> loadAllFontsOnMainIsolate() async {
  final result = <String, Uint8List>{};
  for (final entry in _FontReg.catalog) {
    final regPath = entry[1] as String;
    final boldPath = entry[2] as String;
    final regKey = regPath; // المفتاح هو المسار نفسه
    final boldKey = boldPath;
    if (!result.containsKey(regKey)) {
      final bytes = await loadFontAssetOnMainIsolate(regPath);
      if (bytes != null) result[regKey] = bytes;
    }
    if (!result.containsKey(boldKey)) {
      final bytes = await loadFontAssetOnMainIsolate(boldPath);
      if (bytes != null) result[boldKey] = bytes;
    }
  }
  return result;
}

// ─────────────────────────────────────────────────────────────────────────────
//  الكلاسات العامة (متوافقة مع word_to_pdf_screen.dart)
// ─────────────────────────────────────────────────────────────────────────────

class DocxConversionProgress {
  final double progress;
  final String stage;
  const DocxConversionProgress(this.progress, this.stage);
}

class DocxCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class DocxConversionException implements Exception {
  final String message;
  const DocxConversionException(this.message);
  @override
  String toString() => message;
}

class DocxCancelledException implements Exception {
  const DocxCancelledException();
  @override
  String toString() => 'تم إلغاء التحويل';
}

// ─────────────────────────────────────────────────────────────────────────────
//  نماذج داخلية
// ─────────────────────────────────────────────────────────────────────────────

/// ⚠️ إصلاح حقيقي (انعكاس محاذاة مزدوج في Dart لفقرات RTL بمحاذاة صريحة):
/// قبل هذا الإصلاح كانت قيمتا start/end تُستخدَمان لتمثيل *كل من* الاتجاه
/// النسبي (w:jc="start"/"end" الفعلي، النادر) *و* الاتجاه المطلق
/// (w:jc="left"/"right"، الشائع جداً) معاً بنفس القيمتين — فتطلّب التمييز
/// بينهما عكساً يدوياً حسب paraRtl في _parseParagraph، ثم عكساً ثانياً
/// مكرراً بلا فائدة في mapAlign (لنفس الغرض المُفترَض خطأً: "ترجمة"
/// start/end إلى left/right مرة أخرى). النتيجة: قيمة "left"/"right"
/// الواصلة إلى الجسر الأصلي (NativePdfRenderer.kt) كانت بالفعل معكوسة
/// عن w:jc الأصلي في DOCX قبل أن تصله أصلاً — فمعالجته الصحيحة والضرورية
/// هناك لتحويل left/right المطلقتين إلى ALIGN_NORMAL/ALIGN_OPPOSITE
/// النسبيين لـAndroid (انظر تعليق textAlignment في NativePdfRenderer.kt
/// لتفصيل: هاتان القيمتان نسبيتان لاتجاه الفقرة في Android نفسه، فعكسها
/// هناك حسب direction ضروري وصحيح فنياً ولم يكن الخلل) كانت تُطبَّق على
/// مدخل خاطئ من الأساس، فتُعرَض فقرة عربية بمحاذاة w:jc="left" الصريحة
/// (يسار الصفحة المطلق وفق OOXML) معكوسة (يمين الصفحة فعلياً) في PDF
/// النهائي. left/right الجديدتان هنا تمثّلان القيمة *المطلقة* فقط (تطابق
/// w:jc="left"/"right" حرفياً، بصرف النظر عن paraRtl)، فتمران بلا أي عكس
/// عبر طبقتي Dart كلتيهما، تاركتين العكس الضروري الوحيد لجسر Kotlin حيث
/// ينتمي فعلياً. start/end تبقيان محصورتين بمعناهما *النسبي* الأصلي
/// (w:jc="start"/"end" الفعلي من OOXML، ولمحاذاة الصور/الأشكال التي
/// تعتمد عليه أصلاً في أماكن أخرى من هذا الملف) ولا تُستخدَمان بعد الآن
/// مطلقاً لتمثيل left/right.
enum _Align { start, center, end, justify, left, right }

enum _ListType { bullet, numbered }

/// نتيجة استخراج زخرفة الصفحة (خلفية/إطار/علامة مائية) من XML — تُحوَّل
/// لاحقاً إلى حقول PdfPageSpec.backgroundColorArgb/pageBorder/watermark.
/// بديل الحقول التي كانت تُضبط مباشرة على _PdfWriter في الإصدار السابق.
class _PageDecorations {
  final String? backgroundHex;
  final bool borderOn;
  final double borderWidthPt;
  final String? borderHex;
  final bool borderShadow;
  final String? watermarkText;
  final String? watermarkHex;

  const _PageDecorations({
    this.backgroundHex,
    this.borderOn = false,
    this.borderWidthPt = 1.0,
    this.borderHex,
    this.borderShadow = false,
    this.watermarkText,
    this.watermarkHex,
  });
}

/// يحوّل لون hex (مع/بدون #، 6 خانات) إلى صيغة ARGB كاملة الشفافية
/// (0xFFRRGGBB) التي يتوقعها النموذج الجديد. يُعيد [fallback] عند الفشل.
int _hexToArgb(String? hex, {int fallback = 0xFF000000}) {
  if (hex == null) return fallback;
  var h = hex.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length != 6) return fallback;
  final v = int.tryParse(h, radix: 16);
  if (v == null) return fallback;
  return 0xFF000000 | v;
}

/// تحويل رقم إلى حرف ترقيم (1->a, 26->z, 27->aa ...) — يُستخدم لعناصر
/// القوائم المرقّمة بنمط lowerLetter/upperLetter (w:numFmt).
/// (منقول بلا تعديل من _PdfWriter._toLetter في الإصدار السابق.)
String _toLetter(int n, bool upper) {
  final sb = StringBuffer();
  var v = n;
  while (v > 0) {
    v--;
    sb.write(String.fromCharCode((upper ? 65 : 97) + (v % 26)));
    v ~/= 26;
  }
  return sb.toString().split('').reversed.join();
}

/// تحويل رقم إلى ترقيم روماني — يُستخدم لعناصر القوائم المرقّمة بنمط
/// lowerRoman/upperRoman. (منقول بلا تعديل من _PdfWriter._toRoman.)
String _toRoman(int n) {
  if (n <= 0) return '$n';
  const vals = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
  const syms = [
    'M',
    'CM',
    'D',
    'CD',
    'C',
    'XC',
    'L',
    'XL',
    'X',
    'IX',
    'V',
    'IV',
    'I'
  ];
  final sb = StringBuffer();
  var v = n;
  for (var i = 0; i < vals.length; i++) {
    while (v >= vals[i]) {
      sb.write(syms[i]);
      v -= vals[i];
    }
  }
  return sb.toString();
}

// وجود حروف عربية/RTL في النص (لتحديد الاتجاه عند غياب w:bidi)


// ⚠️ ملاحظة تاريخية: كان هنا محرك تشكيل عربي/ترتيب ثنائي الاتجاه (Bidi) يدوي
// مكتوب بالكامل في Dart (الأصناف _Arabic و _BidiSeg)، أُضيف أصلاً لأن
// Syncfusion's PdfTextDirection.rightToLeft كان معطوباً: يستبدل حروفاً
// عربية برمز ﷺ (U+FDFA) ويُسقط حروفاً أخرى. بعد الانتقال لمحرك أندرويد
// الأصلي (StaticLayout عبر Minikin/HarfBuzz في NativePdfRenderer.kt),
// أصبح هذا المحرك اليدوي زائداً تماماً وحُذف: النص الآن يُمرَّر بترتيبه
// المنطقي كما استُخرج من XML، ويتولى النظام الأصلي كل التشكيل/الترتيب
// البصري بدقة أكبر من أي تطبيق يدوي.

// ألوان تمييز النص (w:highlight) — أسماء Word القياسية إلى hex
String? _highlightHex(String? name) {
  if (name == null || name.isEmpty || name == 'none') return null;
  const map = {
    'yellow': 'FFFF00',
    'green': '00FF00',
    'cyan': '00FFFF',
    'magenta': 'FF00FF',
    'blue': '0000FF',
    'red': 'FF0000',
    'darkBlue': '000080',
    'darkCyan': '008080',
    'darkGreen': '008000',
    'darkMagenta': '800080',
    'darkRed': '800000',
    'darkYellow': '808000',
    'darkGray': '808080',
    'lightGray': 'C0C0C0',
    'black': '000000',
    'white': 'FFFFFF',
  };
  return map[name];
}

// ════════════════════════════════════════════════════════════════════════
//  نظام مطابقة الخطوط: يقرأ اسم الخط من Word (w:rFonts) ويختار الخط المضمّن
//  المطابق، أو أقرب بديل عند غيابه. الخطوط البديلة مكافئة مقاسياً للأصلية.
// ════════════════════════════════════════════════════════════════════════
class _FontFamily {
  final Uint8List regular;
  final Uint8List? bold;
  final bool arabic;
  const _FontFamily(this.regular, this.bold, this.arabic);
}

class _FontReg {
  // كتالوج الخطوط: [مفتاح، ملف عادي، ملف عريض، عربي؟]
  // البدائل الحرة مكافئة مقاسياً لخطوط Word المغلقة:
  //   Carlito≈Calibri، Caladea≈Cambria، LiberationSans≈Arial،
  //   LiberationSerif≈Times New Roman، LiberationMono≈Courier New،
  //   Gelasio≈Georgia، EBGaramond≈Garamond.
  static const List<List<dynamic>> catalog = [
    // ── العربية ──
    [
      'Amiri',
      'assets/fonts/Amiri-Regular.ttf',
      'assets/fonts/Amiri-Bold.ttf',
      true
    ],
    [
      'ScheherazadeNew',
      'assets/fonts/ScheherazadeNew-Regular.ttf',
      'assets/fonts/ScheherazadeNew-Bold.ttf',
      true
    ],
    [
      'NotoNaskhArabic',
      'assets/fonts/NotoNaskhArabic-Regular.ttf',
      'assets/fonts/NotoNaskhArabic-Bold.ttf',
      true
    ],
    [
      'NotoSansArabic',
      'assets/fonts/NotoSansArabic-Regular.ttf',
      'assets/fonts/NotoSansArabic-Bold.ttf',
      true
    ],
    [
      'NotoKufiArabic',
      'assets/fonts/NotoKufiArabic-Regular.ttf',
      'assets/fonts/NotoKufiArabic-Bold.ttf',
      true
    ],
    [
      'Cairo',
      'assets/fonts/Cairo-Regular.ttf',
      'assets/fonts/Cairo-Bold.ttf',
      true
    ],
    [
      'Tajawal',
      'assets/fonts/Tajawal-Regular.ttf',
      'assets/fonts/Tajawal-Bold.ttf',
      true
    ],
    [
      'Almarai',
      'assets/fonts/Almarai-Regular.ttf',
      'assets/fonts/Almarai-Bold.ttf',
      true
    ],
    // ── اللاتينية ──
    [
      'Carlito',
      'assets/fonts/Carlito-Regular.ttf',
      'assets/fonts/Carlito-Bold.ttf',
      false
    ],
    [
      'Caladea',
      'assets/fonts/Caladea-Regular.ttf',
      'assets/fonts/Caladea-Bold.ttf',
      false
    ],
    [
      'LiberationSans',
      'assets/fonts/LiberationSans-Regular.ttf',
      'assets/fonts/LiberationSans-Bold.ttf',
      false
    ],
    [
      'LiberationSerif',
      'assets/fonts/LiberationSerif-Regular.ttf',
      'assets/fonts/LiberationSerif-Bold.ttf',
      false
    ],
    [
      'LiberationMono',
      'assets/fonts/LiberationMono-Regular.ttf',
      'assets/fonts/LiberationMono-Bold.ttf',
      false
    ],
    [
      'Gelasio',
      'assets/fonts/Gelasio-Regular.ttf',
      'assets/fonts/Gelasio-Bold.ttf',
      false
    ],
    [
      'EBGaramond',
      'assets/fonts/EBGaramond-Regular.ttf',
      'assets/fonts/EBGaramond-Bold.ttf',
      false
    ],
    // ── خطوط عربية إضافية (مُعلَنة في pubspec.yaml) ──
    [
      'Lateef',
      'assets/fonts/Lateef-Regular.ttf',
      'assets/fonts/Lateef-Bold.ttf',
      true
    ],
    [
      'ReemKufi',
      'assets/fonts/ReemKufi-Regular.ttf',
      'assets/fonts/ReemKufi-Bold.ttf',
      true
    ],
    [
      'Harmattan',
      'assets/fonts/Harmattan-Regular.ttf',
      'assets/fonts/Harmattan-Bold.ttf',
      true
    ],
    [
      'Mirza',
      'assets/fonts/Mirza-Regular.ttf',
      'assets/fonts/Mirza-Bold.ttf',
      true
    ],
    [
      'MarkaziText',
      'assets/fonts/MarkaziText-Regular.ttf',
      'assets/fonts/MarkaziText-Bold.ttf',
      true
    ],
    [
      'IBMPlexArabic',
      'assets/fonts/IBMPlexArabic-Regular.ttf',
      'assets/fonts/IBMPlexArabic-Bold.ttf',
      true
    ],
    [
      'ArefRuqaa',
      'assets/fonts/ArefRuqaa-Regular.ttf',
      'assets/fonts/ArefRuqaa-Bold.ttf',
      true
    ],
    // ── خطوط لاتينية إضافية (مُعلَنة في pubspec.yaml) ──
    [
      'Merriweather',
      'assets/fonts/Merriweather-Regular.ttf',
      'assets/fonts/Merriweather-Bold.ttf',
      false
    ],
    [
      'Lato',
      'assets/fonts/Lato-Regular.ttf',
      'assets/fonts/Lato-Bold.ttf',
      false
    ],
    [
      'OpenSans',
      'assets/fonts/OpenSans-Regular.ttf',
      'assets/fonts/OpenSans-Bold.ttf',
      false
    ],
    [
      'RobotoSlab',
      'assets/fonts/RobotoSlab-Regular.ttf',
      'assets/fonts/RobotoSlab-Bold.ttf',
      false
    ],
    [
      'SourceSerif4',
      'assets/fonts/SourceSerif4-Regular.ttf',
      'assets/fonts/SourceSerif4-Bold.ttf',
      false
    ],
    [
      'PTSans',
      'assets/fonts/PTSans-Regular.ttf',
      'assets/fonts/PTSans-Bold.ttf',
      false
    ],
    [
      'Nunito',
      'assets/fonts/Nunito-Regular.ttf',
      'assets/fonts/Nunito-Bold.ttf',
      false
    ],
  ];

  // أسماء خطوط Word العربية → مفتاح الخط المضمّن
  static const Map<String, String> arabicNames = {
    'amiri': 'Amiri',
    'times new roman': 'Amiri',
    'traditional arabic': 'ScheherazadeNew',
    'arabic typesetting': 'ScheherazadeNew',
    'scheherazade': 'ScheherazadeNew',
    'scheherazade new': 'ScheherazadeNew',
    'lateef': 'Lateef',
    'simplified arabic': 'NotoNaskhArabic',
    'noto naskh arabic': 'NotoNaskhArabic',
    'arial': 'NotoSansArabic',
    'tahoma': 'NotoSansArabic',
    'noto sans arabic': 'NotoSansArabic',
    'segoe ui': 'Cairo',
    'sakkal majalla': 'Cairo',
    'dubai': 'Tajawal',
    'cairo': 'Cairo',
    'tajawal': 'Tajawal',
    'almarai': 'Almarai',
    'noto kufi arabic': 'NotoKufiArabic',
    // خطوط عربية إضافية
    'reem kufi': 'ReemKufi',
    'reem kufi ink': 'ReemKufi',
    'harmattan': 'Harmattan',
    'mirza': 'Mirza',
    'markazi text': 'MarkaziText',
    'ibm plex arabic': 'IBMPlexArabic',
    'aref ruqaa': 'ArefRuqaa',
    'amiri quran': 'Amiri',
  };

  // أسماء خطوط Word اللاتينية → مفتاح الخط المضمّن
  static const Map<String, String> latinNames = {
    'calibri': 'Carlito',
    'calibri light': 'Carlito',
    'cambria': 'Caladea',
    'cambria math': 'Caladea',
    'arial': 'LiberationSans',
    'arial narrow': 'LiberationSans',
    'helvetica': 'LiberationSans',
    'verdana': 'LiberationSans',
    'tahoma': 'LiberationSans',
    'segoe ui': 'LiberationSans',
    'trebuchet ms': 'LiberationSans',
    'times new roman': 'LiberationSerif',
    'times': 'LiberationSerif',
    'book antiqua': 'LiberationSerif',
    'palatino linotype': 'LiberationSerif',
    'courier new': 'LiberationMono',
    'consolas': 'LiberationMono',
    'courier': 'LiberationMono',
    'georgia': 'Gelasio',
    'garamond': 'EBGaramond',
    'eb garamond': 'EBGaramond',
    // ⚠️ إصلاح حقيقي (فجوة صامتة) + تصحيح ذاتي: "Comic Sans MS" لم يكن له
    // أي إدخال هنا قبل هذا الإصلاح، فيتراجع صامتاً لـdefLatin (الافتراضي
    // المسطح) بلا أي إشارة. لا يوجد حالياً أي خط زخرفي/يدوي الشكل
    // (مثل Comic Neue، المكافئ الحر المعياري لـComic Sans) ضمن خطوط
    // pubspec.yaml المُجمَّعة فعلاً في هذا المشروع — إضافة خط جديد تتطلب
    // حزمة أصول (asset) فعلية لا تتوفر هنا، فالإشارة لمفتاح غير مسجَّل
    // كانت ستتراجع صامتاً للافتراضي تماماً كما كان الحال (لا تغيير فعلي
    // حقيقي، وهمي فقط). الحل الصادق المتاح الآن: توجيهه لـCaladea (سيريف
    // ودّي الشكل، أبعد بصرياً عن الافتراضي المسطح Carlito من أي خط آخر
    // مُجمَّع) كأقرب تمييز بصري متاح فعلياً، بدل بقائه بلا أي معالجة على
    // الإطلاق. لتطابق بصري حقيقي مطلوب لاحقاً: أضف Comic Neue (الرخصة:
    // SIL Open Font License) إلى assets/fonts/ + pubspec.yaml + جدول
    // التسجيل أعلاه (نفس نمط الإدخالات الأخرى)، ثم بدّل المفتاح هنا لـ
    // 'ComicNeue'.
    'comic sans ms': 'Caladea',
    'comic sans': 'Caladea',
    // خطوط لاتينية إضافية
    'merriweather': 'Merriweather',
    'lato': 'Lato',
    'open sans': 'OpenSans',
    'roboto slab': 'RobotoSlab',
    'source serif 4': 'SourceSerif4',
    'source serif pro': 'SourceSerif4',
    'pt sans': 'PTSans',
    'pt sans caption': 'PTSans',
    'nunito': 'Nunito',
    'nunito sans': 'Nunito',
    'century gothic': 'Nunito',
    'franklin gothic medium': 'PTSans',
    'rockwell': 'RobotoSlab',
    'gill sans mt': 'Lato',
  };

  // ⚠️ إصلاح حقيقي (فجوة مطابقة أحادية الاتجاه) + تصحيح ذاتي خطير لاحق:
  // يختار مفتاح العائلة المناسب لاسم خط Word حسب النص (عربي/لاتيني)، ولا
  // يُرجع إلا مفتاحاً موجوداً فعلاً في السجل، وإلا الافتراضي.
  //
  // المحاولة الأولى لهذا الإصلاح كانت تسمح لنص عربي غير مُطابَق في
  // arabicNames بتجريب latinNames كاملةً كبديل احتياطي — بنفس تناظر
  // latinNames المُجرِّبة فعلاً arabicNames عند فشل تطابقها (لخطوط مشتركة
  // كـ"Tahoma"). لكن هذا خاطئ وخطير لاتجاه عربي←لاتيني تحديداً: معظم
  // مفاتيح latinNames (Carlito/Caladea/LiberationSerif/LiberationMono/
  // Gelasio/EBGaramond...) هي خطوط Latin-only بحتة (تأكَّد هذا فعلياً
  // بالبحث: Gelasio مثلاً يدعم فقط Google Fonts Latin Pro glyph set، لا
  // أي تغطية عربية إطلاقاً) — فلو أعاد الكود "Gelasio" لنص عربي مكتوب
  // بخط "Georgia" (موجود فقط في latinNames)، ستظهر الحروف العربية كصناديق
  // فارغة (.notdef) أو فراغاً تاماً، بدل حتى السلوك القديم (سقوط صامت
  // للافتراضي العربي المقروء بدلاً منه). التناظر الصحيح للاتجاه اللاتيني
  // (latinNames تُجرِّب arabicNames) كان سليماً أصلاً لأن خطوط arabicNames
  // كلها (Amiri/Cairo/Tajawal/NotoSansArabic/...) تحمل أيضاً Glyphs لاتينية
  // كاملة كجزء من تصميمها القياسي (كل خط عربي حديث يغطّي الأرقام/الحروف
  // اللاتينية الأساسية ضمناً)، فلا خطر مطابق هناك.
  //
  // الإصلاح الصحيح: يفحص علم arabic الفعلي في _FontReg.catalog لأي مفتاح
  // يُجرَّب من الخريطة "المعاكسة" قبل قبوله — لا يُقبَل مفتاح غير مُعلَّم
  // arabic:true لنص عربي (يحافظ هذا تماماً على الأمان القديم لذاك
  // الاتجاه)، بينما يبقى مفتاح من arabicNames مقبولاً دوماً لنص لاتيني
  // (الاتجاه الآمن أصلاً، بلا تغيير). النتيجة العملية: نص عربي بخط
  // "Georgia"/"Courier New"/"Comic Sans MS" (غائبة عن arabicNames تماماً)
  // يستمر بالسقوط لـdefArabic كما كان دوماً — وهو فعلاً السلوك الصحيح
  // الوحيد المتاح حالياً، إذ لا يوجد خط عربي "مكافئ" حقيقي لهذه الخطوط
  // اللاتينية الزخرفية الثلاثة في الكتالوج المُجمَّع بعد (يتطلب إضافة خط
  // عربي جديد فعلياً للأصول، تماماً كحالة Comic Sans المُوثَّقة أعلاه في
  // latinNames، لا إصلاحاً برمجياً صرفاً). يبقى الإصلاح المفيد فعلياً
  // محصوراً لحالات الأسماء *المشتركة* الفعلية بين الخريطتين (مثل لو أُضيف
  // مستقبلاً اسم مثل "Segoe UI" لخريطة واحدة فقط سهواً).
  static String resolve(
    String? csName,
    String? asciiName,
    bool isArabic,
    Map<String, _FontFamily> reg,
    String defArabic,
    String defLatin,
  ) {
    final raw =
        (isArabic ? (csName ?? asciiName) : (asciiName ?? csName)) ?? '';
    final n = raw.toLowerCase().trim();
    String? key = isArabic ? arabicNames[n] : latinNames[n];
    // لم يُطابَق في الخريطة "الطبيعية" لاتجاه النص؟ جرّب الخريطة الأخرى،
    // لكن لنص عربي تحديداً لا نقبل مفتاحاً إلا إن كان مُعلَّماً arabic:true
    // فعلياً في الكتالوج (راجع التعليق أعلاه: خطوط latinNames غالباً
    // Latin-only ولا تصح بديلاً لنص عربي، خلافاً لخطوط arabicNames التي
    // تغطّي اللاتينية أصلاً فتصلح دوماً بديلاً لنص لاتيني).
    if (key == null) {
      final fallbackKey = isArabic ? latinNames[n] : arabicNames[n];
      if (fallbackKey != null) {
        final isFallbackArabicFont = reg[fallbackKey]?.arabic ?? false;
        if (!isArabic || isFallbackArabicFont) key = fallbackKey;
      }
    }
    if (key != null && reg.containsKey(key)) return key;
    return isArabic ? defArabic : defLatin;
  }
}

class _Run {
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike; // شطب النص (w:strike / w:dstrike)
  /// ⚠️ إصلاح حقيقي (أنماط التسطير/الشطب المتعددة): قبل هذا الإصلاح كان
  /// w:u/@val يُقرَأ فقط كـ Boolean (underline أعلاه)، فتُعامَل كل أنماط
  /// التسطير (single/double/wave/dotted/dashed/none) بنفس الخط البسيط،
  /// وw:dstrike (الشطب المزدوج) كان يُعامَل بنفس معاملة w:strike المفرد
  /// (كلاهما يضبط strike=true فقط بلا تمييز). يقابل هذا الحقل قيمة
  /// w:u/@val الفعلية المُطابِقة لأسماء Kotlin (انظر underlineStyle في
  /// PdfFontSpec): "single"|"double"|"wave"|"dotted"|"dashed".
  final String underlineStyle;
  /// true فقط إن كان العنصر الفعلي في XML هو w:dstrike (لا w:strike).
  final bool strikeDouble;
  final double fontSize;
  final String? colorHex;
  final String? highlightHex; // لون تمييز خلفية النص (w:highlight)
  final double
      baselineShift; // إزاحة عمودية: سالب=أعلى (super)، موجب=أسفل (sub)
  final double letterSpacing; // تباعد الأحرف (w:spacing) بالنقاط
  final String? fontNameCs; // اسم الخط للنص المعقّد/العربي (w:rFonts w:cs)
  final String? fontNameAscii; // اسم الخط اللاتيني (w:rFonts w:ascii/hAnsi)
  final bool rtl;
  final String? linkUri; // رابط خارجي قابل للنقر (hyperlink r:id → target)
  final String? linkAnchor; // رابط داخلي قابل للنقر (hyperlink w:anchor)
  final List<String> footnoteIds; // معرّفات هوامش يشير إليها هذا المقطع

  const _Run({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.underlineStyle = 'single',
    this.strikeDouble = false,
    this.fontSize = 12,
    this.colorHex,
    this.highlightHex,
    this.baselineShift = 0,
    this.letterSpacing = 0,
    this.fontNameCs,
    this.fontNameAscii,
    this.rtl = true,
    this.linkUri,
    this.linkAnchor,
    this.footnoteIds = const [],
  });

  /// نسخة معدَّلة مع تغيير حقول محدَّدة فقط — يُستخدَم في
  /// _splitParagraphOnPageBreaks لإعادة بناء run بنص مقسوم مع الحفاظ
  /// التام على كل تنسيقه (خط/لون/تسطير/رابط…).
  _Run copyWith({String? text}) => _Run(
        text: text ?? this.text,
        bold: bold,
        italic: italic,
        underline: underline,
        strike: strike,
        underlineStyle: underlineStyle,
        strikeDouble: strikeDouble,
        fontSize: fontSize,
        colorHex: colorHex,
        highlightHex: highlightHex,
        baselineShift: baselineShift,
        letterSpacing: letterSpacing,
        fontNameCs: fontNameCs,
        fontNameAscii: fontNameAscii,
        rtl: rtl,
        linkUri: linkUri,
        linkAnchor: linkAnchor,
        footnoteIds: footnoteIds,
      );
}

/// ⚠️ إضافة جديدة (هوامش الصفحة الحقيقية من w:pgMar) — انظر تعليق
/// _sectMargins الكامل لتفصيل المشكلة. حزمة بسيطة لكل القيم الستة
/// المُستخرَجة من w:pgMar لقسم واحد، كلها بالنقاط (محوَّلة من twips).
class _SectionMargins {
  final double top, bottom, left, right, header, footer;
  const _SectionMargins({
    required this.top,
    required this.bottom,
    required this.left,
    required this.right,
    required this.header,
    required this.footer,
  });
}

/// ⚠️ إضافة جديدة (فهرس المحتويات الحقيقي) — انظر تعليق tocHeadings في
/// نقطة بنائه الكامل لتفصيل المشكلة الكاملة وسبب الحاجة لهذا الكلاس.
/// إدخال فهرس واحد: نص العنوان كما يظهر في DOCX (بصرف النظر عن ترقيمه
/// اليدوي مثل "1." الذي قد يكون جزءاً من النص نفسه أو مولَّداً من
/// numPr — لا نعيد ترقيمه هنا، فقط ننسخ النص الظاهري حرفياً مطابقاً
/// لسلوك حقل TOC الحقيقي في Word)، مستواه (1/2/3 يقابل \o "1-3")،
/// واسم bookmark الوجهة (قد يكون null لعنوان بلا bookmarkStart صريح —
/// نادر، لكن مُتعامَل معه بأمان: ذلك الإدخال يُكتَب كنص فهرس بلا رابط
/// قابل للنقر بدل إسقاطه كلياً).
class _TocEntry {
  final String text;
  final int level;
  final String? bookmarkName;
  final bool rtl;
  const _TocEntry(this.text, this.level, this.bookmarkName, this.rtl);
}

/// قيمة حارسة (sentinel) للتمييز بين "لا تغيير" و"اضبط على null" في
/// _Paragraph.copyWith.bookmarkName.
const Object _noChange = Object();

class _Paragraph {
  final List<_Run> runs;
  final _Align align;
  final bool rtl;
  final double spaceBefore;
  final double spaceAfter;
  final double lineSpacing;
  final _ListType? listType;
  final int listLevel;
  final String? numId; // معرّف القائمة (لتتبّع العدّاد)
  final String? numFmt; // decimal / lowerLetter / lowerRoman ...
  final bool isHeading;
  final int headingLevel;
  /// ⚠️ إصلاح حقيقي جوهري (وجهات الروابط الداخلية غائبة كلياً): اسم
  /// أول w:bookmarkStart يسبق هذه الفقرة مباشرة في XML (إن وُجد) — انظر
  /// شرح المشكلة الكامل في PdfBlockParagraph.bookmarkName بـ
  /// pdf_layout_model.dart. null = لا بوكماك يستهدف هذه الفقرة (الحالة
  /// الغالبة لفقرات المحتوى العادية).
  final String? bookmarkName;
  final double? leftIndent;
  final double? rightIndent;
  /// ⚠️ إصلاح حقيقي: مسافة بادئة إضافية (موجبة) أو سالبة (hanging) خاصة
  /// بالسطر الأول فقط من الفقرة (w:ind/@firstLine أو @hanging) — انظر
  /// تعليق استخراجها في _parseParagraph لتفصيل كامل.
  final double firstLineIndent;
  final List<_TabStop> tabStops; // مواقع الجدولة (w:tabs)
  final String? shadingHex; // تظليل خلفية الفقرة (w:pPr/w:shd fill)
  final bool hasBorder; // حدود الفقرة (w:pPr/w:pBdr)
  final String? borderHex; // لون حدود الفقرة

  const _Paragraph({
    required this.runs,
    this.align = _Align.start,
    this.rtl = true,
    this.spaceBefore = 0,
    this.spaceAfter = 8,
    this.lineSpacing = 1.15,
    this.listType,
    this.listLevel = 0,
    this.numId,
    this.numFmt,
    this.isHeading = false,
    this.headingLevel = 0,
    this.bookmarkName,
    this.leftIndent,
    this.rightIndent,
    this.firstLineIndent = 0,
    this.tabStops = const [],
    this.shadingHex,
    this.hasBorder = false,
    this.borderHex,
  });

  String get fullText => runs.map((r) => r.text).join();

  /// نسخة معدَّلة مع استبدال runs فقط (الحفاظ على كل خصائص الفقرة:
  /// محاذاة/تباعد/قائمة/عنوان/هوامش…) — يُستخدَم في
  /// _splitParagraphOnPageBreaks. bookmarkName يُمرَّر فقط للجزء الأول
  /// (وجهة الرابط يجب أن تبقى في أعلى الفقرة الأصلية، لا تتكرر في كل
  /// جزء بعد فاصل صفحة).
  _Paragraph copyWith({List<_Run>? runs, Object? bookmarkName = _noChange}) =>
      _Paragraph(
        runs: runs ?? this.runs,
        align: align,
        rtl: rtl,
        spaceBefore: spaceBefore,
        spaceAfter: spaceAfter,
        lineSpacing: lineSpacing,
        listType: listType,
        listLevel: listLevel,
        numId: numId,
        numFmt: numFmt,
        isHeading: isHeading,
        headingLevel: headingLevel,
        bookmarkName: bookmarkName == _noChange
            ? this.bookmarkName
            : bookmarkName as String?,
        leftIndent: leftIndent,
        rightIndent: rightIndent,
        firstLineIndent: firstLineIndent,
        tabStops: tabStops,
        shadingHex: shadingHex,
        hasBorder: hasBorder,
        borderHex: borderHex,
      );

  // كل معرّفات الهوامش التي تشير إليها مقاطع هذه الفقرة (بالترتيب)
  List<String> get footnoteIds =>
      runs.expand((r) => r.footnoteIds).toList(growable: false);
}

// موقع جدولة واحد: الموضع بالنقاط من هامش اليسار + نوع المحاذاة
class _TabStop {
  final double pos;
  final String align; // left / center / right / decimal
  const _TabStop(this.pos, this.align);
}

/// ⚠️ إصلاح حقيقي (حدود الخلايا الفردية المفقودة): يقابل w:tcBorders داخل
/// w:tcPr لكل خلية على حدة — مستقل تماماً عن w:tblBorders على مستوى
/// الجدول. هذا هو النمط الفعلي الذي تستخدمه أدوات توليد DOCX برمجياً
/// (مثل docx-js) غالباً: كل خلية تحمل حدودها الأربعة الخاصة بها بدل
/// الاعتماد على تعريف موحَّد واحد لكل الجدول. قبل هذا الإصلاح لم تكن
/// _parseTable تستخرج w:tcBorders إطلاقاً، فإن كانت خلايا جدول DOCX حقيقي
/// تحمل حدودها فقط عبر هذا المسار (دون w:tblBorders على مستوى الجدول، أو
/// بحدود مختلفة عن حدود الجدول)، كانت هذه الخلايا تُرسَم بلا أي خط حد على
/// الإطلاق رغم وجود w:tcBorders صريحة في XML.
class _CellEdgeBorders {
  final _BorderSpec? top;
  final _BorderSpec? bottom;
  final _BorderSpec? left;
  final _BorderSpec? right;
  const _CellEdgeBorders({this.top, this.bottom, this.left, this.right});

  bool get isEmpty => top == null && bottom == null && left == null && right == null;
}

class _TableCell {
  final List<_Paragraph> paragraphs;
  final int colSpan;
  final String? bgColorHex;
  final bool vMergeContinue; // خلية امتداد دمج عمودي
  final _Table? nested; // جدول متداخل داخل الخلية (يُرسم كشبكة حقيقية)
  /// ⚠️ إصلاح حقيقي: أول صورة موجودة داخل فقرات الخلية (DOCX: w:drawing
  /// ضمن فقرة في w:tc). كانت تُفقد كلياً سابقاً لأن _extractImages لم
  /// تكن تُستدعى أبداً على فقرات الخلايا في _parseTable. نأخذ أول صورة
  /// فقط لكل خلية (حالة استخدام شائعة: صورة واحدة معرّفة في خلية)؛ صور
  /// متعددة في خلية واحدة قيد غير مدعوم بعد (نادر جداً عملياً).
  final _ImageBlock? image;
  /// حدود الخلية الفردية المستخرجة من w:tcBorders (انظر تعليق
  /// _CellEdgeBorders أعلاه). null إذا لم تُعرَّف الخلية أي حدود خاصة بها
  /// — في هذه الحالة يسقط الرسم احتياطياً إلى حدود الجدول (defaultBorder/
  /// insideHBorder/insideVBorder) كما كان سابقاً.
  final _CellEdgeBorders? edgeBorders;
  /// ⚠️ إضافة جديدة (حشوة الخلية الفعلية من w:tcMar) — انظر تعليق
  /// استخراجها الكامل في _parseTable. متوسط الجهات الأربعة الفعلية، أو
  /// 4.0 (نفس الثابت القديم) إن غابت w:tcMar كلياً.
  final double paddingPt;
  /// ⚠️ إضافة جديدة (محاذاة عمودية فعلية من w:vAlign) — null|"top"|
  /// "center"|"bottom"، انظر تعليق استخراجها الكامل في _parseTable.
  final String? vAlignRaw;

  const _TableCell({
    required this.paragraphs,
    this.colSpan = 1,
    this.bgColorHex,
    this.vMergeContinue = false,
    this.nested,
    this.image,
    this.edgeBorders,
    this.paddingPt = 4.0,
    this.vAlignRaw,
  });
}

class _TableRow {
  final List<_TableCell> cells;
  final bool isHeader;
  const _TableRow({required this.cells, this.isHeader = false});
}

/// حد بسيط (عرض بالنقاط + لون hex) — مرايا Dart لـ PdfBorderSpec في
/// pdf_layout_model.dart، يُستخدَم هنا فقط كحامل بيانات وسيط قبل التحويل.
class _BorderSpec {
  final double widthPt;
  final String colorHex;
  const _BorderSpec(this.widthPt, this.colorHex);
}

class _Table {
  final List<_TableRow> rows;
  final List<double> colWidths;
  final bool rtl; // اتجاه الجدول: true ⇒ العمود المنطقي الأول على اليمين
  /// ⚠️ إصلاح حقيقي (حدود الجداول المفقودة بالكامل): يقابل w:tblBorders
  /// على مستوى الجدول كله — انظر تعليق استخراجها في _parseTable لتفصيل
  /// كامل للمشكلة. defaultBorder يقابل top/bottom/left/right (نأخذ أول
  /// قيمة مُعرَّفة من الأربعة كحد افتراضي موحَّد، الحالة الشائعة فعلياً
  /// حيث DOCX يكرر نفس width/color لكل الأطراف)، وinsideH/insideV
  /// للحدود الداخلية بين الصفوف/الأعمدة حين تختلف عن الخارجية.
  final _BorderSpec? defaultBorder;
  final _BorderSpec? insideHBorder;
  final _BorderSpec? insideVBorder;
  const _Table({
    required this.rows,
    required this.colWidths,
    this.rtl = true,
    this.defaultBorder,
    this.insideHBorder,
    this.insideVBorder,
  });
}

abstract class _Block {}

class _ParagraphBlock extends _Block {
  final _Paragraph paragraph;
  _ParagraphBlock(this.paragraph);
}

class _TableBlock extends _Block {
  final _Table table;
  _TableBlock(this.table);
}

/// ⚠️ إصلاح حقيقي جوهري (فاصل الصفحة الصريح w:br w:type="page" كان
/// يُعامَل كسطر جديد عادي): فاصل صفحة قسري بين الكتل. يُترجَم في
/// mapWatermarkAwareBlock إلى PdfBlockPageBreak (موجود فعلاً في
/// pdf_layout_model.dart، ويعالجه NativePdfRenderer.kt في كل مسارات
/// التدفق — تدفق عادي/أعمدة/قياس جاف) فيُجبر المحتوى التالي على بدء
/// صفحة جديدة، مطابقاً تماماً لسلوك Word. كان غياب هذا يدمج كل أقسام
/// المستند المفصولة بفواصل صفحات صريحة في تدفق متلاصق، فيُنقص عدد
/// الصفحات الكلي ويُفسد ترتيب المحتوى مقابل DOCX الأصلي.
class _PageBreakBlock extends _Block {
  _PageBreakBlock();
}

class _ImageBlock extends _Block {
  final Uint8List bytes;
  final double width;
  final double height;
  final _Align align; // محاذاة الصورة (يسار/وسط/يمين)
  _ImageBlock(
      {required this.bytes,
      required this.width,
      required this.height,
      this.align = _Align.center});
}

// ── نماذج المخططات (SmartArt) ───────────────────────────────────────────────
class _DiagText {
  final String text;
  final double size;
  final String? colorHex;
  final bool bold;
  final _Align align;
  const _DiagText({
    required this.text,
    this.size = 12,
    this.colorHex,
    this.bold = false,
    this.align = _Align.center,
  });
}

class _DiagShape {
  final double x, y, w, h; // بوحدة EMU
  final String? fillHex;
  final String? lineHex;
  final double lineW; // نقاط
  final bool rounded;
  final List<_DiagText> texts;
  // حشوات النص الداخلية (نقاط) ومحاذاة عمودية من bodyPr
  final double tIns, bIns, lIns, rIns;
  final _VAnchor vAnchor;
  /// ⚠️ إضافة جديدة (هندسة الشكل الحقيقية لمسار _extractShapes فقط — لا
  /// تؤثر على مسار SmartArt الذي يتجاهلها تماماً ويستمر باستخدام `rounded`
  /// المُبسَّطة وحدها كما كان): القيمة الخام لـa:prstGeom/@prst (DrawingML
  /// الحديث) أو اسم وسم VML (v:oval/v:roundrect/...) قبل أي تبسيط إلى
  /// rounded:bool. null يعني "غير معروف/مستطيل بسيط" (السلوك الافتراضي
  /// الحالي، فلا تغيير لأي استدعاء قديم لا يمرر هذا الحقل). يُترجَم لاحقاً
  /// إلى PdfShapeKind الصحيح عبر _prstGeomToShapeKind بدل دائماً "rectangle"
  /// أو "roundedRectangle" بصرف النظر عن الهندسة الفعلية في DOCX.
  final String? prstGeom;
  const _DiagShape({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.fillHex,
    this.lineHex,
    this.lineW = 1,
    this.rounded = false,
    this.texts = const [],
    this.tIns = 0,
    this.bIns = 0,
    this.lIns = 0,
    this.rIns = 0,
    this.vAnchor = _VAnchor.middle,
    this.prstGeom,
  });
}

enum _VAnchor { top, middle, bottom }

// حشوات نص الشكل (نقاط) + محاذاة عمودية — تُعاد من _readBodyInsets.
class _Insets {
  final double t, b, l, r;
  final _VAnchor anchor;
  const _Insets(
      {required this.t,
      required this.b,
      required this.l,
      required this.r,
      required this.anchor});
}

class _DiagramBlock extends _Block {
  final List<_DiagShape> shapes;
  final double emuW, emuH; // أبعاد الإطار الكلي للمخطط
  _DiagramBlock({required this.shapes, required this.emuW, required this.emuH});
}

/// ⚠️ إصلاح حقيقي (الأشكال تُحوَّل لجدول مزيَّف بدل أشكال هندسية حقيقية):
/// نوع كتلة مستقل تماماً عن _DiagramBlock (المتروك بلا تغيير لمسار
/// SmartArt متعدد العقد عبر mapDiagram، الذي يبقى يستخدم التقريب المبسَّط
/// القديم لأن دقة التموضع النسبي لعقد متعددة داخل رسم واحد ليست أولوية
/// بالمقارنة بأهمية حجمها الإجمالي للتدفق) — خاص فقط بمخرجات _extractShapes
/// (أشكال DOCX العادية المفردة: مستطيل/بيضاوي/مثلث/سهم/مربع نص... المُضمَّنة
/// inline في تدفق فقرة، لا SmartArt). يحمل _DiagShape مفرداً واحداً ليُترجَم
/// في _mapBlocksToDocSpec إلى Block.GroupBlock حقيقي (شكل هندسي + نص فوقه)
/// بدل PdfBlockTable بخلية واحدة بحد مستطيل بسيط — انظر mapShapeGroup.
class _ShapeGroupBlock extends _Block {
  final _DiagShape shape;
  _ShapeGroupBlock(this.shape);
}

/// ⚠️ إصلاح حقيقي (الأشكال تُحوَّل لجدول مزيَّف بدل أشكال هندسية حقيقية):
/// يترجم القيمة الخام لـ_DiagShape.prstGeom (a:prstGeom/@prst من DrawingML
/// الحديث، أو الاسم المُستنتَج من اسم وسم VML — انظر _parseVmlShape) إلى
/// PdfShapeKind المتاح فعلاً في محرك الرسم Kotlin (ShapeRenderer.kt يدعم
/// rectangle/roundedRectangle/oval/line/triangle/diamond/rightArrow/
/// pentagon/hexagon/star/chevron برسم هندسي حقيقي كامل — كانت هذه القدرة
/// موجودة وجاهزة في الجسر لكن طبقة Dart لم تكن تستخدمها إطلاقاً لأشكال
/// DOCX، بل تحوّلها جميعاً (بصرف النظر عن هندستها الفعلية) إلى صف جدول
/// بخلية واحدة بحد مستطيل بسيط عبر mapDiagram — فيظهر شكل بيضاوي أو
/// مثلث أو سهم في DOCX كمستطيل دائماً في PDF). الأسماء الرسمية مأخوذة من
/// مواصفة ECMA-376 ST_ShapeType؛ أي اسم غير مُطابَق صريحاً (autoshapes
/// نادرة كـ"heart"/"sun"/"cloud"... لا مكافئ هندسي مباشر لها في
/// PdfShapeKind الحالية) يتراجع بأمان لـ"rectangle" (نفس السلوك المبسَّط
/// السابق، فلا يُسقط أي شكل بصمت رغم عدم دقة هندسته 100%).
String _prstGeomToShapeKind(String? prst, bool roundedFallback) {
  switch ((prst ?? '').trim()) {
    case 'ellipse':
      return 'oval';
    case 'roundRect':
    case 'round1Rect':
    case 'round2SameRect':
    case 'round2DiagRect':
    case 'snip1Rect':
    case 'snip2SameRect':
    case 'snip2DiagRect':
      return 'roundedRectangle';
    case 'triangle':
    case 'rtTriangle':
      return 'triangle';
    case 'diamond':
      return 'diamond';
    case 'pentagon':
    case 'homePlate':
      return 'pentagon';
    case 'hexagon':
      return 'hexagon';
    case 'star4':
    case 'star5':
    case 'star6':
    case 'star7':
    case 'star8':
    case 'star10':
    case 'star12':
    case 'star16':
    case 'star24':
    case 'star32':
      return 'star';
    case 'rightArrow':
      return 'rightArrow';
    case 'chevron':
      return 'chevron';
    case 'line':
    case 'straightConnector1':
    case 'lineInv':
      return 'line';
    case 'rect':
    case 'square':
      return 'rectangle';
    default:
      // لا تطابق صريح — نحافظ على سلوك rounded:bool المُبسَّط القديم
      // كأقرب تمييز بصري متاح بدل الإسقاط الصامت لهندسة غير مدعومة.
      return roundedFallback ? 'roundedRectangle' : 'rectangle';
  }
}

// مخطط بياني مستخرج من word/charts/chartN.xml (دائري/أعمدة/خطي)
class _ChartBlock extends _Block {
  final String type; // 'pie' | 'bar' | 'line'
  final List<String> cats; // الفئات
  final List<double> vals; // القيم
  final List<String> colors; // ألوان الشرائح (hex) إن وُجدت
  final double width, height;
  final String? title;
  _ChartBlock({
    required this.type,
    required this.cats,
    required this.vals,
    required this.colors,
    required this.width,
    required this.height,
    this.title,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
//  المحوّل الرئيسي
// ─────────────────────────────────────────────────────────────────────────────

class DocxToPdfConverter {
  DocxToPdfConverter._();

  static const double _pageW = 595.28;
  static const double _pageH = 841.89;
  static const double _marginTop = 56.69;
  static const double _marginBottom = 56.69;
  static const double _marginLeft = 56.69;
  static const double _marginRight = 56.69;
  static const double _contentW = _pageW - _marginLeft - _marginRight;

  /// يحلّل ملف DOCX ويُعيد PdfDocSpec — نموذج تخطيط تصريحي **بلا أي PDF
  /// مُولَّد بعد**. هذه الدالة آمنة للاستدعاء من Worker Isolate (لا تلمس
  /// MethodChannel ولا rootBundle بعد استلام preloadedFonts).
  /// لتوليد بايتات PDF فعلية، مرّر النتيجة إلى
  /// NativePdfBridge.renderDocument() من Main Isolate — انظر
  /// convertDocxInBackground() أسفل هذا الملف للتدفّق الكامل الصحيح.
  static Future<PdfDocSpec> parseToLayout(
    File docxFile, {
    void Function(DocxConversionProgress)? onProgress,
    DocxCancelToken? cancelToken,
    Map<String, Uint8List>?
        preloadedFonts, // الخطوط محمّلة مسبقاً في Main Isolate
  }) async {
    void report(double p, String stage) {
      if (cancelToken?.isCancelled != true) {
        onProgress?.call(DocxConversionProgress(p, stage));
      }
    }

    void checkCancelled() {
      if (cancelToken?.isCancelled == true) {
        throw const DocxCancelledException();
      }
    }

    // ── 1. قراءة الملف ────────────────────────────────────────────────────
    report(0.05, 'قراءة الملف...');
    final Uint8List fileBytes;
    try {
      fileBytes = await docxFile.readAsBytes();
    } catch (_) {
      throw const DocxConversionException('تعذر قراءة الملف من التخزين');
    }
    checkCancelled();

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(fileBytes);
    } catch (_) {
      throw const DocxConversionException('الملف تالف أو ليس بصيغة docx صحيحة');
    }
    checkCancelled();

    // ── 2. استخراج XML ────────────────────────────────────────────────────
    report(0.12, 'تحليل بنية المستند...');
    final documentXml = _readFile(archive, 'word/document.xml');
    if (documentXml == null) {
      throw const DocxConversionException('الملف لا يحتوي على محتوى نصي صالح');
    }
    final stylesXml = _readFile(archive, 'word/styles.xml');
    final numbXml = _readFile(archive, 'word/numbering.xml');
    checkCancelled();

    // ── 3. تحليل البنية ───────────────────────────────────────────────────
    report(0.18, 'استخراج الأنماط...');
    final styleMap = _parseStyles(stylesXml);
    final numbMap = _parseNumbering(numbXml);
    checkCancelled();

    // ── 4. تحليل body ─────────────────────────────────────────────────────
    report(0.28, 'معالجة المحتوى...');
    final XmlDocument docDom;
    try {
      docDom = XmlDocument.parse(documentXml);
    } catch (_) {
      throw const DocxConversionException('خطأ في تحليل XML');
    }

    final body = docDom.findAllElements('w:body').firstOrNull;
    if (body == null) {
      throw const DocxConversionException('لم يتم العثور على body');
    }

    // علاقات الصور: rId -> مسار الملف داخل word/media
    final relsXml = _readFile(archive, 'word/_rels/document.xml.rels');
    final relMap = _parseRels(relsXml);
    // ألوان السمة (لحل ألوان المخططات schemeClr مثل accent4)
    final themeMap = _parseTheme(_readFile(archive, 'word/theme/theme1.xml'));

    final List<_Block> blocks = [];

    // ⚠️ إصلاح حقيقي جوهري (فهرس المحتويات لا يُكتب في PDF رغم وجوده في
    // DOCX): فُحِص XML الفعلي لملف اختبار شامل — قسم TOC موجود فعلاً
    // كحقل Word حقيقي وصريح (w:sdt بـw:alias="Table of Contents"،
    // يحوي w:fldChar begin/separate/end حول instrText "TOC \h \o
    // 1-3")، لكن *لا توجد أي فقرة نتيجة محفوظة* بين separate وend — هذا
    // متوقَّع تماماً من مولِّدات DOCX برمجية (كـdocx-js) لا تملك محرك
    // تخطيط حقيقي يحسب فهرساً فعلياً، فتترك الحقل "فارغاً" بانتظار Word
    // (F9) لحسابه. أي محرك تحويل آخر (بما فيه Word نفسه لو فتح الملف
    // ولم يُحدِّث الحقول) سيواجه نفس الفراغ بالضبط — المشكلة ليست في
    // الاستخراج بل في غياب البيانات من الأساس. الحل: نبني الفهرس من
    // الصفر، بمسح كل فقرات Heading1/2/3 (مطابقاً \o "1-3" بالضبط) في
    // *كل* المستند مسبقاً (قبل الحلقة الرئيسية أدناه، لأن قسم TOC يقع
    // عادة في *أول* المستند، قبل أن تُكتشَف عناوين الأقسام التالية لو
    // اعتمدنا فقط على تراكم الحلقة الرئيسية تتابعياً)، ثم نستخدم هذه
    // القائمة عند معالجة sdt الخاص بـTOC (انظر case 'sdt' أدناه
    // وmapAlign/_synthesizeTableOfContents) لبناء فقرات فهرس حقيقية:
    // نص العنوان + leader نقطي + رمز PUA نائب لرقم الصفحة (نفس آلية
    // PAGE/NUMPAGES المُستخدَمة فعلاً للرأس/التذييل، يُحَل بنفس الطريقة
    // تماماً في NativePdfRenderer.kt) + رابط داخلي (linkAnchor) يشير
    // لاسم bookmark ذلك العنوان تحديداً (الموجود فعلاً صريحاً في DOCX
    // الحقيقي، تأكَّد هذا من فحص XML مباشرة: كل عنوان قسم يحمل
    // w:bookmarkStart بمعرّف دلالي كـ"sec_texts" داخل نفس فقرة العنوان).
    // ⚠️ تحديث: تُعيد الآن أيضاً autoBookmarkOf (خريطة هوية عنصر XML ←
    // اسم bookmark صناعي) لعناوين Heading2/3 الكثيرة في هذا المستند
    // تحديداً (فقرات حشو "Bulk Content Block" بنمط Heading2) التي لا
    // تحمل w:bookmarkStart يدوية — كانت ستظهر في الفهرس المُولَّد بلا
    // رقم صفحة ظاهر إطلاقاً (انظر تعليق bookmarkName الكامل في
    // _collectHeadingsForToc). تُمرَّر لاحقاً إلى _parseParagraph لتُسنَد
    // كـbookmarkName حقيقي على الفقرة الفعلية المطابقة، فتُصبح وجهة
    // رابط صالحة عبر resolveBookmarkPages تماماً كأي bookmark يدوي.
    // ⚠️ تحديث (فهرس المحتويات الحقيقي + bookmark صناعي لعناوين بلا
    // bookmarkStart يدوية، كفقرات الحشو "Bulk Content Block" بنمط
    // Heading2 الكثيرة في هذا المستند تحديداً): autoBookmarkOf خريطة
    // Map<int,String> (موضع ترتيبي pIndex ← اسم bookmark صناعي) —
    // pIndex يُحسَب بنفس الشرط بالضبط في كل من _collectHeadingsForToc
    // (عبر body.children المباشرة، لا findAllElements بعمق كامل — انظر
    // تعليقها لتفصيل فارق فهرسة حقيقي كان سيحدث لولا هذا التطابق) وفي
    // الحلقة الرئيسية أدناه (mainLoopPIndex)، فيضمن تطابقاً بنيوياً
    // مضموناً لا اعتماداً على تساوي XmlElement (غير مؤكَّد بثقة كافية
    // من توثيق مكتبة xml) ولا على فهرس مُستنتَج من عبور بعمق مختلف.
    final (tocHeadings, autoBookmarkOf) = _collectHeadingsForToc(body);
    var mainLoopPIndex = -1;

    // اتجاه كل كتلة حسب قسمها (sectPr/pgSz): landscape أو portrait.
    // فاصل القسم (sectPr داخل pPr) يُطبّق اتجاهه على كل الكتل منذ الفاصل
    // السابق حتى تلك الفقرة. القسم الأخير من sectPr على مستوى body.
    final List<bool> blockLandscape = [];
    final List<int> blockCols = [];
    // ⚠️ إصلاح حقيقي (الهيدر والفوتر غائبان كلياً): نفس فكرة
    // blockLandscape/blockCols، لكن نحتفظ بعنصر sectPr الفعلي (لا فقط
    // قيم مُستخرَجة منه) لكل كتلة — كل قسم DOCX قد يربط هيدر/فوتر مختلف
    // تماماً (مثل فوتر مخصص لقسم Landscape وحده)، فيحتاج flushSection
    // الوصول لـ sectPr هذا القسم بالذات لاستخراج headerReference/
    // footerReference الصحيحين له لا لقسم آخر.
    final List<XmlElement?> blockSectPr = [];
    // ignore: unused_local_variable
    int segStart = 0;
    void assignSeg(bool landscape, int cols, XmlElement? sectPrForSeg) {
      while (blockLandscape.length < blocks.length) {
        blockLandscape.add(landscape);
        blockCols.add(cols);
        blockSectPr.add(sectPrForSeg);
      }
      segStart = blocks.length;
    }

    for (final child in body.children.whereType<XmlElement>()) {
      checkCancelled();
      switch (child.localName) {
        case 'p':
          // ⚠️ mainLoopPIndex يُزاد هنا *فقط* (لكل عنصر w:p يُعالَج في
          // هذه الحلقة الرئيسية، بصرف النظر عن كونه عنواناً) — مطابقاً
          // تماماً لشرط زيادة pIndex في _collectHeadingsForToc (لكل
          // w:p في body.findAllElements، أيضاً بصرف النظر عن نوعه).
          // انظر تعليق autoBookmarkOf الكامل عند بنائها أعلاه لتفصيل
          // القيد الموثَّق (تطابق رياضي مضمون فقط لو لا تداخل عناوين
          // داخل جدول/sdt، مُتحقَّق فعلياً لهذا الملف).
          mainLoopPIndex++;
          final para = _parseParagraph(child, styleMap, numbMap,
              relMap: relMap,
              autoBookmarkName: autoBookmarkOf[mainLoopPIndex]);
          // ⚠️ إصلاح حقيقي جوهري (فاصل الصفحة الصريح): الفقرة قد تحوي
          // رمز PUA U+E010 نائباً لفاصل صفحة قسري (زُرِع في _parseRun من
          // w:br w:type="page"). نقسّمها هنا إلى أجزاء فقرة مفصولة
          // بـ_PageBreakBlock فعلية (انظر _splitParagraphOnPageBreaks).
          // الفقرة الخالية من الرمز تمر كما هي بجزء واحد بلا أي تغيير.
          if (para != null) blocks.addAll(_splitParagraphOnPageBreaks(para));
          // الصور المضمنة داخل الفقرة (كانت تُهمل تماماً سابقاً)
          blocks.addAll(_extractImages(child, relMap, archive));
          // المخططات البيانية (c:chart) — كانت تُهمل تماماً سابقاً
          blocks.addAll(_extractCharts(child, relMap, archive));
          // المخططات (SmartArt) — كانت تُهمل تماماً سابقاً
          blocks.addAll(_extractDiagrams(child, relMap, themeMap, archive));
          // الأشكال ومربعات النص (DrawingML wps:wsp و VML v:shape/v:rect) —
          // تُستخرج بألوانها وحدودها والنصوص بداخلها (عربي/إنجليزي).
          blocks.addAll(_extractShapes(child, themeMap));
          // فاصل قسم؟ عيّن اتجاهه وأعمدته لكل الكتل المتراكمة في القسم
          final sectPr = child
              .findElements('w:pPr')
              .firstOrNull
              ?.findElements('w:sectPr')
              .firstOrNull;
          if (sectPr != null) {
            final sectType = sectPr
                .findElements('w:type')
                .firstOrNull
                ?.getAttribute('w:val');
            if (sectType == 'evenPage' || sectType == 'oddPage') {
              blocks.add(_PageBreakBlock());
            }
            assignSeg(_sectIsLandscape(sectPr), _sectCols(sectPr), sectPr);
          }
        case 'tbl':
          final table = _parseTable(child, styleMap, numbMap,
              relMap: relMap, archive: archive);
          if (table != null) blocks.add(_TableBlock(table));
        case 'sdt':
          // ⚠️ إصلاح حقيقي جوهري (فهرس المحتويات لا يُكتب في PDF) — انظر
          // تعليق tocHeadings الكامل أعلى هذه الدالة. نكتشف هنا تحديداً
          // sdt الخاص بـTOC (عبر w:alias="Table of Contents"، المعيار
          // الذي يكتبه Word نفسه لكل حقل TOC مُدرَج عبر الواجهة) ونفحص
          // إن كان فارغاً فعلياً من أي نص نتيجة محفوظة (لا fldChar/
          // instrText فقط، بل غياب كامل لأي w:t حقيقي بين separate
          // وend) — في هذه الحالة فقط نستبدله بفهرس مُولَّد من
          // tocHeadings المُجمَّعة مسبقاً. أي sdt آخر (أو TOC يحمل
          // نتيجة محفوظة فعلية من Word حقيقي حدَّث حقوله) يستمر بالمسار
          // القديم تماماً بلا أي تغيير سلوك.
          final alias = child
              .findElements('w:sdtPr')
              .firstOrNull
              ?.findElements('w:alias')
              .firstOrNull
              ?.getAttribute('w:val');
          final content = child.findElements('w:sdtContent').firstOrNull;
          final hasStoredTocText = content != null &&
              content.findAllElements('w:t').any((t) => t.innerText.trim().isNotEmpty);
          if (alias == 'Table of Contents' && !hasStoredTocText) {
            blocks.addAll(_synthesizeTableOfContents(tocHeadings));
          } else if (content != null) {
            for (final inner in content.children.whereType<XmlElement>()) {
              if (inner.localName == 'p') {
                final para =
                    _parseParagraph(inner, styleMap, numbMap, relMap: relMap);
                // فاصل الصفحة الصريح داخل sdt يُعالَج كما في المتن.
                if (para != null) {
                  blocks.addAll(_splitParagraphOnPageBreaks(para));
                }
              }
            }
          }
      }
    }
    // القسم الأخير (sectPr على مستوى body)
    final bodySect = body.findElements('w:sectPr').firstOrNull;
    final bool finalLandscape = bodySect != null && _sectIsLandscape(bodySect);
    final int finalCols = bodySect != null ? _sectCols(bodySect) : 1;
    assignSeg(finalLandscape, finalCols, bodySect);
    checkCancelled();

    // ── الهوامش السفلية (footnotes) ────────────────────────────────────────
    // ⚠️ إصلاح حقيقي (موضع الهوامش): سابقاً كانت كل الهوامش تُجمَّع في قسم
    // مستقل بنهاية المستند بصرف النظر عن صفحة مرجعها الفعلية، بخلاف سلوك
    // Word (هامش أسفل نفس صفحة مرجعه). الآن نص كل هامش يُربَط مباشرة
    // بـ PdfBlockParagraph.footnotes للفقرة التي تحمل مرجعه (انظر
    // _Run.footnoteIds → _Paragraph.footnoteIds المُجمَّعة من كل runs
    // الفقرة)، فيستطيع الجسر الأصلي (NativePdfRenderer.renderFlowingPage)
    // تجميع هوامش كل صفحة فعلياً بعد القياس الحقيقي ورسمها أسفل تلك
    // الصفحة بالذات — مطابقاً لسلوك Word. الربط الفعلي (نص → PdfBlockParagraph)
    // يحدث في mapParagraph أسفل هذا الملف، فلا حاجة لأي معالجة هنا غير
    // قراءة الخريطة وإتاحتها لـ _mapBlocksToDocSpec.
    final footnoteMap =
        _parseFootnotes(_readFile(archive, 'word/footnotes.xml'));

    // ── التعليقات الختامية (endnotes) ──────────────────────────────────────
    // بنية word/endnotes.xml مماثلة للهوامش لكن بعنصر w:endnote / المرجع
    // w:endnoteReference. هذه تُجمَّع كقسم في نهاية المستند فعلاً — هذا
    // مطابق لسلوك Word نفسه (Endnotes تظهر بنهاية المستند بخلاف Footnotes
    // أسفل كل صفحة)، فلا تغيير هنا.
    final endnoteMap = _parseEndnotes(_readFile(archive, 'word/endnotes.xml'));

    if (endnoteMap.isNotEmpty) {
      final ordered = <String>[];
      for (final er in body.findAllElements('w:endnoteReference')) {
        final id = er.getAttribute('w:id');
        if (id != null && endnoteMap.containsKey(id) && !ordered.contains(id)) {
          ordered.add(id);
        }
      }
      for (final id in endnoteMap.keys) {
        if (!ordered.contains(id)) ordered.add(id);
      }
      blocks.add(_ParagraphBlock(const _Paragraph(
        runs: [_Run(text: 'التعليقات الختامية / Endnotes', bold: true)],
        rtl: true,
        align: _Align.start,
        spaceBefore: 14,
        spaceAfter: 6,
      )));
      for (final id in ordered) {
        final txt = endnoteMap[id]!;
        final marker = _superscriptDigits(id);
        blocks.add(_ParagraphBlock(_Paragraph(
          runs: [
            _Run(text: '$marker $txt', fontSize: 10, rtl: hasArabic(txt))
          ],
          rtl: hasArabic(txt),
          align: _Align.start,
          spaceAfter: 3,
        )));
      }
    }

    // الهوامش/التعليقات تُلحق بالقسم الأخير (عمودي) — أكمل قائمة الاتجاهات لها
    while (blockLandscape.length < blocks.length) {
      blockLandscape.add(false);
    }
    // تُرسم بعمود واحد (لا ضمن أعمدة القسم)
    while (blockCols.length < blocks.length) {
      blockCols.add(1);
    }

    // ── 5. تحميل الخطوط ───────────────────────────────────────────────────
    report(0.45, 'تحميل الخطوط...');
    // ⚠️ الخطوط تُحمَّل في Main Isolate قبل إطلاق هذا الـ Worker Isolate
    // وتُمرَّر عبر preloadedFonts. لا يجوز استدعاء rootBundle أو
    // BackgroundIsolateBinaryMessenger هنا — كلاهما يسبب الانهيار في
    // Worker Isolate (TimeoutException / type 'Null' is not a subtype of ...).

    Uint8List? fontBytes(String path) => preloadedFonts?[path];

    // ── مرحلة 1: خط عربي أساسي ضروري للتشغيل ──────────────────────────────
    const fontCandidates = [
      ['assets/fonts/Amiri-Regular.ttf', 'assets/fonts/Amiri-Bold.ttf'],
      [
        'assets/fonts/NotoNaskhArabic-Regular.ttf',
        'assets/fonts/NotoNaskhArabic-Bold.ttf'
      ],
      [
        'assets/fonts/ScheherazadeNew-Regular.ttf',
        'assets/fonts/ScheherazadeNew-Bold.ttf'
      ],
      ['assets/fonts/Cairo-Regular.ttf', 'assets/fonts/Cairo-Bold.ttf'],
      [
        'assets/fonts/NotoSansArabic-Regular.ttf',
        'assets/fonts/NotoSansArabic-Bold.ttf'
      ],
      ['assets/fonts/Tajawal-Regular.ttf', 'assets/fonts/Tajawal-Bold.ttf'],
      [
        'assets/fonts/NotoKufiArabic-Regular.ttf',
        'assets/fonts/NotoKufiArabic-Bold.ttf'
      ],
      ['assets/fonts/Almarai-Regular.ttf', 'assets/fonts/Almarai-Bold.ttf'],
    ];

    Uint8List? regLoaded;
    Uint8List? boldLoaded;
    for (final pair in fontCandidates) {
      final reg = fontBytes(pair[0]);
      if (reg == null) continue;
      regLoaded = reg;
      boldLoaded = fontBytes(pair[1]) ?? reg;
      break;
    }

    // احتياط أخير: خط لاتيني مضمون الوجود
    if (regLoaded == null) {
      regLoaded = fontBytes('assets/fonts/LiberationSans-Regular.ttf');
      boldLoaded =
          fontBytes('assets/fonts/LiberationSans-Bold.ttf') ?? regLoaded;
    }

    if (regLoaded == null) {
      throw const DocxConversionException(
        'لم يتم تحميل أي خط. تأكد من أن الخطوط مُحمَّلة قبل بدء التحويل.',
      );
    }

    final Uint8List regBytes = regLoaded;
    final Uint8List boldBytes = boldLoaded ?? regLoaded;

    // ── سجل الخطوط الكامل من preloadedFonts ────────────────────────────────
    final Map<String, _FontFamily> fontReg = {};
    for (final entry in _FontReg.catalog) {
      final key = entry[0] as String;
      final regPath = entry[1] as String;
      final boldPath = entry[2] as String;
      final reg = fontBytes(regPath);
      if (reg == null) continue; // الخط غير محمّل — نتجاوزه
      final bld = fontBytes(boldPath); // null ⇒ يتراجع إلى Regular لاحقاً
      fontReg[key] = _FontFamily(reg, bld, entry[3] as bool);
    }

    // مفاتيح افتراضية: أول متوفّر لكل نوع (مع ضمان وجود عربي)
    String pickFirst(List<String> keys, String fallback) {
      for (final k in keys) {
        if (fontReg.containsKey(k)) return k;
      }
      return fallback;
    }

    if (!fontReg.containsKey('Amiri')) {
      fontReg['Amiri'] = _FontFamily(regBytes, boldBytes, true);
    }
    final String defArabicKey = pickFirst(
        ['Amiri', 'NotoNaskhArabic', 'ScheherazadeNew', 'Cairo'], 'Amiri');
    final String defLatinKey = pickFirst(
        ['Carlito', 'LiberationSans', 'LiberationSerif', 'Caladea'],
        defArabicKey);
    checkCancelled();

    // ── 6. بناء PdfDocSpec (التحليل ينتهي هنا؛ لا رسم بعد الآن في هذه الدالة) ─
    report(0.55, 'تجهيز التخطيط النهائي...');

    // ⚠️ إصلاح حقيقي (الهيدر والفوتر غائبان كلياً، يتكرران الآن فعلياً
    // على كل صفحة): الحل المؤقت السابق (إدراج فقرة هيدر مسطّحة بداية
    // المستند مرة واحدة فقط، بلا فوتر إطلاقاً) أُزيل بالكامل. الهيدر/
    // الفوتر الآن يُستخرَجان لكل قسم (sectPr) بدقة عبر blockSectPr (انظر
    // تعليقها أعلى الحلقة)، ويُمرَّران إلى _mapBlocksToDocSpec التي تبني
    // PdfPageSpec.headerBlocks/footerBlocks الحقيقية لكل صفحة-قسم على حدة
    // (الجسر الأصلي يكرر رسمها تلقائياً على كل صفحة فعلية ناتجة عن ذلك
    // القسم — انظر drawPageHeaderFooter في NativePdfRenderer.kt).

    // ── زخرفة الصفحة: لون الخلفية، إطار الصفحة، العلامة المائية ───────────
    final decorations =
        _extractPageDecorations(archive, body, relMap, themeMap);

    checkCancelled();

    final spec = _mapBlocksToDocSpec(
      blocks: blocks,
      blockLandscape: blockLandscape,
      blockCols: blockCols,
      blockSectPr: blockSectPr,
      relMap: relMap,
      styleMap: styleMap,
      numbMap: numbMap,
      archive: archive,
      fontReg: fontReg,
      defArabicKey: defArabicKey,
      defLatinKey: defLatinKey,
      decorations: decorations,
      footnoteMap: footnoteMap,
      pageW: _pageW,
      pageH: _pageH,
      marginTop: _marginTop,
      marginBottom: _marginBottom,
      marginLeft: _marginLeft,
      marginRight: _marginRight,
    );

    report(0.6, 'اكتمل تجهيز التخطيط');
    return spec;
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  _mapBlocksToDocSpec — يستبدل _PdfWriter بالكامل
  //  ─────────────────────────────────────────────────────────────────────
  //  يحوّل List<_Block> (نتاج التحليل أعلاه، بلا أي تعديل) إلى PdfDocSpec
  //  تصريحي. لا رسم هنا، ولا تشكيل عربي يدوي، ولا ترتيب بصري — النص
  //  يُمرَّر بترتيبه المنطقي كما استُخرج من XML تماماً، ويتولى الجسر
  //  الأصلي (StaticLayout عبر Minikin/HarfBuzz) كل ذلك بدقة كاملة.
  //
  //  أقسام DOCX (sectPr بعرض/اتجاه مختلف) → صفحات PdfPageSpec منفصلة في
  //  هذا النموذج (isPrecomposed=false لكل صفحة قسم على حدة، يحمل كتله
  //  الخاصة فقط)؛ يضمن هذا أن كل قسم يُقسَّم صفحاته الفعلية بحجمه/هوامشه
  //  الصحيحة، بينما لا يزال كل قسم نفسه continuous-flow متعدد الصفحات.
  // ═══════════════════════════════════════════════════════════════════════
  /// يبني قائمة تسجيلات خطوط جاهزة لتمريرها إلى
  /// NativePdfBridge.registerFonts، مبنية مباشرة من _FontReg.catalog —
  /// مصدر الحقيقة الوحيد لربط مفتاح العائلة (المُستخدَم داخلياً في
  /// runFamily()/_FontReg.resolve() أثناء بناء PdfDocSpec) بمساري ملفَّي
  /// الخط العادي والعريض. هذه الدالة العامة الوحيدة المكشوفة من تفاصيل
  /// _FontReg الخاصة، لتُستخدم من isolate_support.dart (الذي يستورد هذا
  /// الملف عبر import عادي، فلا يستطيع الوصول مباشرة لأي عنصر بشرطة
  /// سفلية كـ _FontReg مهما استورد).
  static List<FontRegistration> buildFontRegistrationsFromCatalog(
    Map<String, Uint8List> loadedFontBytes,
  ) {
    final out = <FontRegistration>[];
    for (final entry in _FontReg.catalog) {
      final key = entry[0] as String;
      final regPath = entry[1] as String;
      final boldPath = entry[2] as String;
      final regBytes = loadedFontBytes[regPath];
      if (regBytes == null) continue; // الخط غير محمَّل — نتجاوزه بأمان
      out.add(FontRegistration(family: key, bold: false, bytes: regBytes));
      final boldBytes = loadedFontBytes[boldPath];
      if (boldBytes != null) {
        out.add(FontRegistration(family: key, bold: true, bytes: boldBytes));
      }
    }
    return out;
  }

  static PdfDocSpec _mapBlocksToDocSpec({
    required List<_Block> blocks,
    required List<bool> blockLandscape,
    required List<int> blockCols,
    // ⚠️ إصلاح حقيقي (الهيدر والفوتر غائبان كلياً): معاملات إضافية لازمة
    // لاستخراج هيدر/فوتر كل قسم بدقة داخل flushSection — انظر تعليق
    // blockSectPr عند بنائها أعلى الدالة المستدعية، وتعليق
    // _headerFooterParagraphs لتفصيل كامل لطريقة الاستخراج.
    required List<XmlElement?> blockSectPr,
    required Map<String, String> relMap,
    required Map<String, Map<String, String>> styleMap,
    required Map<String, Map<int, Map<String, String>>> numbMap,
    required Archive archive,
    required Map<String, _FontFamily> fontReg,
    required String defArabicKey,
    required String defLatinKey,
    required _PageDecorations decorations,
    required Map<String, String> footnoteMap,
    required double pageW,
    required double pageH,
    required double marginTop,
    required double marginBottom,
    required double marginLeft,
    required double marginRight,
  }) {
    // عدّادات القوائم المرقّمة، بمفتاح numId — تُحدَّث تتابعياً أثناء
    // المرور على الكتل بالترتيب، تماماً كما كانت في _PdfWriter._listMarker.
    final Map<String, List<int>> listCounters = {};

    String runFamily(_Run run) => _FontReg.resolve(
          run.fontNameCs,
          run.fontNameAscii,
          hasArabic(run.text),
          fontReg,
          defArabicKey,
          defLatinKey,
        );

    PdfFontSpec mapRunFont(_Run run) {
      return PdfFontSpec(
        family: runFamily(run),
        sizePt: run.fontSize,
        bold: run.bold,
        italic: run.italic,
        colorArgb: _hexToArgb(run.colorHex, fallback: 0xFF000000),
        letterSpacing: run.letterSpacing != 0
            ? run.letterSpacing / run.fontSize // DOCX بالنقاط؛ Android بوحدة em
            : null,
        underline: run.underline,
        strikethrough: run.strike,
        superSub: run.baselineShift < 0
            ? PdfSuperSub.superscript
            : (run.baselineShift > 0
                ? PdfSuperSub.subscript
                : PdfSuperSub.none),
        // ⚠️ إصلاح حقيقي (خلفية تظليل النص الملوّنة): run.highlightHex
        // كان يُستخرَج بدقة كاملة من w:highlight/w:shd (انظر _highlightHex
        // وموقع استخدامها في _parseRun أدناه) لكنه يتوقف هنا تماماً ولا
        // يصل أبداً إلى PdfFontSpec المُرسَل فعلياً عبر القناة — فجوة
        // "سلك غير موصول" مطابقة لمشكلة imageManager في طبقة Kotlin.
        highlightColorArgb: run.highlightHex != null
            ? _hexToArgb(run.highlightHex, fallback: 0xFFFFFF00)
            : null,
        // ⚠️ إصلاح حقيقي (أنماط التسطير/الشطب المتعددة): run.underlineStyle
        // وrun.strikeDouble مُستخرَجان أدناه في _parseRun من w:u/@val
        // وw:dstrike، نفس فجوة التمرير السابقة.
        underlineStyle: run.underlineStyle,
        strikethroughDouble: run.strikeDouble,
      );
    }

    // ⚠️ إصلاح حقيقي (انعكاس محاذاة مزدوج في Dart) — انظر تعليق enum _Align
    // أعلاه لتفصيل كامل المشكلة. كانت هذه الدالة تطبّق عكساً ثانياً مكرراً
    // بلا فائدة فوق عكس _parseParagraph (باستقبالها rtl وعكس start/end
    // به)، فتُرسَل قيمة معكوسة بالفعل عن w:jc الأصلي إلى الجسر — حيث
    // يطبَّق عليها هناك (بحق، انظر تعليق textAlignment في
    // NativePdfRenderer.kt) عكسٌ آخر ضروري فعلياً لأسباب غير متعلقة
    // (طبيعة Layout.Alignment النسبية في Android)، فتتراكم العكستان مع
    // تلك الضرورية لتُعرَض النتيجة معكوسة تماماً عن w:jc الأصلي. أصبحت
    // الدالة الآن تحويلاً مباشراً مطلقاً بلا أي عكس إضافي ولا حاجة لمعامل
    // rtl إطلاقاً — يطابق تماماً نمط mapImage (انظر أدناه) الذي لم يكن
    // معطوباً من الأساس لأنه لم يحمل أي منطق عكس مستقل به (ولا معامل rtl
    // أصلاً في توقيعه).
    PdfTextAlign mapAlign(_Align a) {
      switch (a) {
        case _Align.center:
          return PdfTextAlign.center;
        case _Align.justify:
          return PdfTextAlign.justify;
        case _Align.left:
        case _Align.start:
          return PdfTextAlign.left;
        case _Align.right:
        case _Align.end:
          return PdfTextAlign.right;
      }
    }

    // ── ترقيم عناصر القوائم (مطابق لمنطق _PdfWriter._listMarker الأصلي) ───
    String listMarker(_Paragraph para) {
      final level = para.listLevel;
      if (para.listType == _ListType.bullet) {
        const marks = ['•', '◦', '▪', '‣'];
        return marks[level.clamp(0, marks.length - 1)];
      }
      final key = para.numId ?? 'default';
      final counters = listCounters.putIfAbsent(key, () => <int>[]);
      while (counters.length <= level) {
        counters.add(0);
      }
      counters[level] = counters[level] + 1;
      for (int i = level + 1; i < counters.length; i++) {
        counters[i] = 0;
      }
      final n = counters[level];
      switch (para.numFmt) {
        case 'lowerLetter':
          return '${_toLetter(n, false)})';
        case 'upperLetter':
          return '${_toLetter(n, true)})';
        case 'lowerRoman':
          return '${_toRoman(n).toLowerCase()}.';
        case 'upperRoman':
          return '${_toRoman(n)}.';
        default:
          return '$n.';
      }
    }

    PdfBlockParagraph mapParagraph(_Paragraph para) {
      final runs = para.runs
          .map((r) => PdfTextRun(r.text, mapRunFont(r),
              linkUri: r.linkUri, linkAnchor: r.linkAnchor))
          .toList();
      final marker = para.listType != null ? listMarker(para) : null;
      // مواضع جدولة بمحاذاة يسار فقط (انظر قيد tabStopsPt في
      // pdf_layout_model.dart)؛ نتجاهل مواضع وسط/يمين/عشري في v1 ونأخذ فقط
      // left، لأن Android TabStopSpan لا يدعم غير محاذاة اليسار أصلاً.
      final tabStops = [
        for (final ts in para.tabStops)
          if (ts.align == 'left') ts.pos,
      ];
      // ⚠️ إصلاح حقيقي (موضع الهوامش): نص كل هامش يخصّ هذه الفقرة فعلياً
      // (وُجد مرجعه ضمن أحد runs الفقرة) يُرفَق هنا بنصّه الكامل (لا فقط
      // المعرّف)، مع رقم العلامة المرتفعة كبادئة، لتُرسم أسفل نفس الصفحة
      // التي ستحط فيها هذه الفقرة بعد القياس الحقيقي في Kotlin.
      final footnoteTexts = [
        for (final id in para.footnoteIds)
          if (footnoteMap.containsKey(id))
            '${_superscriptDigits(id)} ${footnoteMap[id]!}',
      ];
      return PdfBlockParagraph(
        runs: runs,
        align: mapAlign(para.align),
        direction: para.rtl ? PdfTextDirection.rtl : PdfTextDirection.ltr,
        spaceBeforePt: para.spaceBefore,
        spaceAfterPt: para.spaceAfter,
        lineSpacingMultiplier: para.lineSpacing,
        indentStartPt: para.leftIndent ?? 0,
        // ⚠️ إصلاح حقيقي (المسافة البادئة الإضافية للسطر الأول مفقودة
        // كلياً): para.firstLineIndent كان مُستخرَجاً بدقة من w:ind/
        // @firstLine أو @hanging (انظر _parseParagraph) لكنه لم يكن
        // يُمرَّر أبداً هنا — PdfBlockParagraph.firstLineIndentPt بقي
        // دائماً 0 بصرف النظر عن القيمة الفعلية في DOCX، فتُفقد أي
        // مسافة بادئة خاصة بأول سطر فقط (فقرات مقتبسة، عناصر قوائم
        // بمسافة hanging) كلياً في الناتج النهائي.
        firstLineIndentPt: para.firstLineIndent,
        listLevel: para.listType != null ? para.listLevel : null,
        listOrdered: para.listType == _ListType.numbered,
        listMarkerOverride: marker,
        tabStopsPt: tabStops,
        footnotes: footnoteTexts,
        bookmarkName: para.bookmarkName,
      );
    }

    /// فقرة بتظليل/حدود (w:shd أو w:pBdr) — لا يدعم نموذج الكتل الحالي
    /// تظليل/حدود على مستوى الفقرة مباشرة، فنغلّفها بجدول 1×1 نُعيد
    /// استخدام دعم تظليل/حدود الخلايا الموجود فيه (حل عملي v1 بدل إضافة
    /// نوع كتلة جديد فقط لهذه الحالة الجزئية).
    PdfBlock mapParagraphMaybeShaded(_Paragraph para) {
      final mapped = mapParagraph(para);
      if (para.shadingHex == null && !para.hasBorder) return mapped;
      return PdfBlockTable(
        rows: [
          [
            PdfTableCell(
              blocks: [mapped],
              backgroundColorArgb:
                  para.shadingHex != null ? _hexToArgb(para.shadingHex) : null,
              paddingPt: 4,
            ),
          ],
        ],
        direction: para.rtl ? PdfTextDirection.rtl : PdfTextDirection.ltr,
      );
    }

    // ⚠️ إصلاح حقيقي (دمج عمودي للخلايا/vMerge): _TableCell.vMergeContinue
    // كان يُحلَّل بدقة من w:vMerge في _parseTable لكنه لم يكن يُستخدَم هنا
    // إطلاقاً — فيُفقد الدمج العمودي كلياً ويتحوّل لخلايا منفصلة متكررة.
    // الجسر الأصلي (NativePdfRenderer.kt: placeCellsOnGrid/computeRowHeights/
    // drawTable) يدعم rowSpan فعلياً ويرسمه بصرياً بشكل متكامل (شبكة
    // occupiedUntilRow + توزيع ارتفاع موزَّع على الصفوف الممتدة)؛ الفجوة
    // كانت فقط في عدم حساب/تمرير rowSpan من جهة Dart. خلية البداية
    // الحقيقية تحمل rowSpan = 1 + عدد خلايا continue التالية، وخلايا
    // continue نفسها تُحذف كلياً من المخرجات (تماماً كما يتوقع نموذج
    // Kotlin: خلية واحدة فقط بـ rowSpan، لا خلايا مكررة فارغة).
    // عداد معرّفات صور خلايا الجدول — بادئة 'tblimg_' لتفادي أي تصادم مع
    // معرّفات 'img_' التي يولّدها PdfDocSpec.toChannelArgs لصور PdfBlockImage
    // العادية (مستوى الصفحة)، لأن كلا المصدرين يكتبان إلى نفس خريطة
    // imageAssets المُرسَلة عبر القناة (انظر native_pdf_bridge.dart).
    int nextTableCellImgId = 0;

    // إعلان مسبق (Forward Declaration) لحل مشكلة الاستدعاء الدائري في Dart
    late final PdfBlockTable Function(_Table) mapTable;

    PdfTableCell mapTableCellBody(_TableCell cell, bool tableRtl, int rowSpan) {
      final cellBlocks = <PdfBlock>[];

      // إضافة الفقرات العادية
      for (final p in cell.paragraphs) {
        cellBlocks.add(mapParagraph(p));
      }

      // إضافة الجدول المتداخل كـ Block حقيقي بدلاً من نصوص مسطحة
      if (cell.nested != null) {
        cellBlocks.add(mapTable(cell.nested!));
      }

      String? imgRef;
      double? imgW, imgH;
      Uint8List? imgBytes;
      if (cell.image != null) {
        imgRef = 'tblimg_${nextTableCellImgId++}';
        imgW = cell.image!.width;
        imgH = cell.image!.height;
        imgBytes = cell.image!.bytes;
      }

      // ⚠️ إصلاح حقيقي (حدود الخلايا الفردية المفقودة): تحويل
      // _CellEdgeBorders (المستخرَجة من w:tcBorders في _parseTable) إلى
      // PdfCellEdgeBorders الفعلية المتوقَّعة من pdf_layout_model.dart.
      // كانت موجودة بدقة في طبقة التحليل لكنها لم تكن تصل أبداً إلى
      // PdfTableCell — فجوة مطابقة لفجوة defaultBorder على مستوى الجدول.
      PdfBorderSpec? toPdfBorder(_BorderSpec? b) =>
          b == null ? null : PdfBorderSpec(b.widthPt, _hexToArgb(b.colorHex));
      final cellEdgeBorders = cell.edgeBorders == null
          ? null
          : PdfCellEdgeBorders(
              top: toPdfBorder(cell.edgeBorders!.top),
              bottom: toPdfBorder(cell.edgeBorders!.bottom),
              left: toPdfBorder(cell.edgeBorders!.left),
              right: toPdfBorder(cell.edgeBorders!.right),
            );

      // ⚠️ إصلاح حقيقي (المحاذاة العمودية داخل الخلية مفقودة كلياً) —
      // انظر تعليق vAlignRaw الكامل في _TableCell/_parseTable. تحويل
      // مباشر لـPdfTextAlign (نوع PdfTableCell.verticalAlign الفعلي):
      // "top"⇒left، "bottom"⇒right، أي قيمة أخرى (بما فيها null أو
      // "center")⇒center — نفس تأويل drawGroup المُتحقَّق منه فعلياً في
      // mapShapeGroup (انظر تعليقها)، إذ PdfTableCell.verticalAlign
      // يُستهلَك بنفس آلية PdfBlockGroup.verticalContentAlign تماماً في
      // drawTable (top/middle/bottom رأسياً، لا left/center/right
      // أفقياً). "center" افتراضي عند الغياب — نفس سلوك Word ونفس
      // الافتراضي القديم لهذا الكود، فلا كسر سلوك لخلية بلا w:vAlign
      // صريحة.
      final cellVerticalAlign = switch (cell.vAlignRaw) {
        'top' => PdfTextAlign.left,
        'bottom' => PdfTextAlign.right,
        _ => PdfTextAlign.center,
      };

      return PdfTableCell(
        blocks: cellBlocks,
        colSpan: cell.colSpan,
        rowSpan: rowSpan,
        backgroundColorArgb:
            cell.bgColorHex != null ? _hexToArgb(cell.bgColorHex) : null,
        // ⚠️ إصلاح حقيقي (حشوة الخلية الفعلية من w:tcMar) — انظر تعليق
        // _TableCell.paddingPt واستخراجها الكامل في _parseTable. بدل
        // الثابت الصريح 4 بصرف النظر عن w:tcMar الفعلية في DOCX.
        paddingPt: cell.paddingPt,
        verticalAlign: cellVerticalAlign,
        edgeBorders: cellEdgeBorders,
        imageAssetRefId: imgRef,
        imageWidthPt: imgW,
        imageHeightPt: imgH,
        imageBytes: imgBytes,
      );
    }

    mapTable = (_Table table) {
      // ── حساب rowSpan من سلاسل vMergeContinue عمودياً ──────────────────
      final rowSpanOverride = <List<int>>[
        for (final row in table.rows) List.filled(row.cells.length, 1),
      ];
      final skip = <List<bool>>[
        for (final row in table.rows) List.filled(row.cells.length, false),
      ];
      for (int r = 0; r < table.rows.length; r++) {
        final cells = table.rows[r].cells;
        for (int c = 0; c < cells.length; c++) {
          if (!cells[c].vMergeContinue) continue;
          int start = r - 1;
          while (start >= 0 &&
              c < table.rows[start].cells.length &&
              table.rows[start].cells[c].vMergeContinue) {
            start--;
          }
          if (start >= 0 && c < table.rows[start].cells.length) {
            rowSpanOverride[start][c]++;
            skip[r][c] = true;
          }
        }
      }

      final rows = <List<PdfTableCell>>[];
      for (int r = 0; r < table.rows.length; r++) {
        final cells = table.rows[r].cells;
        final mappedRow = <PdfTableCell>[];
        for (int c = 0; c < cells.length; c++) {
          if (skip[r][c]) continue;
          mappedRow.add(
              mapTableCellBody(cells[c], table.rtl, rowSpanOverride[r][c]));
        }
        rows.add(mappedRow);
      }
      // ⚠️ إصلاح حقيقي (حدود الجداول المفقودة بالكامل): table.defaultBorder/
      // insideHBorder/insideVBorder كانت تُستخرَج بدقة من w:tblBorders
      // (انظر _parseTable) لكنها لم تكن تصل أبداً إلى PdfBlockTable —
      // فجوة "سلك غير موصول" مطابقة لفجوتي highlight وfirstLineIndent
      // أعلاه. نحوّلها هنا لـ PdfBorderSpec (الكلاس الفعلي المتوقَّع من
      // pdf_layout_model.dart) فقط عند وجودها (null-safe بالكامل).
      PdfBorderSpec? toBorderSpec(_BorderSpec? b) =>
          b == null ? null : PdfBorderSpec(b.widthPt, _hexToArgb(b.colorHex));

      return PdfBlockTable(
        rows: rows,
        columnWidthsPt: table.colWidths.isNotEmpty ? table.colWidths : null,
        direction: table.rtl ? PdfTextDirection.rtl : PdfTextDirection.ltr,
        defaultBorder: toBorderSpec(table.defaultBorder),
        insideHBorder: toBorderSpec(table.insideHBorder),
        insideVBorder: toBorderSpec(table.insideVBorder),
      );
    };

    PdfBlockImage mapImage(_ImageBlock img) {
      PdfTextAlign align;
      switch (img.align) {
        case _Align.start:
        case _Align.left:
          align = PdfTextAlign.left;
        case _Align.end:
        case _Align.right:
          align = PdfTextAlign.right;
        default:
          align = PdfTextAlign.center;
      }
      return PdfBlockImage(
        bytes: img.bytes,
        widthPt: img.width,
        heightPt: img.height,
        align: align,
      );
    }

    PdfBlockChart mapChart(_ChartBlock c) {
      const palette = [
        0xFF4472C4,
        0xFFED7D31,
        0xFFA5A5A5,
        0xFFFFC000,
        0xFF5B9BD5,
        0xFF70AD47,
        0xFF264478,
        0xFF9E480E,
        0xFF636363,
        0xFFBF9000,
      ];
      int colorOf(int i) => (i < c.colors.length && c.colors[i].isNotEmpty)
          ? _hexToArgb(c.colors[i])
          : palette[i % palette.length];
      final perValueColors = [
        for (int i = 0; i < c.vals.length; i++) colorOf(i),
      ];
      return PdfBlockChart(
        kind: c.type,
        title: c.title ?? '',
        categories: c.cats,
        series: [
          PdfChartSeries('', c.vals, palette[0], perValueColors: perValueColors)
        ],
        widthPt: c.width.clamp(160.0, 1000.0),
        heightPt: c.height.clamp(120.0, 320.0),
      );
    }

    /// مخطط SmartArt (_DiagramBlock): كل شكل بمستطيل بسيط (تقريب — لا يدعم
    /// النموذج الحالي أشكالاً حرّة الموضع داخل تدفّق نصي، فنحوّله إلى
    /// سلسلة فقرات ملوّنة الخلفية بترتيب الأشكال الرأسي بدل التموضع
    /// الدقيق x/y/w/h الأصلي بوحدة EMU — قيد v1 موثَّق).
    List<PdfBlock> mapDiagram(_DiagramBlock diag) {
      final out = <PdfBlock>[];
      for (final shape in diag.shapes) {
        final texts =
            shape.texts.isNotEmpty ? shape.texts : const [_DiagText(text: '')];
        final paragraphs = [
          for (final t in texts)
            PdfBlockParagraph(
              runs: [
                PdfTextRun(
                  t.text,
                  PdfFontSpec(
                    family: hasArabic(t.text) ? defArabicKey : defLatinKey,
                    sizePt: t.size,
                    bold: t.bold,
                    colorArgb: _hexToArgb(t.colorHex, fallback: 0xFF000000),
                  ),
                )
              ],
              align: t.align == _Align.center
                  ? PdfTextAlign.center
                  : (t.align == _Align.end
                      ? PdfTextAlign.right
                      : PdfTextAlign.left),
              direction: hasArabic(t.text)
                  ? PdfTextDirection.rtl
                  : PdfTextDirection.ltr,
            ),
        ];
                out.add(PdfBlockTable(
          rows: [
            [
              PdfTableCell(
                blocks: paragraphs,
                backgroundColorArgb:
                    shape.fillHex != null ? _hexToArgb(shape.fillHex) : null,
        border: shape.lineHex != null
                    ? PdfBorderSpec(shape.lineW, _hexToArgb(shape.lineHex))
                    : null,
                paddingPt: 6,
              ),
            ],
          ],
        ));
        out.add(const PdfBlockDivider(
            thicknessPt: 0, spaceBeforePt: 4, spaceAfterPt: 4));
      }
      return out;
    }

    /// ⚠️ إصلاح حقيقي (الأشكال تُحوَّل لجدول مزيَّف بدل أشكال هندسية حقيقية):
    /// يبني Block.GroupBlock حقيقي (شكل هندسي صحيح + نص فوقه بحشوة ومحاذاة
    /// عمودية مطابقة لـbodyPr/wps:bodyPr الأصلي) من _ShapeGroupBlock مفرد،
    /// بدل PdfBlockTable بخلية واحدة وحد مستطيل بسيط (mapDiagram أعلاه —
    /// المتروكة بلا تغيير، فهي تبقى صحيحة لاستخدامها الوحيد المتبقي وهو
    /// SmartArt متعدد العقد). يُستخدَم PdfShapeKind الصحيح عبر
    /// _prstGeomToShapeKind (مستطيل/بيضاوي/مثلث/سهم/نجمة...) بدل افتراض
    /// مستطيل دائماً بصرف النظر عن الهندسة الفعلية في DOCX — انظر تعليق
    /// _ShapeGroupBlock وتعليق _prstGeomToShapeKind لتفصيل كامل المشكلة
    /// المُصلَحة. النتيجة كتلة *تدفّقية عادية* (لا overlay بموضع مطلق):
    /// Block.GroupBlock/Block.ShapeBlock مدعومان بالفعل في drawBlock/
    /// measureBlockHeight على جانب Kotlin كعنصرين تدفّقيين عاديين (انظر
    /// NativePdfRenderer.kt)، وهذا يطابق فعلياً طبيعة wps:wsp/v:shape في
    /// هذا السياق: مُضمَّن inline داخل تدفّق الفقرة الحاوية، لا عائماً
    /// بموضع مطلق (wp:anchor) — فلا حاجة لـPdfAbsoluteOverlay هنا.
    PdfBlock mapShapeGroup(_ShapeGroupBlock sg) {
      final shape = sg.shape;
      final wPt = (shape.w / 12700.0).clamp(2.0, _contentW);
      final hPt = (shape.h / 12700.0).clamp(2.0, 2000.0);

      final shapeKind = _prstGeomToShapeKind(shape.prstGeom, shape.rounded);

      final shapeBlock = PdfBlockShape(
        kind: PdfShapeKind.values.firstWhere(
          (k) => k.name == shapeKind,
          orElse: () => PdfShapeKind.rectangle,
        ),
        widthPt: wPt,
        heightPt: hPt,
        fillColorArgb:
            shape.fillHex != null ? _hexToArgb(shape.fillHex) : null,
        lineColorArgb:
            shape.lineHex != null ? _hexToArgb(shape.lineHex) : null,
        lineWidthPt: shape.lineHex != null ? shape.lineW : 0,
      );

      final texts = shape.texts;
      final paragraphs = [
        for (final t in texts)
          if (t.text.trim().isNotEmpty)
            PdfBlockParagraph(
              runs: [
                PdfTextRun(
                  t.text,
                  PdfFontSpec(
                    family: hasArabic(t.text) ? defArabicKey : defLatinKey,
                    sizePt: t.size,
                    bold: t.bold,
                    colorArgb: _hexToArgb(t.colorHex, fallback: 0xFF000000),
                  ),
                )
              ],
              align: t.align == _Align.center
                  ? PdfTextAlign.center
                  : (t.align == _Align.end
                      ? PdfTextAlign.right
                      : PdfTextAlign.left),
              direction: hasArabic(t.text)
                  ? PdfTextDirection.rtl
                  : PdfTextDirection.ltr,
            ),
      ];

      final verticalAlign = switch (shape.vAnchor) {
        _VAnchor.top => PdfTextAlign.left, // علامة "أعلى" — انظر تعليق أدناه
        _VAnchor.bottom => PdfTextAlign.right, // علامة "أسفل"
        _VAnchor.middle => PdfTextAlign.center,
      };

      return PdfBlockGroup(
        children: [shapeBlock, ...paragraphs],
        widthPt: wPt,
        heightPt: hPt,
        paddingTopPt: shape.tIns,
        paddingBottomPt: shape.bIns,
        paddingLeftPt: shape.lIns,
        paddingRightPt: shape.rIns,
        // ⚠️ PdfBlockGroup.verticalContentAlign من نوع PdfTextAlign (مُعاد
        // استخدامه لتمثيل top/middle/bottom رأسياً بدل left/center/right
        // أفقياً). تأكَّد هذا فعلياً من قراءة drawGroup في
        // NativePdfRenderer.kt: "center"⇒منتصف الصندوق رأسياً، "right"⇒
        // أسفله، وأي قيمة أخرى (بما فيها "left")⇒أعلاه — فleft⇒top
        // وright⇒bottom هو التفسير الفعلي المُطبَّق هناك، مطابقاً تماماً
        // لمعنى _VAnchor المُستخدَم أصلاً في هذا الملف.
        verticalContentAlign: verticalAlign,
      );
    }

    PdfBlock? mapWatermarkAwareBlock(_Block b) {
      if (b is _ParagraphBlock) return mapParagraphMaybeShaded(b.paragraph);
      if (b is _TableBlock) return mapTable(b.table);
      if (b is _ImageBlock) return mapImage(b);
      if (b is _ChartBlock) return mapChart(b);
      if (b is _ShapeGroupBlock) return mapShapeGroup(b);
      // ⚠️ إصلاح حقيقي جوهري (فاصل الصفحة الصريح): _PageBreakBlock →
      // PdfBlockPageBreak (يعالجه NativePdfRenderer.kt في كل مسارات
      // التدفق فيبدأ المحتوى التالي صفحة جديدة فعلياً).
      if (b is _PageBreakBlock) return const PdfBlockPageBreak();
      return null; // _DiagramBlock يُعالَج بشكل خاص (يُنتج عدة كتل) أدناه
    }

    // ── تجميع الكتل في صفحات-قسم (كل تغيّر اتجاه/أعمدة يبدأ قسماً جديداً)
    final List<PdfPageSpec> pages = [];
    List<PdfBlock> currentSectionBlocks = [];
    bool currentLandscape = false;
    int currentCols = 1;
    // ⚠️ إصلاح حقيقي (الهيدر والفوتر غائبان كلياً): يتبع نفس نمط
    // currentLandscape/currentCols تماماً، لكن لمرجع sectPr الفعلي بدل
    // قيمة مُستخرَجة منه — flushSection يستخدمه لاستخراج هيدر/فوتر هذا
    // القسم بالذات (لا قسم آخر) عبر _headerFooterParagraphs.
    XmlElement? currentSectPr;

    void flushSection() {
      if (currentSectionBlocks.isEmpty) return;
      final w = currentLandscape ? pageH : pageW;
      final h = currentLandscape ? pageW : pageH;

      // ⚠️ إصلاح حقيقي جوهري (هوامش الصفحة وارتفاع الهيدر/الفوتر ثوابت
      // صريحة لا تُستخرَج من DOCX) — انظر تعليق _sectMargins الكامل
      // أعلاه لتفصيل المشكلة الكاملة والفارق الفعلي المؤكَّد (15.3pt
      // لكل هامش في ملف اختبار حقيقي). secMargins هنا تستخرج كل القيم
      // الستة من w:pgMar الفعلية *لهذا القسم بالذات* (currentSectPr،
      // نفس النمط بالضبط المُستخدَم أصلاً لـheaderParas/footerParas
      // أدناه)، فتتيح هوامش مختلفة فعلياً بين أقسام مختلفة من نفس
      // المستند (DOCX يدعم هذا أصلاً: قسم Landscape قد يحمل هوامش
      // مختلفة تماماً عن باقي المستند) — بخلاف القيم العامة الثابتة
      // (marginTop/marginBottom/marginLeft/marginRight، معاملات هذه
      // الدالة الخارجية) التي تبقى الآن fallback نظري فقط (يُستخدَم
      // فعلياً فقط لو currentSectPr نفسها null كلياً، حالة نادرة جداً).
      final secMargins = _sectMargins(currentSectPr);

      // ⚠️ إصلاح حقيقي (الهيدر والفوتر غائبان كلياً): نستخرج فقرات هيدر/
      // فوتر *هذا القسم بالذات* (currentSectPr) ونحوّلها لـ PdfBlock عبر
      // mapParagraph نفسها المُستخدَمة لمتن المستند، فتحافظ على كل
      // تنسيقها (Bold/ألوان/محاذاة) تماماً. فارغة بأمان (لا تغيير سلوك)
      // إن غاب القسم أو لم يربط هيدر/فوتر صريحاً.
      final headerParas = _headerFooterParagraphs(archive, currentSectPr,
          relMap, 'w:headerReference', styleMap, numbMap);
      final footerParas = _headerFooterParagraphs(archive, currentSectPr,
          relMap, 'w:footerReference', styleMap, numbMap);
      final headerBlocks = headerParas.map(mapParagraph).toList();
      final footerBlocks = footerParas.map(mapParagraph).toList();

      pages.add(PdfPageSpec(
        widthPt: w,
        heightPt: h,
        marginTopPt: secMargins.top,
        marginBottomPt: secMargins.bottom,
        marginLeftPt: secMargins.left,
        marginRightPt: secMargins.right,
        blocks: currentSectionBlocks,
        backgroundColorArgb: decorations.backgroundHex != null
            ? _hexToArgb(decorations.backgroundHex)
            : null,
        pageBorder: decorations.borderOn
            ? PdfPageBorder(
                widthPt: decorations.borderWidthPt,
                colorArgb:
                    _hexToArgb(decorations.borderHex, fallback: 0xFF000000),
                shadow: decorations.borderShadow,
              )
            : null,
        watermark: decorations.watermarkText != null
            ? PdfWatermark(
                text: decorations.watermarkText!,
                colorArgb:
                    _hexToArgb(decorations.watermarkHex, fallback: 0x80C0C0C0),
              )
            : null,
        // ⚠️ إصلاح حقيقي (الأعمدة المتعددة): كانت blockCols تُحلَّل من
        // w:cols num="N" لكنها لم تُستخدَم هنا إطلاقاً، فيُرسم القسم بعمود
        // واحد كامل العرض حتى لو كان w:cols num="2" أو أكثر في DOCX.
        columnCount: currentCols,
        headerBlocks: headerBlocks,
        footerBlocks: footerBlocks,
        // ⚠️ إصلاح حقيقي: نفس secMargins.header/footer الفعليتين من
        // w:pgMar (بدل الثابت الصريح 28 سابقاً) — انظر تعليق
        // _sectMargins أعلاه. لا تغيير لمنطق "فقط إن وُجد هيدر/فوتر
        // فعلياً" (headerBlocks/footerBlocks.isNotEmpty)، فمستند بلا
        // هيدر/فوتر يبقى بلا أي مساحة محجوزة كما كان دوماً.
        headerHeightPt: headerBlocks.isNotEmpty ? secMargins.header : 0,
        footerHeightPt: footerBlocks.isNotEmpty ? secMargins.footer : 0,
      ));
      currentSectionBlocks = [];
    }

    for (int i = 0; i < blocks.length; i++) {
      final landscape = i < blockLandscape.length ? blockLandscape[i] : false;
      final cols = i < blockCols.length ? blockCols[i] : 1;
      final sectPrForBlock =
          i < blockSectPr.length ? blockSectPr[i] : null;
      if ((landscape != currentLandscape || cols != currentCols) &&
          currentSectionBlocks.isNotEmpty) {
        flushSection();
      }
      currentLandscape = landscape;
      currentCols = cols;
      currentSectPr = sectPrForBlock;

      final b = blocks[i];
      if (b is _DiagramBlock) {
        currentSectionBlocks.addAll(mapDiagram(b));
      } else {
        final mapped = mapWatermarkAwareBlock(b);
        if (mapped != null) currentSectionBlocks.add(mapped);
      }
    }
    flushSection();

    if (pages.isEmpty) {
      // مستند فارغ كلياً — صفحة واحدة فارغة بدل فشل العملية بالكامل.
      pages.add(PdfPageSpec(
        widthPt: pageW,
        heightPt: pageH,
        marginTopPt: marginTop,
        marginBottomPt: marginBottom,
        marginLeftPt: marginLeft,
        marginRightPt: marginRight,
        blocks: const [],
      ));
    }

    return PdfDocSpec(pages: pages, isPrecomposed: false);
  }

  // ─── قراءة ملف من الأرشيف ────────────────────────────────────────────────
  static String? _readFile(Archive archive, String path) {
    final f = archive.findFile(path);
    if (f == null) return null;
    try {
      // ⚠️ مهم: ملفات XML داخل docx مرمّزة UTF-8.
      // استخدام String.fromCharCodes كان يفسد كل النص العربي
      // (كل حرف عربي يتحول إلى حرفين لاتينيين تالفين + رموز تحكم C1).
      return utf8.decode(f.content as List<int>, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  // ─── تحليل styles.xml ─────────────────────────────────────────────────────
  static Map<String, Map<String, String>> _parseStyles(String? xml) {
    final map = <String, Map<String, String>>{};
    if (xml == null) return map;
    try {
      final doc = XmlDocument.parse(xml);

      // ⚠️ إصلاح حقيقي (افتراضيات المستند الكلية <w:docDefaults> غائبة):
      // Word يقرأ docDefaults في styles.xml لتحديد تباعد الفقرة الافتراضي
      // (pPrDefault) وحجم الخط الافتراضي (rPrDefault) لكل فقرة/run لا تحمل
      // قيماً صريحة ولا ترث من نمط. بدونها كنا نفرض 160 twips بعد و1.15 سطر
      // و12pt دائماً — قيم لا تطابق غالبية القوالب (Calibri الحديث = 8pt بعد
      // + 1.08 سطر + 11pt؛ قوالب عربية كثيرة تختلف). نخزّنها تحت مفتاح محجوز
      // يقرؤه _parseParagraph/_parseRun كآخر fallback قبل القيم الصلبة.
      final docDefaults = <String, String>{};
      final ddElem = doc.findAllElements('w:docDefaults').firstOrNull;
      if (ddElem != null) {
        final pPrD = ddElem
            .findAllElements('w:pPrDefault')
            .firstOrNull
            ?.findElements('w:pPr')
            .firstOrNull;
        final ddSpacing = pPrD?.findElements('w:spacing').firstOrNull;
        if (ddSpacing != null) {
          final sb = ddSpacing.getAttribute('w:before');
          if (sb != null) docDefaults['spaceBefore'] = sb;
          final sa = ddSpacing.getAttribute('w:after');
          if (sa != null) docDefaults['spaceAfter'] = sa;
          final sl = ddSpacing.getAttribute('w:line');
          if (sl != null) docDefaults['spacingLine'] = sl;
          final slr = ddSpacing.getAttribute('w:lineRule');
          if (slr != null) docDefaults['spacingLineRule'] = slr;
        }
        final rPrD = ddElem
            .findAllElements('w:rPrDefault')
            .firstOrNull
            ?.findElements('w:rPr')
            .firstOrNull;
        final ddSz =
            rPrD?.findElements('w:sz').firstOrNull?.getAttribute('w:val');
        if (ddSz != null) docDefaults['sz'] = ddSz;
        // ⚠️ إصلاح حقيقي (الخط الافتراضي للمستند مُهمَل): rPrDefault/rFonts
        // يحدّد عائلة الخط الافتراضية (مثلاً Arial) لكل run بلا rFonts صريحة
        // ولا نمط يعرّفها. بدونه كان النص اللاتيني يقع دوماً على Carlito
        // (بديل Calibri) بصرف النظر عن خط المستند الفعلي.
        final ddFonts = rPrD?.findElements('w:rFonts').firstOrNull;
        final ddAscii = ddFonts?.getAttribute('w:ascii') ??
            ddFonts?.getAttribute('w:hAnsi');
        if (ddAscii != null) docDefaults['font'] = ddAscii;
        final ddCs = ddFonts?.getAttribute('w:cs');
        if (ddCs != null) docDefaults['fontCs'] = ddCs;
      }
      if (docDefaults.isNotEmpty) map['__docDefaults__'] = docDefaults;

      // basedOn لكل نمط — نحتفظ به لحل سلسلة الوراثة بعد تجميع كل الأنماط.
      final basedOn = <String, String>{};

      for (final style in doc.findAllElements('w:style')) {
        final id = style.getAttribute('w:styleId');
        if (id == null) continue;
        final props = <String, String>{};
        final name =
            style.findElements('w:name').firstOrNull?.getAttribute('w:val');
        if (name != null) props['name'] = name.toLowerCase();
        final pPr = style.findElements('w:pPr').firstOrNull;
        if (pPr != null) {
          final jc =
              pPr.findElements('w:jc').firstOrNull?.getAttribute('w:val');
          if (jc != null) props['jc'] = jc;
          if (pPr.findElements('w:bidi').firstOrNull != null) {
            props['rtl'] = 'true';
          }
          final styleSpacing = pPr.findElements('w:spacing').firstOrNull;
          if (styleSpacing != null) {
            final sb = styleSpacing.getAttribute('w:before');
            if (sb != null) props['spaceBefore'] = sb;
            final sa = styleSpacing.getAttribute('w:after');
            if (sa != null) props['spaceAfter'] = sa;
            final sl = styleSpacing.getAttribute('w:line');
            if (sl != null) props['spacingLine'] = sl;
            final slr = styleSpacing.getAttribute('w:lineRule');
            if (slr != null) props['spacingLineRule'] = slr;
          }
        }
        final rPr = style.findElements('w:rPr').firstOrNull;
        if (rPr != null) {
          if (rPr.findElements('w:b').isNotEmpty) props['bold'] = 'true';
          if (rPr.findElements('w:i').isNotEmpty) props['italic'] = 'true';
          final sz =
              rPr.findElements('w:sz').firstOrNull?.getAttribute('w:val');
          if (sz != null) props['sz'] = sz;
          final color =
              rPr.findElements('w:color').firstOrNull?.getAttribute('w:val');
          if (color != null && color != 'auto') props['color'] = color;
          // ⚠️ rFonts على مستوى النمط — يُورَّث عبر basedOn ويُستهلَك في
          // _parseRun كـ styleProps['font']/['fontCs']. كان مفقوداً كلياً،
          // فأنماط مثل Heading التي تحدّد Arial لم يكن خطها يصل للناتج.
          final sFonts = rPr.findElements('w:rFonts').firstOrNull;
          final sAscii = sFonts?.getAttribute('w:ascii') ??
              sFonts?.getAttribute('w:hAnsi');
          if (sAscii != null) props['font'] = sAscii;
          final sCs = sFonts?.getAttribute('w:cs');
          if (sCs != null) props['fontCs'] = sCs;
        }
        final base =
            style.findElements('w:basedOn').firstOrNull?.getAttribute('w:val');
        if (base != null) basedOn[id] = base;
        map[id] = props;
      }

      // ⚠️ إصلاح حقيقي (وراثة الأنماط عبر w:basedOn مفقودة): نمط Heading
      // مبني على Normal كان يفقد خطه وتباعده الموروثين لأن كل نمط كان يُقرأ
      // منعزلاً. نملأ المفاتيح الناقصة في كل نمط من أسلافه صعوداً في السلسلة
      // (مع حارس دورات)، باستثناء الاسم (خاص بكل نمط فلا يُورَّث).
      for (final id in map.keys) {
        if (id == '__docDefaults__') continue;
        final seen = <String>{id};
        var cur = basedOn[id];
        while (cur != null && map.containsKey(cur) && seen.add(cur)) {
          for (final e in map[cur]!.entries) {
            if (e.key == 'name') continue;
            map[id]!.putIfAbsent(e.key, () => e.value);
          }
          cur = basedOn[cur];
        }
      }
    } catch (_) {}
    return map;
  }

  // ─── تحليل numbering.xml ──────────────────────────────────────────────────
  static Map<String, Map<int, Map<String, String>>> _parseNumbering(
      String? xml) {
    final map = <String, Map<int, Map<String, String>>>{};
    if (xml == null) return map;
    try {
      final doc = XmlDocument.parse(xml);
      final abstractMap = <String, Map<int, Map<String, String>>>{};
      for (final abs in doc.findAllElements('w:abstractNum')) {
        final absId = abs.getAttribute('w:abstractNumId') ?? '';
        final levels = <int, Map<String, String>>{};
        for (final lvl in abs.findElements('w:lvl')) {
          final ilvl = int.tryParse(lvl.getAttribute('w:ilvl') ?? '0') ?? 0;
          final fmt =
              lvl.findElements('w:numFmt').firstOrNull?.getAttribute('w:val') ??
                  'bullet';
          final text = lvl
                  .findElements('w:lvlText')
                  .firstOrNull
                  ?.getAttribute('w:val') ??
              '•';
          final start =
              lvl.findElements('w:start').firstOrNull?.getAttribute('w:val') ??
                  '1';
          levels[ilvl] = {'numFmt': fmt, 'lvlText': text, 'start': start};
        }
        abstractMap[absId] = levels;
      }
      for (final num in doc.findAllElements('w:num')) {
        final numId = num.getAttribute('w:numId') ?? '';
        final absId = num.findElements('w:abstractNumId')
                .firstOrNull
                ?.getAttribute('w:val') ??
            '';
        if (abstractMap.containsKey(absId)) {
          map[numId] = Map.from(abstractMap[absId]!);
        }
      }
    } catch (_) {}
    return map;
  }

  // ─── تحليل فقرة ───────────────────────────────────────────────────────────
  static _Paragraph? _parseParagraph(
    XmlElement pElem,
    Map<String, Map<String, String>> styleMap,
    Map<String, Map<int, Map<String, String>>> numbMap, {
    Map<String, String> relMap = const {},
    // ⚠️ إصلاح حقيقي (bookmark صناعي لعناوين بلا w:bookmarkStart يدوية)
    // — انظر تعليق autoBookmarkOf الكامل عند بنائها في
    // _collectHeadingsForToc ونقطة استدعائها. اسم جاهز (لا الخريطة
    // كاملة) يُمرَّر من نقطة الاستدعاء بعد بحثها بهوية pElem نفسه —
    // null يعني "لا حاجة" (إما ليست عنواناً، أو تحمل bookmarkStart
    // يدوية فعلية ستُستخرَج أدناه بالطريقة القديمة بلا تغيير).
    String? autoBookmarkName,
  }) {
    final pPr = pElem.findElements('w:pPr').firstOrNull;
    final styleId =
        pPr?.findElements('w:pStyle').firstOrNull?.getAttribute('w:val');
    final styleProps =
        styleId != null ? (styleMap[styleId] ?? {}) : <String, String>{};
    final styleName = styleProps['name'] ?? '';

    bool isHeading = false;
    int headingLevel = 0;
    final hMatch = RegExp(r'^heading\s*(\d)').firstMatch(styleName);
    if (hMatch != null) {
      isHeading = true;
      headingLevel = int.tryParse(hMatch.group(1) ?? '1') ?? 1;
    }

    // ⚠️ إصلاح حقيقي جوهري (وجهات الروابط الداخلية غائبة كلياً): انظر
    // الشرح الكامل في تعليق _Paragraph.bookmarkName أعلاه. w:bookmarkStart
    // يظهر كعنصر شقيق مباشر لـw:pPr/w:r داخل w:p نفسها (لا كعنصر مستوى
    // body مستقل)، فنبحث عنه هنا مباشرة. نأخذ أول bookmarkStart فقط (فقرة
    // واحدة نادراً ما تحمل أكثر من وجهة فعلية مفيدة؛ Word يُنشئ أحياناً
    // bookmarks تلقائية إضافية كـ"_GoBack" نتجاهلها صريحاً لأنها ليست
    // وجهات يستهدفها أي رابط حقيقي في المستند).
    final explicitBookmarkName = pElem
        .findElements('w:bookmarkStart')
        .map((e) => e.getAttribute('w:name'))
        .firstWhere((n) => n != null && n != '_GoBack', orElse: () => null);
    // ⚠️ إصلاح حقيقي (bookmark صناعي لعناوين بلا w:bookmarkStart يدوية)
    // — fallback لـautoBookmarkName الممرَّر من نقطة الاستدعاء (غير
    // null فقط حين هذه الفقرة عنوان مُكتشَف مسبقاً في _collectHeadingsForToc
    // بلا bookmarkStart يدوية أصلاً) إن غابت bookmarkStart اليدوية.
    final bookmarkName = explicitBookmarkName ?? autoBookmarkName;

    final bidi = pPr?.findElements('w:bidi').firstOrNull;
    final bidiVal = bidi?.getAttribute('w:val');
    bool paraRtl = bidi != null && bidiVal != '0';
    if (!paraRtl && styleProps['rtl'] == 'true') paraRtl = true;
    // كثير من المستندات لا تضع w:bidi وتعتمد على jc=right + محتوى عربي.
    // نكتشف الاتجاه من المحتوى: وجود حروف عربية يعني فقرة RTL.
    if (!paraRtl) {
      final sample =
          pElem.findAllElements('w:t').map((e) => e.innerText).join();
      if (hasArabic(sample)) paraRtl = true;
    }

    final jcRaw =
        pPr?.findElements('w:jc').firstOrNull?.getAttribute('w:val') ??
            styleProps['jc'] ??
            '';
    _Align align;
    switch (jcRaw) {
      case 'center':
        align = _Align.center;
      // ⚠️ إصلاح حقيقي (انعكاس محاذاة مزدوج في Dart) — انظر تعليق enum
      // _Align أعلاه لتفصيل كامل المشكلة. w:jc="right"/"left" قيمتان
      // *مطلقتان* بصرياً وفق مواصفة OOXML (يمين/يسار الصفحة الفعلي دوماً)،
      // لا علاقة لهما باتجاه النص (paraRtl) — فلا عكس هنا إطلاقاً؛ العكس
      // الضروري الوحيد لإسقاطهما على Layout.Alignment النسبي في Android
      // يحدث لاحقاً في NativePdfRenderer.kt (الموضع الصحيح الوحيد له).
      // العكس بحسب paraRtl يبقى صحيحاً ومطلوباً *فقط* لقيمتي
      // w:jc="start"/"end" الفعليتين (النادرتين في DOCX الحديث)، المُعالَجتين
      // في حالتين صريحتين أدناه (لا ضمن default — default يبقى للقيمة
      // الافتراضية البسيطة عند غياب w:jc كلياً، وهي يسار مطلق دوماً).
      case 'right':
        align = _Align.right;
      case 'left':
        align = _Align.left;
      case 'both':
      case 'distribute':
        align = _Align.justify;
      case 'start':
        align = paraRtl ? _Align.end : _Align.start;
      case 'end':
        align = paraRtl ? _Align.start : _Align.end;
      default:
        align = _Align.start;
    }

    // ⚠️ docDefaults كآخر fallback (بعد الصريح ثم النمط) قبل القيم الصلبة.
    final dd = styleMap['__docDefaults__'] ?? const <String, String>{};
    final spacing = pPr?.findElements('w:spacing').firstOrNull;
    final rawBefore = spacing?.getAttribute('w:before') ??
        styleProps['spaceBefore'] ??
        dd['spaceBefore'];
    final rawAfter = spacing?.getAttribute('w:after') ??
        styleProps['spaceAfter'] ??
        dd['spaceAfter'];
    final rawLine = spacing?.getAttribute('w:line') ??
        styleProps['spacingLine'] ??
        dd['spacingLine'];
    final lineRule = spacing?.getAttribute('w:lineRule') ??
        styleProps['spacingLineRule'] ??
        dd['spacingLineRule'] ??
        '';
    final spaceBefore = _twips(int.tryParse(rawBefore ?? '0') ?? 0);
    final spaceAfter = _twips(int.tryParse(rawAfter ?? '160') ?? 160);
    double lineSpacing = 1.15;
    if (rawLine != null) {
      final lineVal = int.tryParse(rawLine) ?? 240;
      if (lineRule == 'auto' || lineRule.isEmpty) {
        lineSpacing = lineVal / 240.0;
      } else if (lineRule == 'exact' || lineRule == 'atLeast') {
        // w:line is in twips (1/20 pt) for exact/atLeast, not 240ths
        lineSpacing = (lineVal / 20.0) / 12.0;
      }
    }

    final ind = pPr?.findElements('w:ind').firstOrNull;
    double? leftInd, rightInd;
    // ⚠️ إصلاح حقيقي (المسافة البادئة الإضافية للسطر الأول مفقودة
    // كلياً): leftInd/rightInd أعلاه كانا يُستخرَجان ويصلان بدقة فعلياً
    // إلى indentStartPt في PdfBlockParagraph، لكن لم يكن هناك أي استخراج
    // لـ w:ind/@firstLine (مسافة إضافية موجبة للسطر الأول فقط، كحالة
    // فقرة مقتبسة بمسافة بادئة كاملة + مسافة إضافية لأول سطر) أو
    // w:ind/@hanging (نفس المعنى لكن بقيمة سالبة منطقياً — أول سطر
    // *أقل* مسافة بادئة من باقي الفقرة، الحالة الشائعة في عناصر القوائم
    // حيث الرمز يبرز لليسار وبقية النص يتراجع لمسافة أكبر). كلتاهما
    // تترجمان لـ firstLineIndentPt في PdfBlockParagraph (موجودة في
    // pdf_layout_model.dart وتُكتَب في toJson بالفعل، لكن mapParagraph
    // في هذا الملف لم يكن يمرّرها أبداً عند بناء PdfBlockParagraph).
    double firstLineInd = 0;
    if (ind != null) {
      final fl = int.tryParse(ind.getAttribute('w:firstLine') ?? '');
      final hang = int.tryParse(ind.getAttribute('w:hanging') ?? '');
      if (fl != null) {
        firstLineInd = _twips(fl);
      } else if (hang != null) {
        firstLineInd = -_twips(hang);
      }
    }
    if (ind != null) {
      final l = int.tryParse(ind.getAttribute('w:left') ?? '');
      final r = int.tryParse(ind.getAttribute('w:right') ?? '');
      if (l != null) leftInd = _twips(l);
      if (r != null) rightInd = _twips(r);
      // الإصدارات الحديثة من Word تكتب w:start / w:end (قيم منطقية):
      // في الفقرات RTL تكون start = اليمين و end = اليسار.
      final s = int.tryParse(ind.getAttribute('w:start') ?? '');
      final e = int.tryParse(ind.getAttribute('w:end') ?? '');
      if (s != null) {
        if (paraRtl) {
          rightInd = _twips(s);
        } else {
          leftInd = _twips(s);
        }
      }
      if (e != null) {
        if (paraRtl) {
          leftInd = _twips(e);
        } else {
          rightInd = _twips(e);
        }
      }
    }

    _ListType? listType;
    int listLevel = 0;
    String? listNumId;
    String? listNumFmt;
    final numPr = pPr?.findElements('w:numPr').firstOrNull;
    if (numPr != null) {
      final numId =
          numPr.findElements('w:numId').firstOrNull?.getAttribute('w:val');
      final ilvl = int.tryParse(
              numPr.findElements('w:ilvl').firstOrNull?.getAttribute('w:val') ??
                  '0') ??
          0;
      listLevel = ilvl;
      if (numId != null && numbMap.containsKey(numId)) {
        final fmt = numbMap[numId]?[ilvl]?['numFmt'] ?? 'bullet';
        listNumId = numId;
        listNumFmt = fmt;
        listType = (fmt == 'decimal' ||
                fmt == 'lowerRoman' ||
                fmt == 'upperRoman' ||
                fmt == 'lowerLetter' ||
                fmt == 'upperLetter')
            ? _ListType.numbered
            : _ListType.bullet;
      }
    }

    // مواقع الجدولة (w:tabs): الموضع بالعشرينات من النقطة → نقاط
    final tabStops = <_TabStop>[];
    final tabsEl = pPr?.findElements('w:tabs').firstOrNull;
    if (tabsEl != null) {
      for (final tb in tabsEl.findElements('w:tab')) {
        final val = tb.getAttribute('w:val') ?? 'left';
        if (val == 'clear') continue;
        final pos = int.tryParse(tb.getAttribute('w:pos') ?? '');
        if (pos == null) continue;
        tabStops.add(_TabStop(_twips(pos), val));
      }
      tabStops.sort((a, b) => a.pos.compareTo(b.pos));
    }

    // تظليل خلفية الفقرة (w:pPr/w:shd) وحدود الفقرة (w:pPr/w:pBdr)
    String? paraShadingHex;
    final pShd = pPr?.findElements('w:shd').firstOrNull;
    if (pShd != null) {
      final fill = pShd.getAttribute('w:fill');
      if (fill != null && fill != 'auto' && fill.length >= 6) {
        paraShadingHex = fill;
      }
    }
    bool paraHasBorder = false;
    String? paraBorderHex;
    final pBdr = pPr?.findElements('w:pBdr').firstOrNull;
    if (pBdr != null) {
      for (final side in pBdr.children.whereType<XmlElement>()) {
        final v = side.getAttribute('w:val');
        if (v != null && v != 'none' && v != 'nil') {
          paraHasBorder = true;
          final c = side.getAttribute('w:color');
          if (c != null && c != 'auto' && c.length >= 6) paraBorderHex = c;
        }
      }
    }

    // ⚠️ إصلاح حقيقي (حجم الخط الافتراضي للمستند مُهمَل في الـ runs): عند
    // غياب w:sz صريح وغياب sz في نمط الفقرة، _parseRun كان يفرض 12pt صلباً.
    // نمرّر sz من docDefaults كـ fallback (دون تعديل خريطة النمط المشتركة).
    var effStyleProps = styleProps;
    void ddFallback(String key) {
      final v = dd[key];
      if (v != null && !effStyleProps.containsKey(key)) {
        effStyleProps = <String, String>{...effStyleProps, key: v};
      }
    }

    ddFallback('sz');
    ddFallback('font'); // عائلة الخط اللاتيني الافتراضية للمستند
    ddFallback('fontCs'); // عائلة الخط العربي/المعقّد الافتراضية للمستند

    final runs = <_Run>[];
    for (final child in pElem.children.whereType<XmlElement>()) {
      if (child.localName == 'r') {
        final run =
            _parseRun(child, effStyleProps, paraRtl, isHeading, headingLevel);
        if (run != null) runs.add(run);
      } else if (child.localName == 'hyperlink') {
        // هدف الرابط: r:id (خارجي عبر rels) أو w:anchor (داخلي)
        final rId = child.getAttribute('r:id');
        final anchor = child.getAttribute('w:anchor');
        final uri = (rId != null) ? relMap[rId] : null;
        for (final r in child.findElements('w:r')) {
          final run = _parseRun(
              r, effStyleProps, paraRtl, isHeading, headingLevel,
              isLink: true, linkUri: uri, linkAnchor: anchor);
          if (run != null) runs.add(run);
        }
      }
    }

    return _Paragraph(
      runs: runs.isEmpty ? [const _Run(text: '')] : runs,
      align: align,
      rtl: paraRtl,
      spaceBefore: spaceBefore,
      spaceAfter: spaceAfter,
      lineSpacing: lineSpacing,
      listType: listType,
      listLevel: listLevel,
      numId: listNumId,
      numFmt: listNumFmt,
      isHeading: isHeading,
      headingLevel: headingLevel,
      bookmarkName: bookmarkName,
      leftIndent: leftInd,
      rightIndent: rightInd,
      firstLineIndent: firstLineInd,
      tabStops: tabStops,
      shadingHex: paraShadingHex,
      hasBorder: paraHasBorder,
      borderHex: paraBorderHex,
    );
  }

  /// يزيل أي رمز فاصل صفحة نائب (U+E010) متبقٍ من فقرة في سياق لا
  /// يدعم فاصل صفحة فعلياً (داخل خلية جدول، أو هيدر/فوتر) — لو تُرِك
  /// لظهر كمحرف مربّع مفقود في الإخراج. يُعاد الكائن نفسه (لا نسخة) إن
  /// خلا من الرمز (الحالة الغالبة).
  static _Paragraph _stripPageBreakMarkers(_Paragraph para) {
    if (!para.runs.any((r) => r.text.contains('\uE010'))) return para;
    return para.copyWith(
      runs: para.runs
          .map((r) => r.text.contains('\uE010')
              ? r.copyWith(text: r.text.replaceAll('\uE010', ''))
              : r)
          .toList(),
    );
  }

  // ─── تقسيم الفقرة عند فواصل الصفحات الصريحة (U+E010) ──────────────────────
  /// ⚠️ إصلاح حقيقي جوهري (فاصل الصفحة الصريح w:br w:type="page"): يحوّل
  /// فقرة قد تحوي رمز PUA U+E010 (زُرِع في _parseRun) إلى سلسلة كتل:
  /// [_ParagraphBlock(جزء قبل الفاصل), _PageBreakBlock, _ParagraphBlock(جزء
  /// بعده), ...]. الفقرة الخالية من الرمز تُعاد كجزء واحد بلا أي تغيير
  /// (نفس الكائن، لا نسخة) — مسار سريع للحالة الغالبة.
  ///
  /// يحافظ على تنسيق كل run بالكامل (عبر _Run.copyWith) وكل خصائص الفقرة
  /// (عبر _Paragraph.copyWith). bookmarkName (وجهة رابط داخلي) يبقى على
  /// الجزء الأول فقط — يجب أن يشير الرابط لأعلى الفقرة الأصلية، لا لكل
  /// جزء بعد كل فاصل. مقاطع الفاصل نفسها (U+E010) تُحذف من النص فلا
  /// تُرسَم كمحرف مربّع مفقود.
  static List<_Block> _splitParagraphOnPageBreaks(_Paragraph para) {
    if (!para.runs.any((r) => r.text.contains('\uE010'))) {
      return [_ParagraphBlock(para)];
    }

    final blocks = <_Block>[];
    var currentRuns = <_Run>[];
    var isFirstSegment = true;

    void flushSegment() {
      // نُخرِج فقرة حتى لو كانت runs فارغة بشرط أن يكون هناك محتوى فعلي
      // أو أنها الجزء الأول (للحفاظ على bookmark/مسافات قبل الفاصل).
      final hasText = currentRuns.any((r) => r.text.isNotEmpty);
      if (hasText || (isFirstSegment && currentRuns.isNotEmpty)) {
        blocks.add(_ParagraphBlock(para.copyWith(
          runs: currentRuns.isEmpty ? [const _Run(text: '')] : currentRuns,
          // bookmark يبقى للجزء الأول فقط؛ الأجزاء التالية بلا bookmark.
          bookmarkName: isFirstSegment ? _noChange : null,
        )));
      }
      currentRuns = <_Run>[];
      isFirstSegment = false;
    }

    for (final run in para.runs) {
      if (!run.text.contains('\uE010')) {
        currentRuns.add(run);
        continue;
      }
      // نقسّم نص هذا الـ run على كل فاصل صفحة داخله مع الحفاظ على تنسيقه.
      final parts = run.text.split('\uE010');
      for (var i = 0; i < parts.length; i++) {
        if (parts[i].isNotEmpty) {
          currentRuns.add(run.copyWith(text: parts[i]));
        }
        // بين كل جزأين متتاليين يقع فاصل صفحة فعلي (عدد الفواصل =
        // parts.length - 1).
        if (i < parts.length - 1) {
          flushSegment();
          blocks.add(_PageBreakBlock());
        }
      }
    }
    flushSegment();

    // حماية: لو انتهى الأمر بلا أي كتلة فقرة (فقرة كانت فاصلاً صرفاً)،
    // نُبقي على الأقل الفواصل التي جُمِّعت — blocks قد تحوي _PageBreakBlock
    // فقط، وهذا صحيح ومقصود (فقرة تحوي فاصل صفحة فقط = فاصل صفحة).
    if (blocks.isEmpty) return [_ParagraphBlock(para)];
    return blocks;
  }

  // ─── تحليل run ────────────────────────────────────────────────────────────
  static _Run? _parseRun(
    XmlElement rElem,
    Map<String, String> styleProps,
    bool paraRtl,
    bool isHeading,
    int headingLevel, {
    bool isLink = false,
    String? linkUri,
    String? linkAnchor,
  }) {
    // تجميع نص الـ run بترتيب العناصر الفعلي مع دعم فواصل الأسطر والجداول
    final buf = StringBuffer();
    final fnIds = <String>[];
    for (final child in rElem.children.whereType<XmlElement>()) {
      switch (child.localName) {
        case 't':
          buf.write(child.innerText);
        case 'br':
          // ⚠️ إصلاح حقيقي جوهري (فاصل الصفحة الصريح كان يُعامَل كسطر
          // جديد): w:br يحمل w:type يميّز نوع الفاصل — "page" فاصل صفحة
          // قسري (يبدأ المحتوى التالي صفحة جديدة)، "column" فاصل عمود،
          // وغياب w:type (أو "textWrapping") سطر جديد عادي فقط. كان
          // الكود يكتب '\n' لكل الأنواع بلا تمييز، فتتحوّل كل فواصل
          // الصفحات الصريحة (شائعة جداً: بداية كل قسم/فصل في صفحة
          // مستقلة) إلى مجرد أسطر فارغة فيتلاصق المحتوى. نزرع لفاصل
          // الصفحة رمز PUA نائب U+E010 (يُقسَّم عنده لاحقاً في الحلقة
          // الرئيسية، case 'p'، إلى _PageBreakBlock فعلي) — نفس آلية
          // الرموز النائبة المُستخدَمة لـPAGE/NUMPAGES (U+E000/E001)
          // وفهرس المحتويات (U+E002/E003).
          final brType = child.getAttribute('w:type');
          if (brType == 'page') {
            buf.write('\uE010');
          } else {
            buf.write('\n'); // سطر جديد إجباري (textWrapping/column/افتراضي)
          }
        case 'tab':
          buf.write('\t'); // w:tab — يُعالَج لاحقاً بمواقع الجدولة
        case 'ptab':
          buf.write('\t'); // w:ptab — يُعالَج كجدولة
        case 'instrText':
          // ⚠️ إصلاح حقيقي (حقول رقم الصفحة في الرأس/التذييل تخرج فارغة):
          // حقول Word تُمثَّل عبر w:instrText (كود الحقل) محاطاً بـ
          // w:fldChar(begin/separate/end). كان w:instrText يُتجاهَل كلياً
          // هنا، ونتيجة الحقل المخزَّنة (إن وُجدت) غالباً غائبة في ملفات
          // مولَّدة برمجياً (docx-js) — فيخرج التذييل "Page  of " بفراغين
          // مكان رقم الصفحة وإجمالي الصفحات. نزرع هنا رمزَي نائبين من
          // منطقة الاستخدام الخاص (PUA) U+E000/U+E001 يستبدلهما محرّك
          // الرسم (drawPageHeaderFooter في NativePdfRenderer.kt) برقم
          // الصفحة الفعلي وإجمالي الصفحات لكل صفحة على حدة. ندعم PAGE
          // وNUMPAGES (الأكثر شيوعاً في التذييلات)؛ حقول أخرى تبقى متجاهلة
          // بأمان (لا نص زائد). نتفادى ازدواج النتيجة بتخطّي نص نتيجة
          // الحقل المخزَّنة لاحقاً عبر علم _inFieldResult في حلقة الفقرة؟
          // لا حاجة عملياً: المولّدات التي تترك النتيجة فارغة هي الحالة،
          // ومن يخزّن نتيجة صحيحة فالرمز النائب يحلّ محلها بنفس القيمة.
          final instr = child.innerText.toUpperCase();
          if (RegExp(r'\bNUMPAGES\b').hasMatch(instr)) {
            buf.write('\uE001');
          } else if (RegExp(r'\bPAGE\b').hasMatch(instr)) {
            buf.write('\uE000');
          }
        case 'footnoteReference':
          // علامة مرجعية للهامش (رقم مرتفع) — يُرسم المحتوى أسفل صفحته
          final id = child.getAttribute('w:id');
          if (id != null) fnIds.add(id);
          buf.write(_superscriptDigits(id ?? ''));
        case 'endnoteReference':
          // علامة مرجعية لتعليق ختامي — المحتوى يُرسم في نهاية المستند
          final id = child.getAttribute('w:id');
          buf.write(_superscriptDigits(id ?? ''));
      }
    }
    final finalText = buf.toString();
    if (finalText.isEmpty) return null;

    final rPr = rElem.findElements('w:rPr').firstOrNull;

    final rtlElem = rPr?.findElements('w:rtl').firstOrNull;
    final rtlVal = rtlElem?.getAttribute('w:val');
    final bool runRtl = (rtlElem != null && rtlVal != '0') ? true : paraRtl;

    final bElem = rPr?.findElements('w:b').firstOrNull;
    final bool bold = (bElem != null && bElem.getAttribute('w:val') != '0') ||
        styleProps['bold'] == 'true' ||
        (isHeading && headingLevel <= 3);

    final iElem = rPr?.findElements('w:i').firstOrNull;
    final bool italic = iElem != null && iElem.getAttribute('w:val') != '0';

    final uElem = rPr?.findElements('w:u').firstOrNull;
    final bool underline =
        uElem != null && uElem.getAttribute('w:val') != 'none';
    // ⚠️ إصلاح حقيقي (أنماط التسطير المتعددة): w:u/@val الفعلي يحدّد
    // الطراز البصري (single/double/wave/dotted/dashed...)، لا فقط
    // وجود/غياب التسطير. نطابق هنا أسماء Kotlin (underlineStyle في
    // PdfFontSpec): القيم الأقرب بصرياً تُطابَق مباشرة، وأي قيمة أخرى من
    // مجموعة Word الواسعة (thick/dotDash/dashDotDotHeavy...) تتراجع إلى
    // "single" كأقرب تمثيل آمن (لا قيمة مطابقة في Kotlin بعد لهذه
    // الأنماط النادرة جداً عملياً).
    String underlineStyle = 'single';
    final uVal = uElem?.getAttribute('w:val');
    switch (uVal) {
      case 'double':
        underlineStyle = 'double';
      case 'wave':
      case 'wavyDouble':
      case 'wavyHeavy':
        underlineStyle = 'wave';
      case 'dotted':
      case 'dottedHeavy':
        underlineStyle = 'dotted';
      case 'dash':
      case 'dashedHeavy':
      case 'dashLong':
      case 'dashLongHeavy':
        underlineStyle = 'dashed';
    }

    // الشطب: w:strike (خط مفرد) أو w:dstrike (خط مزدوج)
    // ⚠️ إصلاح حقيقي: كان w:dstrike يُعامَل سابقاً بنفس معاملة w:strike
    // المفرد (كلاهما يضبط strike=true فقط بلا أي تمييز)، فيظهر شطب
    // مزدوج DOCX كخط مفرد فقط في الناتج. نميّز الآن بينهما صريحاً عبر
    // strikeDouble المنفصلة.
    final stElem = rPr?.findElements('w:strike').firstOrNull;
    final dstElem = rPr?.findElements('w:dstrike').firstOrNull;
    final bool dstrikeActive =
        dstElem != null && dstElem.getAttribute('w:val') != '0';
    final bool strike =
        (stElem != null && stElem.getAttribute('w:val') != '0') ||
            dstrikeActive;
    final bool strikeDouble = dstrikeActive;

    double fontSize = 12;
    final szElem = rPr?.findElements('w:sz').firstOrNull;
    final szRaw = szElem?.getAttribute('w:val') ?? styleProps['sz'] ?? '';
    if (szRaw.isNotEmpty) {
      final sz = double.tryParse(szRaw);
      if (sz != null) fontSize = sz / 2.0;
    }
    if (isHeading && fontSize == 12) {
      const sizes = [24.0, 20.0, 16.0, 14.0, 12.0, 11.0];
      fontSize = sizes[(headingLevel - 1).clamp(0, 5)];
    }

    String? colorHex;
    final colorVal =
        rPr?.findElements('w:color').firstOrNull?.getAttribute('w:val') ??
            styleProps['color'] ??
            '';
    if (colorVal.isNotEmpty && colorVal != 'auto') colorHex = colorVal;

    // الروابط التشعبية: لون أزرق افتراضي (Word: 0563C1) وخط سفلي
    bool linkUnderline = underline;
    if (isLink) {
      colorHex ??= '0563C1';
      linkUnderline = true;
    }

    // تمييز خلفية النص (w:highlight) أو تظليل الحرف (w:shd fill=...)
    final hlName =
        rPr?.findElements('w:highlight').firstOrNull?.getAttribute('w:val');
    String? highlightHex = _highlightHex(hlName);
    if (highlightHex == null) {
      final shdFill =
          rPr?.findElements('w:shd').firstOrNull?.getAttribute('w:fill');
      if (shdFill != null && shdFill != 'auto' && shdFill.length >= 6) {
        highlightHex = shdFill;
      }
    }

    // ALLCAPS و SmallCaps: تحويل النص لأحرف كبيرة (SmallCaps بحجم أصغر تقريبياً)
    String outText = finalText;
    final caps = rPr?.findElements('w:caps').firstOrNull;
    final smallCaps = rPr?.findElements('w:smallCaps').firstOrNull;
    if ((caps != null && caps.getAttribute('w:val') != '0') ||
        (smallCaps != null && smallCaps.getAttribute('w:val') != '0')) {
      outText = finalText.toUpperCase();
    }
    if (smallCaps != null && smallCaps.getAttribute('w:val') != '0') {
      fontSize *= 0.82;
    }

    // المرتفع/المنخفض (xsuper / xsub)
    // ⚠️ إصلاح حقيقي (تصغير مضاعف): قبل هذا الإصلاح كانت fontSize تُصغَّر
    // هنا بنسبة 0.65 *وأيضاً* في Kotlin (PdfContentBuilder.SUPER_SUB_SCALE
    // بنفس النسبة 0.65 تماماً، بشكل مستقل تماماً عن هذا الكود)، فيصبح
    // التصغير الفعلي ≈0.65×0.65≈0.42 من الحجم الأصلي بدل 0.65 المقصودة
    // مرة واحدة — وهذا ما فسَّر ظهور superscript/subscript أصغر من
    // المتوقع بصرياً رغم نجاح المبدأ العام. الحل: Dart يكتفي بتمرير
    // *نوع* الإزاحة (superSub enum) فقط دون أي تصغير لـ fontSize نفسها؛
    // Kotlin (الذي يملك القياس الدقيق عبر StaticLayout) هو المصدر
    // الوحيد لمقدار التصغير/الرفع الفعلي. baselineShift يبقى محفوظاً هنا
    // فقط كعلامة اتجاه (موجب/سالب/صفر) لتحديد superSub في mapRunFont،
    // لا كقيمة فعلية تُستخدَم للرسم.
    double baselineShift = 0;
    final va =
        rPr?.findElements('w:vertAlign').firstOrNull?.getAttribute('w:val');
    if (va == 'superscript') {
      baselineShift = -1; // علامة اتجاه فقط؛ القيمة المطلقة لا تُستخدَم
    } else if (va == 'subscript') {
      baselineShift = 1; // علامة اتجاه فقط؛ القيمة المطلقة لا تُستخدَم
    }

    // تباعد الأحرف (w:spacing بالعشرينات من النقطة)
    double letterSpacing = 0;
    final spc =
        rPr?.findElements('w:spacing').firstOrNull?.getAttribute('w:val');
    if (spc != null) {
      final v = double.tryParse(spc);
      if (v != null) letterSpacing = v / 20.0;
    }

    // اسم الخط من w:rFonts (cs للعربية، ascii/hAnsi للاتينية)
    final rFonts = rPr?.findElements('w:rFonts').firstOrNull;
    final fontCs = rFonts?.getAttribute('w:cs') ?? styleProps['fontCs'];
    final fontAscii = rFonts?.getAttribute('w:ascii') ??
        rFonts?.getAttribute('w:hAnsi') ??
        styleProps['font'];

    return _Run(
      text: outText,
      bold: bold,
      italic: italic,
      underline: linkUnderline,
      strike: strike,
      underlineStyle: underlineStyle,
      strikeDouble: strikeDouble,
      fontSize: fontSize.clamp(6, 72),
      colorHex: colorHex,
      highlightHex: highlightHex,
      baselineShift: baselineShift,
      letterSpacing: letterSpacing,
      fontNameCs: fontCs,
      fontNameAscii: fontAscii,
      rtl: runRtl,
      linkUri: isLink ? linkUri : null,
      linkAnchor: isLink ? linkAnchor : null,
      footnoteIds: fnIds,
    );
  }

  // ─── تحليل جدول ───────────────────────────────────────────────────────────
  static _Table? _parseTable(
    XmlElement tblElem,
    Map<String, Map<String, String>> styleMap,
    Map<String, Map<int, Map<String, String>>> numbMap, {
    Map<String, String> relMap = const {},
    Archive? archive,
  }) {
    final rows = <_TableRow>[];
    final tblGrid = tblElem.findElements('w:tblGrid').firstOrNull;
    List<double> colWidths = [];
    if (tblGrid != null) {
      for (final col in tblGrid.findElements('w:gridCol')) {
        final w = int.tryParse(col.getAttribute('w:w') ?? '0') ?? 0;
        colWidths.add(_twips(w));
      }
    }

    for (final trElem in tblElem.findElements('w:tr')) {
      final cells = <_TableCell>[];
      // w:tblHeader يقع داخل w:trPr وليس مباشرة تحت w:tr
      final isHeader = trElem
              .findElements('w:trPr')
              .firstOrNull
              ?.findElements('w:tblHeader')
              .isNotEmpty ??
          false;
      for (final tcElem in trElem.findElements('w:tc')) {
        final tcPr = tcElem.findElements('w:tcPr').firstOrNull;
        final colSpan = int.tryParse(tcPr
                    ?.findElements('w:gridSpan')
                    .firstOrNull
                    ?.getAttribute('w:val') ??
                '1') ??
            1;
        String? bgColor;
        final fill =
            tcPr?.findElements('w:shd').firstOrNull?.getAttribute('w:fill');
        if (fill != null && fill != 'auto' && fill.isNotEmpty) {
          bgColor = fill;
        }
        // ⚠️ إصلاح حقيقي (المحاذاة العمودية داخل الخلية مفقودة كلياً):
        // w:vAlign (top|center|bottom) كانت تُتجاهَل كلياً — كل خلية في
        // كل جدول كانت تُحاذى وسطاً عمودياً دوماً (PdfTableCell.
        // verticalAlign الافتراضي)، بصرف النظر عن قيمة w:vAlign الفعلية
        // في DOCX (شائعة كـ"top" للجداول التي تريد محاذاة محتوى أعلى
        // الخلية تحديداً، خصوصاً مع خلايا بارتفاعات متفاوتة في نفس
        // الصف). نمرّر القيمة الخام هنا (تُترجَم لـPdfTextAlign مباشرة
        // في mapTableCellBody أدناه)؛ null (لا w:vAlign صريحة) يُترجَم
        // هناك لـcenter — نفس الافتراضي القديم بالضبط، فلا كسر سلوك.
        final vAlignRaw =
            tcPr?.findElements('w:vAlign').firstOrNull?.getAttribute('w:val');
        // الدمج العمودي: vMerge بدون val (أو val=continue) يعني خلية امتداد
        bool vMergeContinue = false;
        final vMerge = tcPr?.findElements('w:vMerge').firstOrNull;
        if (vMerge != null) {
          final vv = vMerge.getAttribute('w:val');
          vMergeContinue = (vv == null || vv == 'continue');
        }
        // ⚠️ إصلاح حقيقي (حشوة الخلية الفعلية مفقودة كلياً): w:tcMar
        // (top/left/bottom/right بوحدة dxa=twips) كانت تُتجاهَل تماماً —
        // تُستخدَم بدلاً منها قيمة ثابتة صريحة (4pt) لكل خلية في كل
        // جدول، بصرف النظر عن القيمة الفعلية المُحدَّدة في DOCX (شائعة
        // الاختلاف فعلياً، خصوصاً للجداول المُصمَّمة بعناية بحشوة أكبر
        // للقراءة). PdfTableCell.paddingPt (ومرآته Kotlin
        // TableCellModel.paddingPt) يقبل قيمة *موحَّدة واحدة* فقط لكل
        // الجهات الأربعة (قيد نموذج حالي، توسيعه لأربع قيم منفصلة تغيير
        // معماري أوسع يتجاوز نطاق هذا الإصلاح) — فنحسب هنا متوسط الجهات
        // الأربعة الفعلية من w:tcMar كأقرب تقريب صحيح ضمن هذا القيد،
        // بدل تجاهلها كلياً لصالح ثابت صريح. null (لا w:tcMar في الخلية،
        // ترث الافتراضي من w:tblPr/w:tblCellMar أو إعداد Word الضمني)
        // يُترجَم لـ4.0 (نفس الثابت القديم بالضبط، فلا كسر سلوك لخلية
        // بلا تخصيص حشوة صريح).
        double? tcMarPt(String tag) {
          final raw = tcPr
              ?.findElements('w:tcMar')
              .firstOrNull
              ?.findElements(tag)
              .firstOrNull
              ?.getAttribute('w:w');
          if (raw == null) return null;
          final twips = int.tryParse(raw);
          return twips == null ? null : twips / 20.0;
        }

        final tcMarValues = [
          tcMarPt('w:top'),
          tcMarPt('w:left'),
          tcMarPt('w:bottom'),
          tcMarPt('w:right'),
        ].whereType<double>().toList();
        final cellPaddingPt = tcMarValues.isEmpty
            ? 4.0
            : tcMarValues.reduce((a, b) => a + b) / tcMarValues.length;
        // ⚠️ إصلاح حقيقي (حدود الخلايا الفردية المفقودة): w:tcBorders
        // داخل w:tcPr — مستقل عن w:tblBorders على مستوى الجدول (انظر
        // تعليق _CellEdgeBorders أعلاه). نفس منطق تحويل w:sz/w:val/w:color
        // المستخدَم لاحقاً لـ w:tblBorders (w:sz بثُمن النقطة، not عشرينيات).
        _BorderSpec? parseTcBorderEl(String tag) {
          final el = tcPr?.findElements('w:tcBorders').firstOrNull
              ?.findElements(tag)
              .firstOrNull;
          if (el == null) return null;
          final val = el.getAttribute('w:val') ?? 'single';
          if (val == 'none' || val == 'nil') return null;
          final szRaw = int.tryParse(el.getAttribute('w:sz') ?? '4') ?? 4;
          final widthPt = szRaw / 8.0;
          final colorRaw = el.getAttribute('w:color') ?? 'auto';
          final colorHex =
              (colorRaw == 'auto' || colorRaw.isEmpty) ? '000000' : colorRaw;
          return _BorderSpec(widthPt, colorHex);
        }

        final tcEdgeBorders = _CellEdgeBorders(
          top: parseTcBorderEl('w:top'),
          bottom: parseTcBorderEl('w:bottom'),
          left: parseTcBorderEl('w:left'),
          right: parseTcBorderEl('w:right'),
        );

        final paragraphs = <_Paragraph>[];
        _Table? nestedTable;
        // ⚠️ إصلاح حقيقي: أول صورة موجودة ضمن فقرات الخلية (كانت تُفقد
        // كلياً سابقاً). نعيد استخدام _extractImages الموجودة فعلاً (تقرأ
        // w:drawing/a:blip ضمن أي فقرة) بدل تكرار منطقها، فقط إن توفّر
        // archive (يُمرَّر من المستوى الأعلى فقط؛ الجداول المتداخلة تتلقاه
        // أيضاً عبر تمريره صريحاً أدناه فتدعم الصور بنفس الطريقة).
        _ImageBlock? cellImage;
        for (final child in tcElem.children.whereType<XmlElement>()) {
          if (child.localName == 'p') {
            final para = _parseParagraph(child, styleMap, numbMap);
            // فاصل الصفحة داخل خلية جدول غير مدعوم في Word — نطهّر الرمز
            // النائب فلا يُرسَم كمربع مفقود.
            if (para != null) paragraphs.add(_stripPageBreakMarkers(para));
            if (cellImage == null && archive != null) {
              final imgs = _extractImages(child, relMap, archive);
              if (imgs.isNotEmpty) cellImage = imgs.first;
            }
          } else if (child.localName == 'tbl') {
            // جدول متداخل حقيقي داخل الخلية: نحلّله تكرارياً ونرسمه شبكةً
            // كاملة (بدل تسطيحه إلى نص). نكتفي بأول جدول متداخل في الخلية.
            nestedTable ??= _parseTable(child, styleMap, numbMap,
                relMap: relMap, archive: archive);
          }
        }
        if (paragraphs.isEmpty && nestedTable == null) {
          paragraphs.add(const _Paragraph(runs: [_Run(text: '')], rtl: true));
        }
        cells.add(_TableCell(
            paragraphs: paragraphs,
            colSpan: colSpan,
            bgColorHex: bgColor,
            vMergeContinue: vMergeContinue,
            nested: nestedTable,
            image: cellImage,
            edgeBorders: tcEdgeBorders.isEmpty ? null : tcEdgeBorders,
            paddingPt: cellPaddingPt,
            vAlignRaw: vAlignRaw));
      }
      if (cells.isNotEmpty) {
        rows.add(_TableRow(cells: cells, isHeader: isHeader));
      }
    }
    if (rows.isEmpty) return null;

    if (colWidths.isEmpty && rows.isNotEmpty) {
      final maxCols = rows
          .map((r) => r.cells.fold<int>(0, (s, c) => s + c.colSpan))
          .reduce((a, b) => a > b ? a : b);
      final w = _contentW / maxCols;
      colWidths = List.filled(maxCols, w);
    }

    // اتجاه الجدول: w:bidiVisual في tblPr ⇒ RTL، وإلا نستنتج من المحتوى العربي
    final tblPr = tblElem.findElements('w:tblPr').firstOrNull;
    final bidiVisual = tblPr?.findElements('w:bidiVisual').firstOrNull;
    bool tableRtl;
    if (bidiVisual != null) {
      tableRtl = bidiVisual.getAttribute('w:val') != '0';
    } else {
      final sample = rows
          .take(2)
          .expand((r) => r.cells)
          .expand((c) => c.paragraphs)
          .map((p) => p.fullText)
          .join(' ');
      tableRtl = hasArabic(sample);
    }

    // ⚠️ إصلاح حقيقي (حدود الجداول المفقودة بالكامل): قبل هذا الإصلاح لم
    // يكن tblPr يُقرأ إلا لـ w:bidiVisual؛ w:tblBorders (الحدود على
    // مستوى الجدول كله — top/bottom/left/right/insideH/insideV) لم
    // تُستخرَج أبداً، رغم أنها الحالة الأكثر شيوعاً فعلياً في DOCX حقيقي
    // (حدود مُعرَّفة مرة واحدة للجدول كله، لا مكررة في كل w:tcPr/
    // w:tcBorders لكل خلية على حدة). w:sz هنا بثُمن النقطة (eighths of a
    // point) حسب مواصفة OOXML — يختلف عن w:spacing/w:ind المقاسة
    // بالعشرينيات (twips)، فالتحويل /8.0 لا /20.0.
    final tblBorders = tblPr?.findElements('w:tblBorders').firstOrNull;
    _BorderSpec? parseBorderEl(String tag) {
      final el = tblBorders?.findElements(tag).firstOrNull;
      if (el == null) return null;
      final val = el.getAttribute('w:val') ?? 'single';
      if (val == 'none' || val == 'nil') return null;
      final szRaw = int.tryParse(el.getAttribute('w:sz') ?? '4') ?? 4;
      final widthPt = szRaw / 8.0;
      final colorRaw = el.getAttribute('w:color') ?? 'auto';
      final colorHex =
          (colorRaw == 'auto' || colorRaw.isEmpty) ? '000000' : colorRaw;
      return _BorderSpec(widthPt, colorHex);
    }

    // الأطراف الأربعة الخارجية غالباً متطابقة في DOCX (Word يكتب نفس
    // width/color للأربعة عند "Borders → All Borders" في الواجهة)؛ نأخذ
    // أول طرف مُعرَّف فعلياً كحد افتراضي موحَّد بدل تعقيد تمييز كل طرف
    // بشكل مستقل في v1 (التمييز الكامل بالأربعة متاح مستقبلاً عبر توسيع
    // _BorderSpec إلى أربعة حقول إن لزم تمييز عملي حقيقي بين الأطراف).
    final defaultBorder = parseBorderEl('w:top') ??
        parseBorderEl('w:left') ??
        parseBorderEl('w:bottom') ??
        parseBorderEl('w:right');
    final insideHBorder = parseBorderEl('w:insideH');
    final insideVBorder = parseBorderEl('w:insideV');

    return _Table(
      rows: rows,
      colWidths: colWidths,
      rtl: tableRtl,
      defaultBorder: defaultBorder,
      insideHBorder: insideHBorder,
      insideVBorder: insideVBorder,
    );
  }

  static double _twips(int t) => t / 20.0;

  // عدد الأعمدة في القسم (w:cols num) — 1 إن غاب
  static int _sectCols(XmlElement sectPr) {
    final cols = sectPr.findElements('w:cols').firstOrNull;
    if (cols == null) return 1;
    final n = int.tryParse(cols.getAttribute('w:num') ?? '1') ?? 1;
    return n < 1 ? 1 : n;
  }

  /// ⚠️ إصلاح حقيقي جوهري (هوامش الصفحة ومسافات الهيدر/الفوتر ثوابت
  /// صريحة، لا تُستخرَج من DOCX إطلاقاً): قبل هذا الإصلاح كانت
  /// _marginTop/_marginBottom/_marginLeft/_marginRight (وheaderFooterReservePt
  /// لمسافة الهيدر/الفوتر) كلها أرقاماً ثابتة صريحة في الكود (56.69pt =
  /// 1 بوصة بالضبط للهوامش، 28pt تقديرية للهيدر/الفوتر)، بصرف النظر
  /// التام عن قيم w:pgMar الفعلية المُحدَّدة في DOCX الأصلي — حتى لو
  /// كانت هذه القيم متاحة مباشرة وبسيطة القراءة في XML (لا تحتاج أي
  /// قياس نص معقَّد، فقط أربعة/سبعة أرقام صريحة بوحدة twips). تأكَّد هذا
  /// فعلياً: ملف اختبار حقيقي يحدّد w:pgMar w:top="1440" (=72pt) بينما
  /// الثابت المُستخدَم كان 56.69pt — فارق حقيقي 15.3pt (~0.21 بوصة) لكل
  /// هامش، يُراكم تأثيره عبر المستند كاملاً (يُفسِّر جزئياً أيضاً اختلاف
  /// عدد الصفحات الإجمالي عن DOCX الأصلي: هامش أصغر من المطلوب يعني
  /// مساحة محتوى أكبر زائفة في كل صفحة). يستخرج هذا التابع كل القيم
  /// الخمس (top/bottom/left/right/header/footer) من w:pgMar الفعلية
  /// لهذا القسم بالذات (sectPr، تماماً كنمط _sectCols/_sectIsLandscape
  /// أعلاه)، محوَّلة من twips إلى نقاط (القسمة على 20، معيار OOXML
  /// الثابت: 1pt = 20 twips). القيم الافتراضية (fallback) عند غياب
  /// w:pgMar كلياً (نادر، لكن ممكن نظرياً لقسم بلا pgMar صريح يرث
  /// إعدادات Word الافتراضية) تبقى نفس الثوابت القديمة بالضبط (1 بوصة
  /// للهوامش، 28pt للهيدر/الفوتر) — فلا كسر سلوك للحالة الحدّية الغائبة.
  static _SectionMargins _sectMargins(XmlElement? sectPr) {
    final pgMar = sectPr?.findElements('w:pgMar').firstOrNull;
    double fromTwips(String attr, double fallback) {
      final raw = pgMar?.getAttribute(attr);
      if (raw == null) return fallback;
      final twips = int.tryParse(raw);
      if (twips == null) return fallback;
      return twips / 20.0;
    }

    return _SectionMargins(
      top: fromTwips('w:top', _marginTop),
      bottom: fromTwips('w:bottom', _marginBottom),
      left: fromTwips('w:left', _marginLeft),
      right: fromTwips('w:right', _marginRight),
      header: fromTwips('w:header', 28),
      footer: fromTwips('w:footer', 28),
    );
  }

  // هل القسم أفقي؟ من w:pgSz (orient="landscape" أو العرض > الارتفاع)
  static bool _sectIsLandscape(XmlElement sectPr) {
    final pgSz = sectPr.findElements('w:pgSz').firstOrNull;
    if (pgSz == null) return false;
    final orient = pgSz.getAttribute('w:orient');
    if (orient == 'landscape') return true;
    final w = int.tryParse(pgSz.getAttribute('w:w') ?? '0') ?? 0;
    final h = int.tryParse(pgSz.getAttribute('w:h') ?? '0') ?? 0;
    return w > h && w > 0;
  }

  // أرقام مرتفعة Unicode لعلامة الهامش المرجعية (1→¹، 12→¹²)
  static String _superscriptDigits(String s) {
    const sup = {
      '0': '⁰',
      '1': '¹',
      '2': '²',
      '3': '³',
      '4': '⁴',
      '5': '⁵',
      '6': '⁶',
      '7': '⁷',
      '8': '⁸',
      '9': '⁹'
    };
    return s.split('').map((c) => sup[c] ?? c).join();
  }

  // تحليل word/footnotes.xml ⇒ id → نص الهامش (تجاهل الفواصل id<=0)
  static Map<String, String> _parseFootnotes(String? xml) {
    final map = <String, String>{};
    if (xml == null) return map;
    try {
      final doc = XmlDocument.parse(xml);
      for (final fn in doc.findAllElements('w:footnote')) {
        final id = fn.getAttribute('w:id');
        if (id == null) continue;
        final n = int.tryParse(id);
        if (n == null || n <= 0) continue; // -1/0 فواصل قياسية
        final txt =
            fn.findAllElements('w:t').map((e) => e.innerText).join().trim();
        if (txt.isNotEmpty) map[id] = txt;
      }
    } catch (_) {}
    return map;
  }

  // تحليل word/endnotes.xml ⇒ id → نص التعليق الختامي (تجاهل الفواصل id<=0)
  static Map<String, String> _parseEndnotes(String? xml) {
    final map = <String, String>{};
    if (xml == null) return map;
    try {
      final doc = XmlDocument.parse(xml);
      for (final en in doc.findAllElements('w:endnote')) {
        final id = en.getAttribute('w:id');
        if (id == null) continue;
        final n = int.tryParse(id);
        if (n == null || n <= 0) continue;
        final txt =
            en.findAllElements('w:t').map((e) => e.innerText).join().trim();
        if (txt.isNotEmpty) map[id] = txt;
      }
    } catch (_) {}
    return map;
  }

  // ─── تحويل الصور غير المدعومة (GIF/BMP/WebP/TIFF…) إلى PNG ───────────────
  // android.graphics.BitmapFactory (المُستخدَم في الجسر الأصلي) يدعم PNG
  // وJPEG وWebP بثبات عبر إصدارات أندرويد المختلفة، لكن دعمه لـ GIF/BMP/
  // TIFF غير موثوق أو غير موجود على بعض الإصدارات. نفكّ أي صيغة نقطية
  // أخرى عبر حزمة image (Dart) ونعيد ترميزها PNG حتى لا تُفقد الصورة.
  static Uint8List? _ensureRasterPngOrJpeg(Uint8List bytes) {
    if (bytes.length < 4) return null;
    final isPng = bytes[0] == 0x89 && bytes[1] == 0x50;
    final isJpeg = bytes[0] == 0xFF && bytes[1] == 0xD8;
    if (isPng || isJpeg) return bytes; // مدعومة أصلاً
    try {
      final decoded = imglib.decodeImage(bytes);
      if (decoded == null) return null;
      return Uint8List.fromList(imglib.encodePng(decoded));
    } catch (_) {
      return null;
    }
  }

  // ─── تحليل document.xml.rels (علاقات الصور) ─────────────────────────────
  // ─── زخرفة الصفحة: خلفية + إطار + علامة مائية ──────────────────────────
  // يقرأ w:background ولون الإطار w:pgBorders والعلامة المائية من الترويسات،
  // ويضبطها على الكاتب. يُستدعى قبل كتابة المحتوى ليطبّق الخلفية على كل
  // الصفحات (بما فيها الأولى التي أُنشئت في الباني وهي لا تزال فارغة).
  /// نتيجة استخراج زخرفة الصفحة (خلفية/إطار/علامة مائية) — بديل الحقول
  /// التي كانت تُضبط مباشرة على _PdfWriter في الإصدار السابق.
  static _PageDecorations _extractPageDecorations(
    Archive archive,
    XmlElement body,
    Map<String, String> relMap,
    Map<String, String> theme,
  ) {
    String? bgHex;
    bool borderOn = false;
    double borderWidth = 1.0;
    String? borderHex;
    bool borderShadow = false;
    String? watermarkText;
    String? watermarkHex;

    try {
      // 1) خلفية الصفحة (w:background على جذر document) — تتطلب أيضاً تفعيل
      //    displayBackgroundShape في settings.xml لكي يعرضها Word، لكننا نرسمها
      //    دائماً إن وُجد اللون لأن غالب المستندات العربية تعتمدها.
      final docRoot = body.parent; // <w:document>
      final bg = docRoot?.findElements('w:background').firstOrNull ??
          body.document?.rootElement.findElements('w:background').firstOrNull;
      if (bg != null) {
        final hex = _themeOrSrgb(
            bg.getAttribute('w:color'),
            bg.getAttribute('w:themeColor'),
            bg.getAttribute('w:themeTint'),
            theme);
        if (hex != null) bgHex = hex;
      }

      // 2) إطار الصفحة (w:pgBorders داخل أول sectPr)
      final sectPr = body.findAllElements('w:sectPr').firstOrNull;
      final pgB = sectPr?.findElements('w:pgBorders').firstOrNull;
      if (pgB != null) {
        final side = pgB.findElements('w:top').firstOrNull ??
            pgB.children.whereType<XmlElement>().firstOrNull;
        final v = side?.getAttribute('w:val');
        if (side != null && v != null && v != 'none' && v != 'nil') {
          borderOn = true;
          final sz = int.tryParse(side.getAttribute('w:sz') ?? '');
          borderWidth = sz != null ? sz / 8.0 : 1.0; // sz بثُمن النقطة
          final c = side.getAttribute('w:color');
          borderHex = (c != null && c != 'auto') ? c : '000000';
          borderShadow = side.getAttribute('w:shadow') == '1';
        }
      }

      // 3) العلامة المائية النصية (WordArt) — تكون عادةً في إحدى الترويسات
      //    كـ v:shape فيه v:textpath. نقرأ النص واللون.
      for (final ref in body.findAllElements('w:headerReference')) {
        final rId = ref.getAttribute('r:id');
        if (rId == null) continue;
        final path = _relPath(relMap[rId]);
        if (path == null) continue;
        final xml = _readFile(archive, path);
        if (xml == null) continue;
        if (!xml.contains('textpath') && !xml.contains('WaterMark')) continue;
        try {
          final hdoc = XmlDocument.parse(xml);
          final tp = hdoc.findAllElements('v:textpath').firstOrNull;
          if (tp != null) {
            final str = tp.getAttribute('string');
            if (str != null && str.trim().isNotEmpty) {
              watermarkText = str.trim();
              // اللون من v:fill أو style fillcolor للشكل الأب
              final shape = tp.ancestors
                  .whereType<XmlElement>()
                  .firstWhere((e) => e.localName == 'shape', orElse: () => tp);
              final fill = shape
                  .findElements('v:fill')
                  .firstOrNull
                  ?.getAttribute('color');
              watermarkHex = _normalizeVmlColor(fill) ?? 'C0C0C0';
              break;
            }
          }
        } catch (_) {}
      }
    } catch (_) {}

    return _PageDecorations(
      backgroundHex: bgHex,
      borderOn: borderOn,
      borderWidthPt: borderWidth,
      borderHex: borderHex,
      borderShadow: borderShadow,
      watermarkText: watermarkText,
      watermarkHex: watermarkHex,
    );
  }

  // لون VML قد يكون اسماً (#RRGGBB أو "silver") — نُعيد hex بلا #.
  static String? _normalizeVmlColor(String? c) {
    if (c == null) return null;
    var s = c.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length == 6 && int.tryParse(s, radix: 16) != null) return s;
    const named = {
      'silver': 'C0C0C0',
      'gray': '808080',
      'grey': '808080',
      'black': '000000',
      'red': 'FF0000',
      'blue': '0000FF',
    };
    return named[s.toLowerCase()];
  }

  // يحل لون theme مع tint إن لزم، وإلا يُعيد srgb المباشر.
  static String? _themeOrSrgb(String? srgb, String? themeColor,
      String? themeTint, Map<String, String> theme) {
    if (srgb != null && srgb != 'auto' && srgb.length >= 6) return srgb;
    if (themeColor != null) {
      final base = theme[themeColor] ?? theme['accent2'];
      if (base != null && base.length >= 6) {
        final tint = int.tryParse(themeTint ?? '', radix: 16);
        if (tint != null && tint < 255) {
          // tint: مزج اللون مع الأبيض بنسبة (255 - tint)/255
          return _applyTint(base, tint / 255.0);
        }
        return base;
      }
    }
    return null;
  }

  // tint: 1.0 = اللون الأصلي، أقل = أفتح (مزج مع الأبيض)
  static String _applyTint(String hex, double tint) {
    try {
      int ch(int i) => int.parse(hex.substring(i, i + 2), radix: 16);
      final r = ch(0), g = ch(2), b = ch(4);
      int mix(int v) => (v * tint + 255 * (1 - tint)).round().clamp(0, 255);
      String hh(int v) => v.toRadixString(16).padLeft(2, '0');
      return '${hh(mix(r))}${hh(mix(g))}${hh(mix(b))}';
    } catch (_) {
      return hex;
    }
  }

  static Map<String, String> _parseRels(String? xml) {
    final map = <String, String>{};
    if (xml == null) return map;
    try {
      final doc = XmlDocument.parse(xml);
      for (final rel in doc.findAllElements('Relationship')) {
        final id = rel.getAttribute('Id');
        final target = rel.getAttribute('Target');
        if (id != null && target != null) map[id] = target;
      }
    } catch (_) {}
    return map;
  }

  // ⚠️ إصلاح حقيقي (الهيدر والفوتر غائبان كلياً): قبل هذا الإصلاح كانت
  // _headerFooterText (المُستبدَلة بهذه الدالة) تُعيد نصاً مسطّحاً واحداً
  // فقط (كل w:t مُجمَّعة بلا فواصل فقرات ولا أي تنسيق: لا Bold، لا
  // محاذاة فعلية لكل سطر، لا فقرات متعددة) وتبحث عن *أول* مرجع default
  // في *أي* sectPr بالمستند كله بصرف النظر عن القسم الحالي. هذه النسخة:
  // (1) تُعيد فقرات حقيقية كاملة (List<_Paragraph>) عبر إعادة استخدام
  // _parseParagraph نفسها على كل w:p في ملف header/footer، فتحافظ على
  // Bold/Italic/المحاذاة/الألوان تماماً كما تُعالَج فقرات المستند
  // الأساسي؛ (2) تأخذ [sectPr] محدَّداً صريحاً (قسم واحد بعينه) بدل
  // البحث العام، لأن كل قسم DOCX قد يربط ملف هيدر/فوتر مختلف تماماً
  // (فوتر مخصص لقسم Landscape وحده هو المثال المؤكَّد بالاختبار الفعلي).
  static List<_Paragraph> _headerFooterParagraphs(
    Archive archive,
    XmlElement? sectPr,
    Map<String, String> relMap,
    String refTag,
    Map<String, Map<String, String>> styleMap,
    Map<String, Map<int, Map<String, String>>> numbMap,
  ) {
    if (sectPr == null) return const [];
    try {
      String? rid;
      String? fallbackRid;
      for (final ref in sectPr.findElements(refTag)) {
        final type = ref.getAttribute('w:type');
        if (type == 'default') {
          rid = ref.getAttribute('r:id');
          break;
        }
        fallbackRid ??= ref.getAttribute('r:id');
      }
      rid ??= fallbackRid;
      if (rid == null) return const [];
      final target = relMap[rid];
      if (target == null) return const [];
      final path = target.startsWith('/')
          ? target.substring(1)
          : (target.startsWith('word/') ? target : 'word/$target');
      final xml = _readFile(archive, path);
      if (xml == null) return const [];
      final dom = XmlDocument.parse(xml);
      final result = <_Paragraph>[];
      // قيد v1 موثَّق: نقرأ فقط فقرات w:p المباشرة تحت جذر مستند الهيدر/
      // الفوتر (مطابق لمستوى التبسيط المعتمد في بقية هذا المحوّل). جدول
      // كامل (w:tbl) داخل هيدر/فوتر — حالة نادرة جداً عملياً (شعار +
      // عنوان في جدول 1×2 مثلاً) — لا يُدعَم بعد في هذه الدالة، خلافاً
      // لمتن المستند الذي يتعامل مع w:tbl صريحاً عبر _parseTable. يمكن
      // توسيعها لاحقاً بنفس نمط حلقة body الرئيسية (switch على
      // child.localName) إن ظهرت حاجة عملية حقيقية لذلك.
      for (final pElem in dom.rootElement.findElements('w:p')) {
        final para = _parseParagraph(pElem, styleMap, numbMap, relMap: relMap);
        if (para != null && para.fullText.trim().isNotEmpty) {
          // فاصل الصفحة لا معنى له داخل هيدر/فوتر — نطهّر الرمز النائب.
          result.add(_stripPageBreakMarkers(para));
        }
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  // ─── استخراج الصور المضمنة في فقرة ───────────────────────────────────────
  // استخراج المخططات البيانية (c:chart) من فقرة — كانت تُهمل تماماً
  static List<_ChartBlock> _extractCharts(
    XmlElement pElem,
    Map<String, String> relMap,
    Archive archive,
  ) {
    final result = <_ChartBlock>[];
    for (final drawing in pElem.findAllElements('w:drawing')) {
      try {
        final chartEl = drawing.findAllElements('c:chart').firstOrNull;
        final rId = chartEl?.getAttribute('r:id');
        if (rId == null) continue;
        final target = relMap[rId];
        if (target == null) continue;
        final path =
            target.startsWith('/') ? target.substring(1) : 'word/$target';
        final xml =
            _readFile(archive, path) ?? _readFile(archive, 'word/$target');
        if (xml == null) continue;
        final chart = _parseChart(xml, drawing);
        if (chart != null) result.add(chart);
      } catch (_) {}
    }
    return result;
  }

  static _ChartBlock? _parseChart(String xml, XmlElement drawing) {
    try {
      final doc = XmlDocument.parse(xml);
      String type = 'bar';
      if (doc.findAllElements('c:pieChart').isNotEmpty ||
          doc.findAllElements('c:doughnutChart').isNotEmpty) {
        type = 'pie';
      } else if (doc.findAllElements('c:lineChart').isNotEmpty) {
        type = 'line';
      } else if (doc.findAllElements('c:barChart').isNotEmpty) {
        type = 'bar';
      }
      final ser = doc.findAllElements('c:ser').firstOrNull;
      if (ser == null) return null;
      final cats = <String>[];
      final catEl = ser.findAllElements('c:cat').firstOrNull;
      if (catEl != null) {
        for (final pt in catEl.findAllElements('c:pt')) {
          cats.add(pt.findElements('c:v').firstOrNull?.innerText ?? '');
        }
      }
      final vals = <double>[];
      final valEl = ser.findAllElements('c:val').firstOrNull;
      if (valEl != null) {
        for (final pt in valEl.findAllElements('c:pt')) {
          vals.add(double.tryParse(
                  pt.findElements('c:v').firstOrNull?.innerText ?? '') ??
              0);
        }
      }
      if (vals.isEmpty) return null;
      // ألوان الشرائح إن نُصّ عليها (c:dPt) — وإلا نستخدم لوحة افتراضية
      final colors = <String>[];
      for (final dpt in ser.findAllElements('c:dPt')) {
        final clr =
            dpt.findAllElements('a:srgbClr').firstOrNull?.getAttribute('val');
        colors.add(clr ?? '');
      }
      final extent = drawing.findAllElements('wp:extent').firstOrNull;
      double w =
          (int.tryParse(extent?.getAttribute('cx') ?? '') ?? 0) / 12700.0;
      double h =
          (int.tryParse(extent?.getAttribute('cy') ?? '') ?? 0) / 12700.0;
      if (w <= 0) w = 320;
      if (h <= 0) h = 200;
      String? title;
      final titleEl = doc.findAllElements('c:title').firstOrNull;
      if (titleEl != null) {
        title = titleEl.findAllElements('a:t').map((e) => e.innerText).join();
        if (title.trim().isEmpty) title = null;
      }
      return _ChartBlock(
        type: type,
        cats: cats,
        vals: vals,
        colors: colors,
        width: w,
        height: h,
        title: title,
      );
    } catch (_) {
      return null;
    }
  }

  static List<_ImageBlock> _extractImages(
    XmlElement pElem,
    Map<String, String> relMap,
    Archive archive,
  ) {
    final result = <_ImageBlock>[];
    // محاذاة الفقرة الحاوية للصورة (يسار/وسط/يمين)
    final jc = pElem
        .findElements('w:pPr')
        .firstOrNull
        ?.findElements('w:jc')
        .firstOrNull
        ?.getAttribute('w:val');
    final imgAlign = jc == 'center'
        ? _Align.center
        : (jc == 'right' || jc == 'end')
            ? _Align.end
            : (jc == 'left' || jc == 'start')
                ? _Align.start
                : _Align.center;
    // ⚠️ قيد بنيوي موثَّق (لا إصلاح كامل، بل توضيح صريح لحد قائم): كل
    // عنصر <w:drawing> في OOXML يحمل إما <wp:anchor> (عائم، بموضع مطلق
    // نسبي للصفحة/الهامش عبر wp:positionH/wp:positionV، يلتف النص حوله)
    // أو <wp:inline> (مُضمَّن في تدفّق النص، يؤثر على ارتفاع السطر كحرف
    // عادي). الكود التالي (كما كان قبل هذا التعليق أيضاً) لا يميّز بينهما
    // إطلاقاً — يستخرج wp:extent (متاحة كطفل لكلا النوعين) ويُعامل العنصر
    // دوماً كمُضمَّن، بصرف النظر عن نوعه الفعلي. هذا ليس سهواً عرضياً بل
    // قيداً حقيقياً في تصميم المحرك الحالي: دعم تموضع مطلق صحيح لعنصر
    // عائم يتطلب تمريره إلى PdfPageSpec.overlayBlocks (PdfAbsoluteOverlay)
    // — البنية الموجودة فعلاً في pdf_layout_model.dart لهذا الغرض تحديداً
    // (مُستخدَمة في محوّل XLSX→PDF لصور/رسوم عائمة فوق الشبكة) — لكن هذا
    // المحوّل (DOCX→PDF) لا يستخدمها مطلقاً حالياً (صفر استخدام في كل
    // الملف). والأهم: حتى لو استُخدمت، يبقى تحدٍ أعمق غير محلول: تقسيم
    // الصفحات (pagination) يحدث فعلياً في Kotlin بعد قياس النص الحقيقي،
    // فـDart (هنا) لا يعرف مسبقاً "أي رقم صفحة" ستقع فيه فقرة معيّنة — أي
    // عنصر عائم مرتبط بفقرة قد تنتقل لصفحة مختلفة عن المتوقَّع بعد القياس
    // الفعلي، فربط Overlay بصفحة محدَّدة مسبقاً من Dart غير موثوق دون
    // إعادة هيكلة فعلية لتمرير العناصر العائمة كبيانات خام إلى Kotlin
    // وتركه يحجز موضعها بعد تحديد صفحتها الحقيقية أثناء التصفيح نفسه — لا
    // إصلاح متاح بأمان ضمن البنية الحالية بدون تلك الإعادة الأعمق.
    //
    // لذا — وبدل الاستمرار في معاملة هذا الفرق بصمت كما كان — نكتشف هنا
    // فعلياً نوع كل w:drawing (anchor أم inline)، ونسجّل تحذيراً تشخيصياً
    // واحداً فقط عند وجود عنصر عائم حقيقي، فيظهر هذا بوضوح في سجلات
    // التشخيص (debugPrint) بدل أن يبقى افتراضاً صامتاً قد يُفسَّر خطأً
    // كأن الاستخراج "يعمل بصورة كاملة" لكل أنواع المحتوى.
    bool loggedFloatingImageWarning = false;
    for (final drawing in pElem.findAllElements('w:drawing')) {
      try {
        final isFloating = _isFloatingDrawing(drawing);
        if (isFloating && !loggedFloatingImageWarning) {
          loggedFloatingImageWarning = true;
          debugPrint(
              '⚠️ صورة عائمة (wp:anchor) مكتشَفة — ستُعامَل كمُضمَّنة '
              '(inline) في موضعها الحالي ضمن تدفّق الفقرة، لا بموضعها '
              'المطلق الأصلي (wp:positionH/wp:positionV) لقيد بنيوي حالي '
              'في محرك DOCX→PDF (انظر تعليق _extractImages أعلاه لتفصيل '
              'كامل السبب).');
        }
        final blip = drawing.findAllElements('a:blip').firstOrNull;
        final rId = blip?.getAttribute('r:embed');
        if (rId == null) continue;
        final target = relMap[rId];
        if (target == null) continue;

        final path =
            target.startsWith('/') ? target.substring(1) : 'word/$target';
        final file = archive.findFile(path) ?? archive.findFile('word/$target');
        if (file == null) continue;
        Uint8List bytes = Uint8List.fromList(file.content as List<int>);

        // android.graphics.BitmapFactory (الجسر الأصلي) يدعم PNG/JPEG/WebP
        // بثبات؛ الصيغ الأخرى (GIF/BMP/TIFF/الإطار الأول من GIF المتحرّك…)
        // تُفك وتُعاد ترميزاً إلى PNG بدل حذفها بصمت.
        bytes = _ensureRasterPngOrJpeg(bytes) ?? bytes;
        final isPng = bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50;
        final isJpeg = bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8;
        if (!isPng && !isJpeg) continue;

        // الأبعاد بوحدة EMU (12700 EMU = نقطة واحدة)
        final extent = drawing.findAllElements('wp:extent').firstOrNull;
        double w =
            (int.tryParse(extent?.getAttribute('cx') ?? '') ?? 0) / 12700.0;
        double h =
            (int.tryParse(extent?.getAttribute('cy') ?? '') ?? 0) / 12700.0;
        if (w <= 0 || h <= 0) {
          w = _contentW;
          h = _contentW * 0.6;
        }

        // تصغير للحجم المتاح مع الحفاظ على النسبة
        const maxH = _pageH - _marginTop - _marginBottom - 16;
        final scale = math.min(1.0, math.min(_contentW / w, maxH / h));
        result.add(_ImageBlock(
            bytes: bytes,
            width: w * scale,
            height: h * scale,
            align: imgAlign));
      } catch (_) {
        // صورة تالفة أو غير مدعومة — نتجاوزها بدل إفشال التحويل
      }
    }
    return result;
  }

  // ─── تحليل ألوان السمة (theme1.xml) ─────────────────────────────────────
  static Map<String, String> _parseTheme(String? xml) {
    final map = <String, String>{};
    if (xml == null) return map;
    try {
      final doc = XmlDocument.parse(xml);
      final scheme = doc.findAllElements('a:clrScheme').firstOrNull;
      if (scheme == null) return map;
      for (final el in scheme.children.whereType<XmlElement>()) {
        final name = el.localName; // dk1, lt1, accent1..6, hlink...
        final srgb =
            el.findElements('a:srgbClr').firstOrNull?.getAttribute('val');
        final sys =
            el.findElements('a:sysClr').firstOrNull?.getAttribute('lastClr');
        final hex = srgb ?? sys;
        if (hex != null) map[name] = hex;
      }
      // أسماء بديلة شائعة
      map['tx1'] ??= map['dk1'] ?? '000000';
      map['bg1'] ??= map['lt1'] ?? 'FFFFFF';
      map['tx2'] ??= map['dk2'] ?? '000000';
      map['bg2'] ??= map['lt2'] ?? 'FFFFFF';
    } catch (_) {}
    return map;
  }

  // حل لون من عنصر تعبئة/خط (srgbClr أو schemeClr مع تعديلات الإضاءة)
  static String? _resolveFillColor(
      XmlElement? clrParent, Map<String, String> theme) {
    if (clrParent == null) return null;
    final srgb = clrParent.findElements('a:srgbClr').firstOrNull;
    if (srgb != null) return srgb.getAttribute('val');
    final sc = clrParent.findElements('a:schemeClr').firstOrNull;
    if (sc != null) {
      final base = theme[sc.getAttribute('val') ?? ''] ?? '';
      if (base.length < 6) return null;
      // تطبيق تعديلات HSL: lumMod/lumOff (إضاءة) + hueMod/hueOff (تدرّج)
      // + satMod/satOff (تشبّع). SmartArt يصنع دورة الألوان عبر hueOff
      // المتزايد على لون أساس واحد (accent4)، لذا تجاهل hueOff كان يجعل كل
      // العقد بلون واحد (أصفر). نقرؤها كلها لإعادة إنتاج التدرّج الأصلي.
      int? gi(String n) => int.tryParse(
          sc.findElements('a:$n').firstOrNull?.getAttribute('val') ?? '');
      final lumMod = gi('lumMod');
      final lumOff = gi('lumOff');
      final hueMod = gi('hueMod');
      final hueOff = gi('hueOff');
      final satMod = gi('satMod');
      final satOff = gi('satOff');
      if (lumMod == null &&
          lumOff == null &&
          hueMod == null &&
          hueOff == null &&
          satMod == null &&
          satOff == null) {
        return base;
      }
      return _applyHsl(base, lumMod, lumOff, hueMod, hueOff, satMod, satOff);
    }
    return null;
  }

  // تعديل اللون في فضاء HSL ثم العودة إلى RGB.
  // قيم Word: lum/sat بـ Mod نسبة مئوية ×1000 (100000=100%)، وOff إزاحة
  // ×1000. أما hue فبوحدة 1/60000 من الدرجة (hueOff/Mod). نطبّق Mod ثم Off.
  static String _applyHsl(String hex, int? lumMod, int? lumOff, int? hueMod,
      int? hueOff, int? satMod, int? satOff) {
    try {
      final r = int.parse(hex.substring(0, 2), radix: 16) / 255.0;
      final g = int.parse(hex.substring(2, 4), radix: 16) / 255.0;
      final b = int.parse(hex.substring(4, 6), radix: 16) / 255.0;
      final mx = math.max(r, math.max(g, b));
      final mn = math.min(r, math.min(g, b));
      double h = 0, s = 0;
      final l0 = (mx + mn) / 2;
      final d = mx - mn;
      if (d != 0) {
        s = l0 > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
        if (mx == r) {
          h = ((g - b) / d + (g < b ? 6 : 0));
        } else if (mx == g) {
          h = (b - r) / d + 2;
        } else {
          h = (r - g) / d + 4;
        }
        h /= 6; // h الآن في [0,1)
      }
      // ── الصبغة (Hue) ──
      double hueDeg = h * 360.0;
      if (hueMod != null) hueDeg *= hueMod / 100000.0;
      if (hueOff != null) hueDeg += hueOff / 60000.0; // 1/60000 درجة للوحدة
      hueDeg %= 360.0;
      if (hueDeg < 0) hueDeg += 360.0;
      h = hueDeg / 360.0;
      // ── التشبّع (Saturation) ──
      if (satMod != null) s *= satMod / 100000.0;
      if (satOff != null) s += satOff / 100000.0;
      s = s.clamp(0.0, 1.0);
      // ── الإضاءة (Lightness) ──
      double l = l0;
      if (lumMod != null) l *= lumMod / 100000.0;
      if (lumOff != null) l += lumOff / 100000.0;
      l = l.clamp(0.0, 1.0);

      double hue2(double p, double q, double t) {
        if (t < 0) t += 1;
        if (t > 1) t -= 1;
        if (t < 1 / 6) return p + (q - p) * 6 * t;
        if (t < 1 / 2) return q;
        if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
        return p;
      }

      double rr, gg, bb;
      if (s == 0) {
        rr = gg = bb = l;
      } else {
        final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
        final p = 2 * l - q;
        rr = hue2(p, q, h + 1 / 3);
        gg = hue2(p, q, h);
        bb = hue2(p, q, h - 1 / 3);
      }
      String hh(double v) =>
          (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
      return '${hh(rr)}${hh(gg)}${hh(bb)}';
    } catch (_) {
      return hex;
    }
  }

  // ─── استخراج المخططات (SmartArt) من فقرة ────────────────────────────────
  /// ⚠️ إضافة جديدة (فهرس المحتويات الحقيقي) — انظر تعليق tocHeadings
  /// عند نقطة بنائه الكامل (بداية _convertSync أو ما يعادلها) لتفصيل
  /// كامل المشكلة. تمريرة عبور خفيفة على *كل* فقرات body (بصرف النظر
  /// عن العمق التداخلي — findAllElements تنزل لأي مستوى، بما فيه داخل
  /// خلايا الجداول، مطابقاً تماماً لسلوك حقل TOC الحقيقي في Word الذي
  /// يفهرس أي عنوان في المستند بصرف النظر عن موضعه البنيوي)، تستخرج
  /// *فقط* النص الظاهري المباشر + مستوى العنوان + bookmarkName لكل
  /// فقرة بنمط Heading1/2/3 (يطابق \o "1-3" في instrText الأصلي —
  /// عناوين أعمق كـHeading4 تُتجاهَل عمداً، تماماً كما يفعل Word نفسه
  /// مع نفس مدى الحقل). لا تبني _Paragraph كاملة (تنسيق/تشغيلات/إلخ —
  /// غير مطلوب لنص الفهرس، الذي يُعاد تنسيقه بنمط فهرس موحَّد لاحقاً
  /// في _synthesizeTableOfContents بصرف النظر عن تنسيق العنوان الأصلي،
  /// مطابقاً تماماً لسلوك TOC الحقيقي في Word) — أخف وأسرع، ويتجنّب أي
  /// تكرار لمنطق _parseParagraph المعقَّد لغرض لا يحتاج كل تفاصيله.
  /// ⚠️ إصلاح حقيقي (bookmark صناعي لعناوين بلا w:bookmarkStart يدوية،
  /// + إصلاح أمان لاحق) — تُعيد الآن أيضاً [autoBookmarkOf]: خريطة من
  /// *موضع ترتيبي* (pIndex، عدّاد صحيح بسيط — لا هوية XmlElement، انظر
  /// تعليقها الكامل عند نقطة استدعاء هذه الدالة لسبب التراجع عن
  // ignore: unintended_html_in_doc_comment
  /// المحاولة الأولى المعتمِدة على Map<XmlElement,...>) إلى اسم
  /// bookmark صناعي مُولَّد لعنوان بلا bookmarkStart يدوية في ذلك
  /// الموضع. _parseParagraph (الحلقة الرئيسية اللاحقة) تستقبل اسماً
  /// جاهزاً واحداً (لا الخريطة كاملة) بعد بحثها بنفس pIndex محسوباً
  /// بشرط مطابق تماماً هناك.
  static (List<_TocEntry>, Map<int, String>) _collectHeadingsForToc(
      XmlElement body) {
    final result = <_TocEntry>[];
    final autoBookmarkOf = <int, String>{};
    // ⚠️ إصلاح حقيقي حاسم (فارق فهرسة كان سيُسبب اختلاطاً تاماً بعد أول
    // جدول في المستند): العبور هنا *كان* عبر body.findAllElements('w:p')
    // (بعمق كامل، ينزل داخل أي w:tbl/w:sdt متداخل) — هذا تحديداً يُسبب
    // pIndex أكبر بكثير من mainLoopPIndex (المُزاد فقط لفقرات w:p
    // المباشرة تحت body في الحلقة الرئيسية؛ فقرات الجداول تُعالَج
    // بمعزل كامل عبر case 'tbl': → _parseTable ولا تُحسَب إطلاقاً في
    // mainLoopPIndex) بعد أول جدول يحوي أي w:p بداخله — تأكَّد هذا
    // فعلياً بالقياس على ملف الاختبار: 502 w:p بعمق كامل مقابل 438
    // مباشرة تحت body (فارق 64، فقرات داخل الجداول). العبور الصحيح هنا
    // إذن يجب أن يكون *بالضبط* body.children.whereType<XmlElement>()
    // (لا findAllElements) مع فحص localName=='p' يدوياً — نفس مصدر
    // العبور بالضبط المُستخدَم في الحلقة الرئيسية، فيُحسَب pIndex بنفس
    // الشرط تماماً ويتطابق ضمانياً (لا تخميناً) مع mainLoopPIndex. هذا
    // يعني عناوين متداخلة داخل جدول/sdtContent (لا توجد في هذا الملف،
    // تحقَّقت فعلياً) لن تُكتشَف هنا إطلاقاً — قيد موثَّق صريح، أفضل من
    // فهرسة خاطئة صامتة تُسند bookmark صناعياً لفقرة مختلفة تماماً عن
    // العنوان المقصود.
    var pIndex = -1;
    for (final p in body.children.whereType<XmlElement>()) {
      if (p.localName != 'p') continue;
      pIndex++;
      final pPr = p.findElements('w:pPr').firstOrNull;
      final styleId =
          pPr?.findElements('w:pStyle').firstOrNull?.getAttribute('w:val');
      if (styleId == null) continue;
      // ⚠️ نفس استنتاج isHeading/headingLevel المُستخدَم في _parseParagraph
      // (انظر هناك) لكن من styleId مباشرة لا styleMap (غير متاحة هنا
      // بنفس السهولة دون تمريرها كمعامل إضافي؛ نطابق نمط "heading N"
      // الشائع في معرّفات الأنماط نفسها، وهو غالباً مطابق لاسم النمط
      // المعروض فعلياً في Word لأنماط العناوين القياسية — أي عنوان
      // بنمط مخصص بمعرّف مختلف كلياً [نادر لعناوين فعلية] لن يُفهرَس،
      // تراجع آمن لا يكسر شيئاً، فقط يُسقط ذلك العنوان من TOC المُولَّد
      // دون أي أثر آخر).
      final hMatch =
          RegExp(r'heading(\d)', caseSensitive: false).firstMatch(styleId);
      if (hMatch == null) continue;
      final level = int.tryParse(hMatch.group(1) ?? '1') ?? 1;
      if (level < 1 || level > 3) continue; // يطابق \o "1-3" فقط

      final explicitBookmark = p
          .findElements('w:bookmarkStart')
          .map((e) => e.getAttribute('w:name'))
          .firstWhere((n) => n != null && n != '_GoBack', orElse: () => null);

      final buf = StringBuffer();
      for (final t in p.findAllElements('w:t')) {
        buf.write(t.innerText);
      }
      final text = buf.toString().trim();
      if (text.isEmpty) continue;

      // ⚠️ إصلاح حقيقي (إدخالات فهرس بلا رقم صفحة ظاهر): قبل هذا الإصلاح،
      // أي عنوان لا يحمل w:bookmarkStart *يدوية* صريحة في DOCX (شائع
      // جداً فعلياً — Word لا يتطلب bookmark يدوية مسبقة لبناء TOC
      // إطلاقاً؛ هو يُنشئ Bookmarks ضمنية تلقائياً داخلياً لكل عنوان
      // أثناء حساب الحقل، بصرف النظر عن أي bookmarkStart موجودة مسبقاً
      // في XML لأغراض أخرى كالروابط الداخلية اليدوية) كان يظهر في
      // الفهرس المُولَّد هنا بلا أي رقم صفحة ظاهر (فراغ تام، لا حتى
      // "0") — لأن _synthesizeTableOfContents لا تكتب رمز TOC المُركَّب
      // إطلاقاً حين bookmarkName==null (انظرها). هذا انحراف حقيقي عن
      // سلوك Word الذي سيُظهر رقم صفحة صحيحاً لكل عنوان بصرف النظر عن
      // وجود bookmark يدوية. الإصلاح: نولِّد اسم bookmark صناعياً
      // فريداً (مطابقاً تماماً لآلية Word الداخلية: لكل عنوان نسخة
      // مرجعية صالحة لـTOC حتى بلا تدخل يدوي) لأي عنوان لا يحمل
      // bookmarkStart يدوية — لا حذف العنوان من الفهرس (سيكون انحرافاً
      // عن الدقة، فهرس Word الحقيقي سيُظهره أيضاً)، بل توفير وجهة
      // صالحة له تماماً كما يفعل Word. الاسم الصناعي مُولَّد من فهرس
      // ترتيبي بسيط (لا يتعارض أبداً مع أي اسم bookmark يدوي حقيقي،
      // فالأخيرة دلالية كـ"sec_texts" لا رقمية صرفة كهذا النمط) ويُضاف
      // أيضاً كـbookmarkName حقيقي على الفقرة نفسها (انظر مستهلكها في
      // mapParagraph لاحقاً) لتُصبح هذه الفقرة بالذات وجهة رابط صالحة
      // فعلياً عبر resolveBookmarkPages، مطابقاً تماماً لمسار العناوين
      // ذات bookmark يدوي. autoBookmarkOf[pIndex] يُسجَّل *فقط* حين لا
      // توجد bookmark يدوية (إن وُجدت، _parseParagraph تستخرجها مباشرة
      // من p نفسها بالطريقة القديمة، فلا حاجة لإخبارها بشيء إضافي هنا).
      final bookmarkName = explicitBookmark ?? '_autoToc$pIndex';
      if (explicitBookmark == null) autoBookmarkOf[pIndex] = bookmarkName;

      result.add(_TocEntry(text, level, bookmarkName, hasArabic(text)));
    }
    return (result, autoBookmarkOf);
  }

  /// ⚠️ إضافة جديدة (فهرس المحتويات الحقيقي) — انظر تعليق tocHeadings/
  /// _collectHeadingsForToc لتفصيل كامل المشكلة. تبني فقرة واحدة لكل
  /// إدخال فهرس: نص العنوان (محاذٍ لبداية السطر) + فراغ بسيط + رمز PUA
  /// مُركَّب جديد يحمل اسم bookmark الهدف مباشرة بداخله (راجع التعليق
  /// أدناه لتفصيل الترميز)، يُستبدَل لاحقاً في NativePdfRenderer.kt
  /// برقم الصفحة الفعلي لذلك bookmark (بنفس آلية resolveBookmarkPages
  /// المبنية مسبقاً لـNUMPAGES). النص بالكامل (عنوان + رقم) رابط داخلي
  /// واحد قابل للنقر (linkAnchor) يشير لنفس bookmark، فالنقر في أي مكان
  /// على سطر الفهرس يقفز لذلك القسم — مطابق تماماً لسلوك TOC الحقيقي
  /// في Word. مستوى العنوان (1/2/3) يُترجَم لإزاحة يسارية تصاعدية بسيطة
  /// (12pt لكل مستوى) لتمييز التسلسل الهرمي بصرياً، تماماً كمسافات
  /// الإزاحة الافتراضية لمستويات TOC في Word.
  ///
  /// ⚠️ قيد بنيوي موثَّق (لا dot-leader، لا محاذاة يمين دقيقة لرقم
  /// الصفحة): التخطيط الكلاسيكي لفهرس Word (نص يسار ········ رقم يمين،
  /// بخط نقطي رابط بينهما عبر tab stop بمحاذاة right) يتطلب دعم
  /// android.text.style.TabStopSpan لمحاذاة غير يسارية — وهي تدعم فقط
  /// محاذاة يسار بطبيعتها في إطار عمل Android نفسه (قيد حقيقي خارج
  /// تحكُّم هذا الكود، انظر تعليق tabStopsPt في PdfSpecModels.kt
  /// وnقطة استدعائها في mapAlign/mapParagraph). البديل المُطبَّق هنا
  /// (نص ثم فراغ ثابت ثم رقم) وظيفي بالكامل (رابط قابل للنقر + رقم
  /// صحيح) لكنه أبسط بصرياً من تخطيط Word الدقيق — توضيح صريح بدل
  /// محاولة تقريب مُضلِّل قد يبدو "شبه صحيح" لكنه ليس كذلك فعلياً.
  static List<_ParagraphBlock> _synthesizeTableOfContents(
      List<_TocEntry> headings) {
    final result = <_ParagraphBlock>[];
    for (final h in headings) {
      final indent = (h.level - 1) * 12.0;
      // ⚠️ ترميز رمز "رقم صفحة bookmark مُركَّب": \uE002 + اسم البوكماركة
      // الحرفي + \uE003 (رمز إغلاق). يُستخرَج ويُستبدَل بالكامل (الرمزان
      // والاسم بينهما) برقم الصفحة الفعلي في resolvePageMarkersInBlock
      // (NativePdfRenderer.kt) — انظر تعليقها المُحدَّث هناك لتفصيل
      // الاستبدال الفعلي. لا تعارض مع \uE000/\uE001 (PAGE/NUMPAGES
      // العاديين): نطاق Unicode الخاص (PUA) يحتوي آلاف النقاط المتاحة،
      // فاختيار \uE002/\uE003 هنا تعسفي بقدر اختيار \uE000/\uE001 سابقاً
      // — فقط يجب أن يتطابق الترميز حرفياً بين هذا الموضع (Dart) ومنطق
      // الاستبدال المقابل (Kotlin).
      final pageRefPlaceholder =
          h.bookmarkName != null ? '\uE002${h.bookmarkName}\uE003' : '';
      result.add(_ParagraphBlock(_Paragraph(
        runs: [
          _Run(
            text: '${h.text}    $pageRefPlaceholder',
            fontSize: 11,
            rtl: h.rtl,
            linkAnchor: h.bookmarkName,
          ),
        ],
        align: h.rtl ? _Align.right : _Align.left,
        rtl: h.rtl,
        spaceBefore: 2,
        spaceAfter: 2,
        leftIndent: h.rtl ? null : indent,
        rightIndent: h.rtl ? indent : null,
      )));
    }
    return result;
  }

  static List<_DiagramBlock> _extractDiagrams(
    XmlElement pElem,
    Map<String, String> relMap,
    Map<String, String> theme,
    Archive archive,
  ) {
    final result = <_DiagramBlock>[];
    for (final relIds in pElem.findAllElements('dgm:relIds')) {
      try {
        final dm = relIds.getAttribute('r:dm');
        if (dm == null) continue;
        final dataPath = _relPath(relMap[dm]);
        if (dataPath == null) continue;
        final dataXml = _readFile(archive, dataPath);
        if (dataXml == null) continue;

        // data.xml -> dataModelExt relId -> drawing.xml
        final dataDom = XmlDocument.parse(dataXml);
        final ext = dataDom.findAllElements('dsp:dataModelExt').firstOrNull;
        final drawRel = ext?.getAttribute('relId');
        if (drawRel == null) continue;
        final drawPath = _relPath(relMap[drawRel]);
        if (drawPath == null) continue;
        final drawXml = _readFile(archive, drawPath);
        if (drawXml == null) continue;

        final diagram = _parseDiagramDrawing(drawXml, theme);
        if (diagram != null) {
          result.add(_recolorDiagramNodes(diagram, theme));
        }
      } catch (_) {
        // مخطط غير مدعوم — نتجاوزه
      }
    }
    return result;
  }

  // SmartArt يلوّن العقد بتدوير ألوان السمة (accent1..6) عبر colors*.xml،
  // لكن drawing*.xml المخزّن مؤقتاً قد يحمل لوناً واحداً (مثل accent4) لكل
  // العقد فتظهر كلها بلون واحد. إذا تطابق لون تعبئة ثلاث عقد نصّية أو أكثر،
  // نوزّع ألوان السمة عليها بالترتيب لتقارب المظهر الملوّن الأصلي في Word.
  static _DiagramBlock _recolorDiagramNodes(
      _DiagramBlock diagram, Map<String, String> theme) {
    final accents = <String>[
      for (final k in [
        'accent1',
        'accent2',
        'accent3',
        'accent4',
        'accent5',
        'accent6'
      ])
        if (theme[k] != null) theme[k]!,
    ];
    if (accents.length < 2) return diagram;

    // العقد المرشّحة: أي أشكال تحمل نصاً (صناديق العناوين). لا نشترط وجود
    // تعبئة مُحلّلة مسبقاً، لأن بعض ملفات SmartArt تترك التعبئة بصيغة لا
    // تُحلّ فتصل null؛ في هذه الحالة نريد مع ذلك إعطاءها لوناً مرئياً.
    final nodeIdx = <int>[];
    for (int i = 0; i < diagram.shapes.length; i++) {
      if (diagram.shapes[i].texts.isNotEmpty) nodeIdx.add(i);
    }
    if (nodeIdx.length < 2) return diagram;

    // نعيد التلوين عندما تكون كل العقد بلون واحد (الحالة المعطوبة في Word
    // حيث تظهر كلها بلون موحّد) أو عندما تكون كلها بلا لون مُحلّل (فتظهر
    // بلا مربعات أصلاً). أما إن كانت ألواناً متمايزة فعلاً فنتركها كما هي.
    final fills =
        nodeIdx.map((i) => diagram.shapes[i].fillHex?.toUpperCase()).toList();
    final firstFill = fills.first;
    final allSame = fills.every((f) => f == firstFill);
    if (!allSame) return diagram;

    final newShapes = <_DiagShape>[];
    int n = 0;
    for (int i = 0; i < diagram.shapes.length; i++) {
      final s = diagram.shapes[i];
      if (nodeIdx.contains(i)) {
        final c = accents[n % accents.length];
        n++;
        newShapes.add(_DiagShape(
          x: s.x,
          y: s.y,
          w: s.w,
          h: s.h,
          fillHex: c,
          lineHex: s.lineHex,
          lineW: s.lineW,
          rounded: s.rounded,
          texts: s.texts,
          tIns: s.tIns,
          bIns: s.bIns,
          lIns: s.lIns,
          rIns: s.rIns,
          vAnchor: s.vAnchor,
        ));
      } else {
        newShapes.add(s);
      }
    }
    return _DiagramBlock(
        shapes: newShapes, emuW: diagram.emuW, emuH: diagram.emuH);
  }

  /// ⚠️ إضافة جديدة (انظر تعليق القيد البنيوي في _extractImages لتفصيل
  /// كامل السبب): هل عنصر w:drawing هذا عائم (wp:anchor، بموضع مطلق
  /// يلتف النص حوله) أم مُضمَّن (wp:inline، يتبع تدفّق النص)؟ دالة مساعدة
  /// مشتركة يستخدمها _extractImages وَ_extractShapes معاً بدل تكرار نفس
  /// فحص findElements('wp:anchor') في كل واحدة منهما على حدة.
  static bool _isFloatingDrawing(XmlElement drawing) =>
      drawing.findElements('wp:anchor').firstOrNull != null;

  static String? _relPath(String? target) {
    if (target == null) return null;
    return target.startsWith('/') ? target.substring(1) : 'word/$target';
  }

  // ─── تحليل رسم المخطط (drawingN.xml) إلى أشكال ──────────────────────────
  static _DiagramBlock? _parseDiagramDrawing(
      String xml, Map<String, String> theme) {
    final shapes = <_DiagShape>[];
    double maxX = 0, maxY = 0;
    try {
      final dom = XmlDocument.parse(xml);
      for (final sp in dom.findAllElements('dsp:sp')) {
        final xfrm = sp.findAllElements('a:xfrm').firstOrNull;
        final off = xfrm?.findElements('a:off').firstOrNull;
        final extE = xfrm?.findElements('a:ext').firstOrNull;
        if (off == null || extE == null) continue;
        final x = double.tryParse(off.getAttribute('x') ?? '') ?? 0;
        final y = double.tryParse(off.getAttribute('y') ?? '') ?? 0;
        final w = double.tryParse(extE.getAttribute('cx') ?? '') ?? 0;
        final h = double.tryParse(extE.getAttribute('cy') ?? '') ?? 0;
        if (w <= 0 || h <= 0) continue;

        final spPr = sp.findElements('dsp:spPr').firstOrNull;
        final rounded = (spPr
                    ?.findElements('a:prstGeom')
                    .firstOrNull
                    ?.getAttribute('prst') ??
                '')
            .toLowerCase()
            .contains('round');

        final fillHex = _resolveFillColor(
            spPr?.findElements('a:solidFill').firstOrNull, theme);
        final lnEl = spPr?.findElements('a:ln').firstOrNull;
        final lineHex = _resolveFillColor(
            lnEl?.findElements('a:solidFill').firstOrNull, theme);
        final lineWemu = int.tryParse(lnEl?.getAttribute('w') ?? '') ?? 12700;

        // نص الشكل
        final texts = <_DiagText>[];
        final txBody = sp.findElements('dsp:txBody').firstOrNull;
        // bodyPr: الحشوات (EMU) والمحاذاة العمودية
        double tIns = 0, bIns = 0, lIns = 0, rIns = 0;
        _VAnchor vAnchor = _VAnchor.middle;
        final bodyPr = txBody?.findElements('a:bodyPr').firstOrNull;
        if (bodyPr != null) {
          tIns =
              (int.tryParse(bodyPr.getAttribute('tIns') ?? '') ?? 0) / 12700.0;
          bIns =
              (int.tryParse(bodyPr.getAttribute('bIns') ?? '') ?? 0) / 12700.0;
          lIns =
              (int.tryParse(bodyPr.getAttribute('lIns') ?? '') ?? 0) / 12700.0;
          rIns =
              (int.tryParse(bodyPr.getAttribute('rIns') ?? '') ?? 0) / 12700.0;
          switch (bodyPr.getAttribute('anchor')) {
            case 't':
              vAnchor = _VAnchor.top;
            case 'b':
              vAnchor = _VAnchor.bottom;
            default:
              vAnchor = _VAnchor.middle;
          }
        }
        if (txBody != null) {
          for (final p in txBody.findElements('a:p')) {
            final buf = StringBuffer();
            String? colorHex;
            bool bold = false;
            double size = 12;
            for (final r in p.findElements('a:r')) {
              buf.write(r.findElements('a:t').firstOrNull?.innerText ?? '');
              final rPr = r.findElements('a:rPr').firstOrNull;
              if (rPr != null) {
                final sz = int.tryParse(rPr.getAttribute('sz') ?? '');
                if (sz != null) size = sz / 100.0;
                if (rPr.getAttribute('b') == '1') bold = true;
                colorHex ??= _resolveFillColor(
                    rPr.findElements('a:solidFill').firstOrNull, theme);
              }
            }
            final t = buf.toString().trim();
            if (t.isEmpty) continue;
            final algn =
                p.findElements('a:pPr').firstOrNull?.getAttribute('algn');
            _Align al;
            switch (algn) {
              case 'l':
                al = _Align.start;
              case 'r':
                al = _Align.end;
              default:
                al = _Align.center;
            }
            texts.add(_DiagText(
                text: t,
                size: size,
                colorHex: colorHex,
                bold: bold,
                align: al));
          }
        }

        shapes.add(_DiagShape(
          x: x,
          y: y,
          w: w,
          h: h,
          fillHex: fillHex,
          lineHex: lineHex,
          lineW: lineWemu / 12700.0,
          rounded: rounded,
          texts: texts,
          tIns: tIns,
          bIns: bIns,
          lIns: lIns,
          rIns: rIns,
          vAnchor: vAnchor,
        ));
        if (x + w > maxX) maxX = x + w;
        if (y + h > maxY) maxY = y + h;
      }
    } catch (_) {
      return null;
    }
    if (shapes.isEmpty) return null;
    return _DiagramBlock(shapes: shapes, emuW: maxX, emuH: maxY);
  }

  // ─── استخراج الأشكال ومربعات النص (Shapes & Text Boxes) ──────────────────
  // يدعم نمطين:
  //  (أ) DrawingML الحديث: <wps:wsp> داخل <w:drawing>/<mc:Choice>، مع
  //      <wps:spPr> (الهندسة/التعبئة a:solidFill/الحدّ a:ln) و
  //      <wps:txbx><w:txbxContent> للنص (فقرات w:p عربية/إنجليزية).
  //  (ب) VML القديم: <v:shape>/<v:rect>/<v:roundrect>/<v:oval> مع السمات
  //      style (الموضع/الأبعاد) وfillcolor/strokecolor و<v:textbox>.
  // ⚠️ إصلاح حقيقي (الأشكال تُحوَّل لجدول مزيَّف بدل أشكال هندسية حقيقية):
  // كل شكل يُحوَّل الآن إلى _ShapeGroupBlock مفرد (لا _DiagramBlock — ذاك
  // النوع محصور بمسار SmartArt القديم عبر mapDiagram)، فيُرسم لاحقاً في
  // _mapBlocksToDocSpec عبر mapShapeGroup بهندسة a:prstGeom/اسم وسم VML
  // الحقيقية (مستطيل/بيضاوي/مثلث/سهم/نجمة...) ضمن Block.GroupBlock حقيقي،
  // لا كصف جدول بخلية واحدة بحد مستطيل بسيط كما كان سابقاً.
  static List<_ShapeGroupBlock> _extractShapes(
      XmlElement pElem, Map<String, String> theme) {
    final result = <_ShapeGroupBlock>[];
    final seen = <XmlElement>{}; // تفادي ازدواج Choice/Fallback لنفس الشكل
    // ⚠️ انظر تعليق القيد البنيوي الكامل في _extractImages أعلاه — نفس
    // القيد ينطبق هنا بالضبط (لا تمييز فعلي بين wps:wsp/v:shape عائم
    // [داخل wp:anchor، موضعه مطلق نسبي للصفحة] أو مُضمَّن [wp:inline]؛
    // كلاهما يُعامَل هنا كمُضمَّن ضمن تدفّق الفقرة الحاوية). الأشكال أكثر
    // عرضة عملياً من الصور لاستخدام anchor (مربعات نص/أشكال زخرفية
    // توضَع غالباً بحرية فوق الصفحة في DOCX الحقيقي)، فالتنويه التشخيصي
    // هنا أكثر أهمية من نظيره في _extractImages.
    bool loggedFloatingShapeWarning = false;
    bool isFloatingAncestor(XmlElement el) {
      for (final a in el.ancestors.whereType<XmlElement>()) {
        if (a.localName == 'drawing') return _isFloatingDrawing(a);
      }
      return false;
    }

    // ── (أ) DrawingML الحديث: wps:wsp ───────────────────────────────────────
    // داخل mc:AlternateContent نفضّل mc:Choice (wps) ونتجاهل mc:Fallback (VML)
    // حتى لا يُرسم الشكل مرتين.
    for (final wsp in pElem.findAllElements('wps:wsp')) {
      // إن كان داخل mc:Fallback فتخطّه (سنأخذ نسخة wps من Choice).
      if (_insideFallback(wsp)) continue;
      if (isFloatingAncestor(wsp) && !loggedFloatingShapeWarning) {
        loggedFloatingShapeWarning = true;
        debugPrint(
            '⚠️ شكل/مربع نص عائم (wp:anchor) مكتشَف — سيُعامَل كمُضمَّن '
            '(inline) في موضعه الحالي ضمن تدفّق الفقرة، لا بموضعه المطلق '
            'الأصلي لقيد بنيوي حالي في محرك DOCX→PDF.');
      }
      final shape = _parseWpsShape(wsp, theme);
      if (shape != null) {
        result.add(_ShapeGroupBlock(shape));
      }
    }

    // ── (ب) VML القديم: v:shape / v:rect / v:roundrect / v:oval ──────────────
    for (final vtag in ['v:rect', 'v:roundrect', 'v:oval', 'v:shape']) {
      for (final vsh in pElem.findAllElements(vtag)) {
        if (seen.contains(vsh)) continue;
        seen.add(vsh);
        // إن وُجد نظير DrawingML (داخل mc:Choice) لنفس الشكل، فالـ VML غالباً
        // في Fallback — نتخطاه إن كان هناك wps:wsp إخوة في AlternateContent.
        if (_hasWpsSibling(vsh)) continue;
        if (isFloatingAncestor(vsh) && !loggedFloatingShapeWarning) {
          loggedFloatingShapeWarning = true;
          debugPrint(
              '⚠️ شكل/مربع نص عائم (wp:anchor) مكتشَف — سيُعامَل كمُضمَّن '
              '(inline) في موضعه الحالي ضمن تدفّق الفقرة، لا بموضعه المطلق '
              'الأصلي لقيد بنيوي حالي في محرك DOCX→PDF.');
        }
        final shape = _parseVmlShape(vsh, theme);
        if (shape != null) {
          result.add(_ShapeGroupBlock(shape));
        }
      }
    }
    return result;
  }

  // هل العنصر داخل mc:Fallback؟ (لتفضيل mc:Choice)
  static bool _insideFallback(XmlElement el) {
    for (final a in el.ancestors.whereType<XmlElement>()) {
      if (a.localName == 'Fallback') return true;
    }
    return false;
  }

  // هل لشكل VML نظير wps:wsp في نفس AlternateContent (أي أنه Fallback)؟
  static bool _hasWpsSibling(XmlElement vsh) {
    for (final a in vsh.ancestors.whereType<XmlElement>()) {
      if (a.localName == 'AlternateContent') {
        return a.findAllElements('wps:wsp').isNotEmpty;
      }
    }
    return false;
  }

  // تحليل شكل DrawingML واحد (wps:wsp)
  static _DiagShape? _parseWpsShape(XmlElement wsp, Map<String, String> theme) {
    try {
      final spPr = wsp.findElements('wps:spPr').firstOrNull;
      if (spPr == null) return null;
      final xfrm = spPr.findElements('a:xfrm').firstOrNull;
      final ext = xfrm?.findElements('a:ext').firstOrNull;
      // الأبعاد (EMU). الموضع غير مهم للرسم المضمّن (نرسمه في تدفق النص).
      double w = double.tryParse(ext?.getAttribute('cx') ?? '') ?? 0;
      double h = double.tryParse(ext?.getAttribute('cy') ?? '') ?? 0;
      if (w <= 0 || h <= 0) {
        // قد تكون الأبعاد في wp:extent بالـ drawing الأب
        final drawing = wsp.ancestors
            .whereType<XmlElement>()
            .firstWhere((e) => e.localName == 'drawing', orElse: () => wsp);
        final extent = drawing.findAllElements('wp:extent').firstOrNull;
        w = double.tryParse(extent?.getAttribute('cx') ?? '') ?? 914400;
        h = double.tryParse(extent?.getAttribute('cy') ?? '') ?? 457200;
      }

      final prst =
          spPr.findElements('a:prstGeom').firstOrNull?.getAttribute('prst') ??
              'rect';
      final rounded = prst.toLowerCase().contains('round') ||
          prst.toLowerCase().contains('ellipse');

      final fillHex = _resolveFillColor(
          spPr.findElements('a:solidFill').firstOrNull, theme);
      final lnEl = spPr.findElements('a:ln').firstOrNull;
      final lineHex = _resolveFillColor(
          lnEl?.findElements('a:solidFill').firstOrNull, theme);
      final lineWemu = int.tryParse(lnEl?.getAttribute('w') ?? '') ?? 12700;

      final txbx = wsp.findElements('wps:txbx').firstOrNull;
      final content = txbx?.findElements('w:txbxContent').firstOrNull;
      final bodyPr = wsp.findElements('wps:bodyPr').firstOrNull;
      final ins = _readBodyInsets(bodyPr);
      final texts = _readTxbxTexts(content);

      return _DiagShape(
        x: 0,
        y: 0,
        w: w,
        h: h,
        fillHex: fillHex,
        lineHex: lineHex,
        lineW: lineWemu / 12700.0,
        rounded: rounded,
        texts: texts,
        tIns: ins.t,
        bIns: ins.b,
        lIns: ins.l,
        rIns: ins.r,
        vAnchor: ins.anchor,
        // ⚠️ إضافة جديدة: انظر تعليق _DiagShape.prstGeom — يمرّر القيمة
        // الخام الحقيقية (مثل "ellipse"|"triangle"|"star5"|"rightArrow"...)
        // بدل ضياعها في تبسيط rounded:bool وحده.
        prstGeom: prst,
      );
    } catch (_) {
      return null;
    }
  }

  // تحليل شكل VML واحد (v:rect / v:roundrect / v:oval / v:shape)
  static _DiagShape? _parseVmlShape(XmlElement vsh, Map<String, String> theme) {
    try {
      // الأبعاد من سمة style: "width:120pt;height:60pt;..."
      final style = vsh.getAttribute('style') ?? '';
      double pt(String key) {
        final m = RegExp('$key:\\s*([0-9.]+)pt').firstMatch(style);
        return m != null ? (double.tryParse(m.group(1) ?? '') ?? 0.0) : 0.0;
      }

      double wPt = pt('width');
      double hPt = pt('height');
      // EMU = pt * 12700
      double w = wPt * 12700;
      double h = hPt * 12700;
      if (w <= 0) w = 914400;
      if (h <= 0) h = 457200;

      final tag = vsh.localName;
      final rounded = tag.contains('round') || tag.contains('oval');

      // الألوان من سمات VML: fillcolor / strokecolor (#RRGGBB أو اسم)
      final fillHex = _normalizeVmlColor(vsh.getAttribute('fillcolor'));
      // تعبئة شفافة؟ <v:fill on="f"/> أو filled="f"
      final filledAttr = vsh.getAttribute('filled');
      final vFill = vsh.findElements('v:fill').firstOrNull;
      final fillOn = !(filledAttr == 'f' ||
          filledAttr == 'false' ||
          vFill?.getAttribute('on') == 'f');
      final strokeHex = _normalizeVmlColor(vsh.getAttribute('strokecolor'));
      final strokedAttr = vsh.getAttribute('stroked');
      final strokeOn = !(strokedAttr == 'f' || strokedAttr == 'false');
      // سُمك الحدّ: strokeweight="1.5pt"
      final swStyle = vsh.getAttribute('strokeweight') ?? '';
      final swM = RegExp(r'([0-9.]+)pt').firstMatch(swStyle);
      final lineW =
          swM != null ? (double.tryParse(swM.group(1) ?? '') ?? 1.0) : 1.0;

      // النص داخل v:textbox > w:txbxContent
      final vtb = vsh.findElements('v:textbox').firstOrNull;
      final content = vtb?.findElements('w:txbxContent').firstOrNull;
      final texts = _readTxbxTexts(content);

      return _DiagShape(
        x: 0,
        y: 0,
        w: w,
        h: h,
        fillHex: fillOn ? (fillHex ?? 'FFFFFF') : null,
        lineHex: strokeOn ? (strokeHex ?? '000000') : null,
        lineW: lineW,
        rounded: rounded,
        texts: texts,
        tIns: 7.2, // حشوات VML الافتراضية (0.1")
        bIns: 7.2,
        lIns: 7.2,
        rIns: 7.2,
        vAnchor: _VAnchor.top,
        // ⚠️ إضافة جديدة: انظر تعليق _DiagShape.prstGeom. VML القديم لا
        // يحمل a:prstGeom (خاص بـDrawingML)، لكن اسم الوسم نفسه (v:rect/
        // v:roundrect/v:oval) يكفي لتحديد الهندسة الأساسية بدقة — v:shape
        // العام (autoshapes برقم معرّف، نادرة عملياً) يبقى prstGeom=null
        // فيتراجع لمستطيل بسيط كالسابق (لا تغيير سلوك لهذه الحالة النادرة).
        prstGeom: tag == 'v:oval'
            ? 'ellipse'
            : (tag == 'v:roundrect' ? 'roundRect' : null),
      );
    } catch (_) {
      return null;
    }
  }

  // يقرأ حشوات bodyPr (نقاط) والمحاذاة العمودية ⇒ _Insets
  static _Insets _readBodyInsets(XmlElement? bodyPr) {
    double t = 45720 / 12700.0, bo = 45720 / 12700.0;
    double l = 91440 / 12700.0, r = 91440 / 12700.0;
    _VAnchor v = _VAnchor.middle;
    if (bodyPr != null) {
      final tv = int.tryParse(bodyPr.getAttribute('tIns') ?? '');
      final bv = int.tryParse(bodyPr.getAttribute('bIns') ?? '');
      final lv = int.tryParse(bodyPr.getAttribute('lIns') ?? '');
      final rv = int.tryParse(bodyPr.getAttribute('rIns') ?? '');
      if (tv != null) t = tv / 12700.0;
      if (bv != null) bo = bv / 12700.0;
      if (lv != null) l = lv / 12700.0;
      if (rv != null) r = rv / 12700.0;
      switch (bodyPr.getAttribute('anchor')) {
        case 't':
          v = _VAnchor.top;
        case 'b':
          v = _VAnchor.bottom;
        default:
          v = _VAnchor.middle;
      }
    }
    return _Insets(t: t, b: bo, l: l, r: r, anchor: v);
  }

  // يقرأ نصوص w:txbxContent (فقرات w:p مع w:r/w:t) مع لون/عرض/محاذاة.
  // يدعم العربية والإنجليزية (يُمرَّر النص كما هو، والاتجاه يُحدَّد عند الرسم).
  static List<_DiagText> _readTxbxTexts(XmlElement? content) {
    final out = <_DiagText>[];
    if (content == null) return out;
    for (final p in content.findElements('w:p')) {
      final buf = StringBuffer();
      String? colorHex;
      bool bold = false;
      double size = 11;
      for (final run in p.findElements('w:r')) {
        for (final t in run.findElements('w:t')) {
          buf.write(t.innerText);
        }
        final rPr = run.findElements('w:rPr').firstOrNull;
        if (rPr != null) {
          if (rPr.findElements('w:b').isNotEmpty) bold = true;
          final sz =
              rPr.findElements('w:sz').firstOrNull?.getAttribute('w:val');
          final szi = int.tryParse(sz ?? '');
          if (szi != null) size = szi / 2.0; // half-points ⇒ points
          final col =
              rPr.findElements('w:color').firstOrNull?.getAttribute('w:val');
          if (col != null && col != 'auto' && col.length >= 6) {
            colorHex ??= col;
          }
        }
      }
      final txt = buf.toString().trim();
      if (txt.isEmpty) continue;
      final jc = p
          .findElements('w:pPr')
          .firstOrNull
          ?.findElements('w:jc')
          .firstOrNull
          ?.getAttribute('w:val');
      _Align al;
      switch (jc) {
        case 'center':
          al = _Align.center;
        case 'right':
          al = _Align.end;
        case 'left':
          al = _Align.start;
        default:
          al = hasArabic(txt) ? _Align.end : _Align.start;
      }
      out.add(_DiagText(
          text: txt, size: size, colorHex: colorHex, bold: bold, align: al));
    }
    return out;
  }
}
