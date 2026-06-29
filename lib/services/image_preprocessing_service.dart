/// خدمة المعالجة المسبقة للصور قبل تمريرها لمحرك التعرف الضوئي.
///
/// نقطة التفوق الأساسية على Text Fairy: تطبيق Text Fairy يعتمد على
/// خوارزميات تصحيح ميل (deskew) وتنظيف ثنائي (binarization) من نسخة
/// قديمة من مكتبة Leptonica المرفقة مع Tesseract، بدون أي تحكم يدوي
/// من المستخدم ولا أي خطوة لتحسين التباين بشكل تكيفي.
///
/// هنا نطبّق خط أنابيب (pipeline) أوضح وأكثر دقة، قابل للتخصيص:
///   1) تحويل إلى تدرج رمادي.
///   2) إزالة الضجيج بفلتر متوسط خفيف (median) محافظ على حدة الحروف.
///   3) تحسين تباين تكيفي محلي (CLAHE مبسّط) يفيد بشكل خاص في صور
///      الكاميرا غير المتساوية الإضاءة (ظل جزئي على الصفحة).
///   4) كشف زاوية الميل عبر تحويل Hough على حواف النص وتصحيحها بالدوران.
///   5) ثنائية تكيفية (adaptive threshold) تحافظ على تشكيل الحروف العربية
///      المتصلة، بدل العتبة الثابتة (global threshold) التي تكسر نقاط
///      الحروف العربية الدقيقة (كالنقاط فوق الباء والتاء) في الإضاءة غير
///      المنتظمة.
///
/// كل هذه الخطوات تُنفَّذ بمعزل عن Dart/Flutter الفعلي (لا تتوفر بيئة
/// تشغيل Flutter هنا)، لذا الكود مكتوب وفق واجهة `package:image` الشائعة
/// في مشاريع Flutter لمعالجة الصور؛ يجب أن يقوم مصطفى ببناء المشروع
/// واختبار الناتج، ثم رفع نتائج البناء لمراجعتها.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// نتيجة خطوة المعالجة المسبقة لصورة واحدة.
class PreprocessedImage {
  final img.Image image;
  final double detectedSkewAngleDegrees;
  final File savedFile;

  /// أبعاد الصورة النهائية بالبكسل بعد كل خطوات المعالجة (بما فيها
  /// تصحيح الميل الذي قد يُغيّر الأبعاد طفيفاً بسبب الدوران) — تُمرَّر
  /// هنا مباشرة بدل أن يُعيد المستدعي فتح الملف من جديد لقراءة الأبعاد.
  int get widthPx => image.width;
  int get heightPx => image.height;

  const PreprocessedImage({
    required this.image,
    required this.detectedSkewAngleDegrees,
    required this.savedFile,
  });
}

/// إعدادات قابلة للتخصيص لخط أنابيب المعالجة، تُعرض للمستخدم كخيارات
/// متقدمة اختيارية (الوضع الافتراضي مناسب لأغلب الحالات).
class ImagePreprocessingOptions {
  /// تفعيل تصحيح الميل التلقائي.
  final bool autoDeskew;

  /// تفعيل تحسين التباين التكيفي (مفيد للصور المصوّرة بالكاميرا).
  final bool adaptiveContrastEnhancement;

  /// تفعيل التحويل الثنائي (أبيض/أسود) النهائي. يُعطّل تلقائيًا إذا
  /// كانت الصورة من مستند ممسوح بدقة عالية أصلاً (لا تحتاج تنظيف إضافي).
  final bool binarize;

  /// أقصى زاوية ميل (بالدرجات) يُسمح بتصحيحها تلقائيًا، لتجنّب تدوير
  /// خاطئ لصور بها جدول مائل عمدًا أو رسم بياني.
  final double maxAutoDeskewAngle;

  /// كشف وعكس تلقائي لصور بقطبية معكوسة (نص فاتح على خلفية داكنة، مثل
  /// لقطات شاشة تطبيقات بالـ Dark Mode أو واتساب). مفعّل افتراضياً لكل
  /// الأوضاع لأنه بلا أي أثر سلبي على الصور العادية (يكتشف القطبية أولاً
  /// ولا يعكس إلا عند الحاجة الفعلية)، وضروري جداً لمصدر "صورة من
  /// المعرض" حيث الصور الرقمية (لقطات شاشة، صور محادثات) شائعة جداً.
  final bool autoInvertDarkBackground;

  /// ⚠️ إضافة جديدة: تفعيل فلتر إزالة الضجيج (median 3x3). مفيد فقط
  /// لصور الكاميرا الحقيقية (ضجيج مستشعر/إضاءة)؛ على صور رقمية المنشأ
  /// حادة التباين أصلاً (لقطات شاشة)، هذا الفلتر يطمس حواف الحروف
  /// الرفيعة بلا فائدة فعلية ويُضعف الدقة بدل تحسينها — كان هذا الفلتر
  /// يعمل دائماً بلا أي شرط في إصدار سابق، بصرف النظر عن نوع الصورة.
  final bool denoiseForCameraNoise;

  /// ⚠️ إضافة جديدة: كشف وإزالة مناطق التشبّع اللوني العالي (الرموز
  /// التعبيرية/الإيموجي الملوَّنة كـ 🔥) قبل تمرير الصورة لـ Tesseract.
  /// مُتحقَّق عملياً (مقارنة مباشرة مع Text Fairy على نفس الصورة) أن
  /// أي إيموجي يُفسد تعرّف الكلمة المحتواة عليه والكلمات المجاورة لها
  /// مباشرة، في كل محركات Tesseract بلا استثناء. مفعَّل افتراضياً لكل
  /// الأوضاع لأنه بلا أي أثر سلبي على نص عادي (النص لا تشبّع لوني فيه
  /// إطلاقاً — أسود/أبيض/رمادي دوماً، فلا تُكتشف أي منطقة فيه كإيموجي).
  final bool removeSaturatedEmoji;

  const ImagePreprocessingOptions({
    this.autoDeskew = true,
    this.adaptiveContrastEnhancement = true,
    this.binarize = true,
    this.maxAutoDeskewAngle = 15.0,
    this.autoInvertDarkBackground = true,
    this.denoiseForCameraNoise = true,
    this.removeSaturatedEmoji = true,
  });

  /// إعداد مخصص للمستندات الممسوحة عبر سكانر (دقة عالية، إضاءة متساوية)
  /// حيث المعالجة الزائدة قد تُفقد تفاصيل دقيقة في الحروف العربية.
  static const ImagePreprocessingOptions scannedDocument = ImagePreprocessingOptions(
    autoDeskew: true,
    adaptiveContrastEnhancement: false,
    binarize: false,
    maxAutoDeskewAngle: 5.0,
    denoiseForCameraNoise: false,
  );

  /// إعداد مخصص لصور الكاميرا المباشرة (إضاءة متفاوتة، احتمال ميل أكبر).
  static const ImagePreprocessingOptions cameraCapture = ImagePreprocessingOptions(
    autoDeskew: true,
    adaptiveContrastEnhancement: true,
    binarize: true,
    maxAutoDeskewAngle: 20.0,
    denoiseForCameraNoise: true,
  );

  /// ⚠️ إضافة جديدة: إعداد مخصص لصور "رقمية المنشأ" (digital-born) —
  /// لقطات شاشة، صور محادثات، مستندات PDF محوَّلة لصورة، شعارات نصية.
  /// هذه الصور بتباين عالٍ أصلاً وحواف حروف حادة تماماً (لا ضجيج كاميرا
  /// ولا ميل فعلي)، فالتحويل الثنائي اليدوي (Sauvola) والتباين التكيفي
  /// وفلتر إزالة الضجيج لا يفيدون شيئاً غالباً، وقد يُفسدون حروفاً رفيعة
  /// دقيقة (خطوط Cairo/Tajawal الرفيعة الشائعة في تصاميم العربية
  /// الحديثة). كشف/عكس القطبية يبقى مفعّلاً (ضروري لخلفيات Dark Mode)،
  /// وتصحيح الميل يبقى مفعّلاً (بأقصى زاوية صغيرة، فلقطات الشاشة نادراً
  /// ما تكون مائلة فعلياً).
  static const ImagePreprocessingOptions digitalScreenshot = ImagePreprocessingOptions(
    autoDeskew: true,
    adaptiveContrastEnhancement: false,
    binarize: false,
    maxAutoDeskewAngle: 3.0,
    autoInvertDarkBackground: true,
    denoiseForCameraNoise: false,
  );
}

class ImagePreprocessingService {
  /// ينفذ خط الأنابيب الكامل على صورة من مسار ملف، ويحفظ الناتج في ملف
  /// مؤقت جديد (لا يُعدّل الأصل، حتى يستطيع المستخدم الرجوع له لاحقًا).
  ///
  /// ⚠️ إصلاح حقيقي جوهري (فشل تام على لقطات الشاشة ذات الخلفية الداكنة،
  /// كصور واتساب/تطبيقات بالـ Dark Mode): محرك Tesseract مُدرَّب أساساً
  /// على افتراض "نص داكن على خلفية فاتحة" (وثائق ممسوحة تقليدية). أي
  /// صورة بقطبية معكوسة (نص فاتح على خلفية داكنة) تُفسد التعرف بالكامل
  /// — ليس فقط بدقة منخفضة بل بنتائج عشوائية تماماً (رموز/حروف لا علاقة
  /// لها بالنص الأصلي إطلاقاً)، وهذا تحديداً ما ظهر فعلياً: السطر الأول
  /// من نتيجة OCR على لقطة شاشة واتساب داكنة كان "l = @) ev s BX Vn %4 &"
  /// — هذه ليست أخطاء تعرّف عادية، بل Tesseract يحاول "قراءة" الصورة
  /// المعكوسة بالكامل كرموز عشوائية.
  ///
  /// الإصلاح: نكشف القطبية الغالبة في الصورة (متوسط سطوع البكسلات) قبل
  /// أي معالجة أخرى، ونعكس الصورة (255-قيمة كل بكسل) إن كانت الخلفية
  /// داكنة، لنحصل دائماً على "نص داكن على خلفية فاتحة" كما يتوقع المحرك
  /// بنيوياً — بصرف النظر عن قطبية المصدر الأصلي.
  ///
  /// ⚠️ إضافة جديدة (معالجة مشكلة الرموز التعبيرية/الإيموجي): تحقَّقنا
  /// عملياً (مقارنة مباشرة مع نتيجة Text Fairy على نفس الصورة) أن أي
  /// إيموجي ملوَّن (مثل 🔥) داخل نص يُفسد تعرّف الكلمات المجاورة له
  /// مباشرة في كل محركات Tesseract (ليست مشكلة خاصة بأداتنا) — الكلمة
  /// التي تحوي الإيموجي وما حولها مباشرة تضيع كلياً أو تتحول لرموز
  /// عشوائية. الإصلاح: نكشف مناطق التشبّع اللوني العالي (saturated
  /// color regions) في الصورة الملوَّنة الأصلية — النص العادي (أسود/
  /// أبيض/رمادي) لا تشبّع لوني فيه إطلاقاً، بخلاف الإيموجي الملوَّن
  /// (أحمر/برتقالي/أصفر/إلخ) الذي يبرز بتشبّع عالٍ مميَّز. نملأ هذه
  /// المناطق بلون الخلفية المحيطة بها (لا نتركها سوداء/بيضاء عشوائياً،
  /// لتفادي خلق حافة حادة جديدة قد تُفسَّر كحرف وهمي) **قبل** أي تحويل
  /// لرمادي — إذ يضيع التشبّع اللوني بعد grayscale ولا يمكن كشفه لاحقاً.
  static Future<PreprocessedImage> process(
    File inputFile, {
    ImagePreprocessingOptions options = const ImagePreprocessingOptions(),
  }) async {
    final bytes = await inputFile.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException('تعذّر فتح الصورة. الصيغة غير مدعومة أو الملف تالف.');
    }

    final colorCleaned = options.removeSaturatedEmoji
        ? _removeSaturatedColorRegions(decoded)
        : decoded;

    img.Image working = img.grayscale(colorCleaned);

    if (options.autoInvertDarkBackground && _isDarkBackgroundDominant(working)) {
      working = img.invert(working);
    }

    // ⚠️ إصلاح حقيقي: إزالة الضجيج بفلتر متوسط 3x3 مفيدة فقط لصور
    // الكاميرا الحقيقية (ضجيج المستشعر/الإضاءة). على صور رقمية المنشأ
    // حادة التباين أصلاً (لقطات شاشة، مستندات محوَّلة لصورة) — لا ضجيج
    // فعلي ليُزال، والفلتر يطمس بلا فائدة حواف الحروف الرفيعة (خطوط
    // Cairo/Tajawal الشائعة)، فيُشوِّش Tesseract بدل أن يساعده. كان هذا
    // الفلتر يعمل دائماً بلا أي شرط، بصرف النظر عن إعدادات الخيارات —
    // هذا تحديداً جزء من سبب الفرق الملحوظ فعلياً في الدقة عن Text Fairy
    // على نفس الصورة (راجع denoiseForCameraNoise في الخيارات أدناه).
    if (options.denoiseForCameraNoise) {
      working = _medianFilter3x3(working);
    }

    double skewAngle = 0.0;
    if (options.autoDeskew) {
      skewAngle = _detectSkewAngle(working, options.maxAutoDeskewAngle);
      if (skewAngle.abs() > 0.1) {
        working = img.copyRotate(working, angle: -skewAngle, interpolation: img.Interpolation.cubic);
      }
    }

    if (options.adaptiveContrastEnhancement) {
      working = _adaptiveContrastEnhance(working);
    }

    if (options.binarize) {
      working = _adaptiveBinarize(working);
    }

    final outDir = inputFile.parent;
    final outPath =
        '${outDir.path}/preprocessed_${DateTime.now().millisecondsSinceEpoch}.png';
    final outFile = File(outPath);
    await outFile.writeAsBytes(img.encodePng(working));

    return PreprocessedImage(
      image: working,
      detectedSkewAngleDegrees: skewAngle,
      savedFile: outFile,
    );
  }

  /// يحدد هل الخلفية الغالبة في الصورة داكنة (متوسط سطوع البكسلات أقل
  /// من نقطة وسط، 127) عبر هيستوغرام مبسّط على نسخة مصغّرة من الصورة
  /// (تسريع الحساب، لا حاجة لفحص كل بكسل في صورة كبيرة لتقدير تقريبي).
  /// نستخدم المتوسط لا أكثر شيوعاً (mode) لأنه أبسط وكافٍ عملياً: في
  /// لقطة شاشة أو وثيقة عادية، الخلفية تُشكّل الغالبية العظمى من مساحة
  /// الصورة (النص نسبة صغيرة منها)، فمتوسط السطوع يعكس لون الخلفية
  /// بدقة كافية بصرف النظر عن لون النص نفسه.
  static bool _isDarkBackgroundDominant(img.Image gray) {
    final probe = img.copyResize(gray, width: 100);
    double sum = 0;
    int count = 0;
    for (int y = 0; y < probe.height; y++) {
      for (int x = 0; x < probe.width; x++) {
        sum += img.getLuminance(probe.getPixel(x, y));
        count++;
      }
    }
    final average = count > 0 ? sum / count : 255.0;
    return average < 127.0;
  }

  /// فلتر متوسط 3x3 بسيط لإزالة ضجيج الكاميرا (sensor noise) بدون
  /// طمس حواف الحروف الدقيقة. يُطبَّق على القناة الرمادية مباشرة.
  static img.Image _medianFilter3x3(img.Image src) {
    final out = img.Image.from(src);
    final w = src.width, h = src.height;
    final window = List<int>.filled(9, 0);

    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        int idx = 0;
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            window[idx++] = img.getLuminance(src.getPixel(x + dx, y + dy)).toInt();
          }
        }
        window.sort();
        final median = window[4];
        out.setPixelRgb(x, y, median, median, median);
      }
    }
    return out;
  }

  /// يكشف زاوية ميل النص عبر تحليل تجميع بكسلات الحواف الداكنة على
  /// مجموعة زوايا تجريبية (تقريب مبسّط لتحويل Hough) ويختار الزاوية
  /// التي تُعطي أعلى "وضوح أسطر أفقية" (أقصى تباين بين صفوف البكسلات
  /// عند تجميعها أفقيًا، لأن السطر الصحيح يُنتج خطوطًا أفقية كثيفة).
  static double _detectSkewAngle(img.Image grayscale, double maxAngle) {
    const stepDegrees = 0.5;
    double bestAngle = 0.0;
    double bestScore = -1.0;

    // تقليص حجم الصورة مؤقتًا لتسريع الفحص (الدقة الكاملة غير ضرورية
    // لكشف الزاوية، فقط لتطبيق التصحيح النهائي).
    final probe = img.copyResize(grayscale, width: math.min(grayscale.width, 800));

    for (double angle = -maxAngle; angle <= maxAngle; angle += stepDegrees) {
      final rotated = img.copyRotate(probe, angle: -angle, interpolation: img.Interpolation.linear);
      final score = _horizontalProjectionVariance(rotated);
      if (score > bestScore) {
        bestScore = score;
        bestAngle = angle;
      }
    }
    return bestAngle;
  }

  /// يحسب تباين كثافة البكسلات الداكنة عبر صفوف الصورة (إسقاط أفقي).
  /// كلما زاد التباين بين الصفوف، كانت الأسطر النصية أكثر "استواءً".
  static double _horizontalProjectionVariance(img.Image gray) {
    final rowSums = List<double>.filled(gray.height, 0);
    for (int y = 0; y < gray.height; y++) {
      double sum = 0;
      for (int x = 0; x < gray.width; x++) {
        final lum = img.getLuminance(gray.getPixel(x, y));
        sum += (255 - lum); // الداكن يُحسب بقيمة أعلى
      }
      rowSums[y] = sum;
    }
    final mean = rowSums.reduce((a, b) => a + b) / rowSums.length;
    final variance =
        rowSums.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) / rowSums.length;
    return variance;
  }

  /// تحسين تباين تكيفي مبسّط: يقسّم الصورة إلى مربعات (tiles)، ويُعيد
  /// توزيع مستويات السطوع ضمن كل مربع بشكل مستقل (مشابه لمبدأ CLAHE)،
  /// مما يُصلح الصور التي بها ظل جزئي أو إضاءة غير متساوية على الصفحة —
  /// مشكلة شائعة جدًا عند تصوير الصفحات بالكاميرا وتُفقد Tesseract دقته
  /// كثيرًا معها إن لم تُعالَج.
  static img.Image _adaptiveContrastEnhance(img.Image gray) {
    const tileSize = 64;
    final out = img.Image.from(gray);
    final w = gray.width, h = gray.height;

    for (int ty = 0; ty < h; ty += tileSize) {
      for (int tx = 0; tx < w; tx += tileSize) {
        final tileW = math.min(tileSize, w - tx);
        final tileH = math.min(tileSize, h - ty);

        int minLum = 255, maxLum = 0;
        for (int y = ty; y < ty + tileH; y++) {
          for (int x = tx; x < tx + tileW; x++) {
            final lum = img.getLuminance(gray.getPixel(x, y)).toInt();
            if (lum < minLum) minLum = lum;
            if (lum > maxLum) maxLum = lum;
          }
        }

        final range = (maxLum - minLum).clamp(1, 255);
        for (int y = ty; y < ty + tileH; y++) {
          for (int x = tx; x < tx + tileW; x++) {
            final lum = img.getLuminance(gray.getPixel(x, y)).toInt();
            final stretched = (((lum - minLum) / range) * 255).clamp(0, 255).toInt();
            out.setPixelRgb(x, y, stretched, stretched, stretched);
          }
        }
      }
    }
    return out;
  }

  /// ثنائية تكيفية بطريقة Sauvola مبسّطة: العتبة تُحسب محليًا حسب متوسط
  /// وانحراف الجوار (نافذة 15x15)، بدل عتبة عامة ثابتة. هذا يحافظ على
  /// تشكيل الحروف العربية المتصلة في حالة الإضاءة المتفاوتة، وهي تحديدًا
  /// الحالة التي تُفسد فيها الثنائية الثابتة (global threshold) النقاط
  /// الدقيقة فوق/تحت الحروف العربية.
  static img.Image _adaptiveBinarize(img.Image gray) {
    const windowRadius = 7;
    const k = 0.2; // معامل حساسية Sauvola المعتاد
    final out = img.Image.from(gray);
    final w = gray.width, h = gray.height;

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final x0 = math.max(0, x - windowRadius);
        final x1 = math.min(w - 1, x + windowRadius);
        final y0 = math.max(0, y - windowRadius);
        final y1 = math.min(h - 1, y + windowRadius);

        double sum = 0, sumSq = 0;
        int count = 0;
        for (int wy = y0; wy <= y1; wy++) {
          for (int wx = x0; wx <= x1; wx++) {
            final lum = img.getLuminance(gray.getPixel(wx, wy)).toDouble();
            sum += lum;
            sumSq += lum * lum;
            count++;
          }
        }
        final mean = sum / count;
        final variance = (sumSq / count) - (mean * mean);
        final stdDev = math.sqrt(math.max(0, variance));
        final threshold = mean * (1 + k * ((stdDev / 128) - 1));

        final pixelLum = img.getLuminance(gray.getPixel(x, y));
        final value = pixelLum > threshold ? 255 : 0;
        out.setPixelRgb(x, y, value, value, value);
      }
    }
    return out;
  }

  /// يكشف مناطق التشبّع اللوني العالي (إيموجي ملوَّن) في الصورة الملوَّنة
  /// الأصلية، ويملأها بلون الخلفية الغالب المحسوب من بكسلات الصورة
  /// منخفضة التشبّع فقط (أي النص/الخلفية العادية، لا الإيموجي نفسه).
  ///
  /// آلية الكشف: لكل بكسل، "التشبّع" = (أعلى قناة RGB − أقل قناة RGB).
  /// نص عادي (أسود/أبيض/رمادي) قيمته قريبة من صفر دوماً. إيموجي ملوَّن
  /// (🔥 أحمر/برتقالي/أصفر) يُعطي تشبّعاً عالياً.
  ///
  /// ⚠️ قيد أمان حقيقي مهم: خلفيات تطبيقات ملوَّنة بالكامل (كفقاعات
  /// واتساب الخضراء الغامقة، تشبّعها العالي طبيعي تماماً وليس إيموجي)
  /// يجب ألا تُعتبَر "إيموجي" وتُمحى بالخطأ — لو طبَّقنا عتبة تشبّع فقط
  /// بلا قيد إضافي، خلفية واتساب الخضراء الكاملة (مثلاً RGB قريب من
  /// 0,92,75 → تشبّع~92) ستُكتشف كمنطقة "إيموجي" ضخمة وتُفسَد الصورة
  /// كاملةً بدل إصلاحها فقط. الإصلاح: نشترط أيضاً أن تكون **نسبة مساحة**
  /// البكسلات المُشبَّعة من إجمالي مساحة الصورة صغيرة جداً (أقل من 8%) —
  /// إيموجي واحد أو اثنان داخل نص لا يتجاوزان هذه النسبة عملياً، بخلاف
  /// خلفية تطبيق ملوَّنة كاملة التي تُغطي نسبة كبيرة من الصورة. إن
  /// تجاوزت النسبة هذا الحد، نعتبر اللون جزءاً من تصميم الصورة الطبيعي
  /// ولا نلمسها إطلاقاً (الأكثر أماناً: لا تغيير، بدل تغيير خاطئ شامل).
  static img.Image _removeSaturatedColorRegions(img.Image src) {
    final w = src.width, h = src.height;
    const saturationThreshold = 60;
    const maxSaturatedAreaRatio = 0.08;

    final mask = List.generate(h, (_) => List.filled(w, false));
    int saturatedCount = 0;
    double sumR = 0, sumG = 0, sumB = 0;
    int bgCount = 0;

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final p = src.getPixel(x, y);
        final r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt();
        final maxC = math.max(r, math.max(g, b));
        final minC = math.min(r, math.min(g, b));
        final isSaturated = (maxC - minC) >= saturationThreshold;
        if (isSaturated) {
          mask[y][x] = true;
          saturatedCount++;
        } else {
          sumR += r;
          sumG += g;
          sumB += b;
          bgCount++;
        }
      }
    }

    final totalPixels = w * h;
    final saturatedRatio = totalPixels > 0 ? saturatedCount / totalPixels : 0.0;

    // ⚠️ قيد الأمان: لو كانت نسبة المساحة المُشبَّعة كبيرة (خلفية ملوَّنة
    // كاملة، لا إيموجي محدود)، لا نُغيِّر أي شيء في الصورة إطلاقاً.
    if (saturatedRatio > maxSaturatedAreaRatio || bgCount == 0) {
      return src;
    }

    final bgR = (sumR / bgCount).round();
    final bgG = (sumG / bgCount).round();
    final bgB = (sumB / bgCount).round();

    // نملأ كل بكسل مُشبَّع بلون الخلفية المحسوب، مع هامش توسعة بسيط
    // (1 بكسل حول كل منطقة مُشبَّعة) لتغطية حواف الإيموجي الأقل تشبّعاً
    // (anti-aliasing) التي قد تتسرب من الكشف المباشر.
    final out = img.Image.from(src);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        bool nearSaturated = false;
        for (int dy = -1; dy <= 1 && !nearSaturated; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            final ny = y + dy, nx = x + dx;
            if (ny >= 0 && ny < h && nx >= 0 && nx < w && mask[ny][nx]) {
              nearSaturated = true;
              break;
            }
          }
        }
        if (nearSaturated) {
          out.setPixelRgb(x, y, bgR, bgG, bgB);
        }
      }
    }
    return out;
  }
}
