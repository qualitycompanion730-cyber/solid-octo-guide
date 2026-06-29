/// نماذج البيانات الخاصة بنتائج التعرف الضوئي على الحروف (OCR).
///
/// تُستخدم هذه النماذج لتمثيل خروج محرك Tesseract بشكل منظم:
/// صفحة -> كتل نصية (HOCR blocks) -> أسطر -> كلمات، مع صناديق الإحداثيات
/// (bounding boxes) ومستوى الثقة لكل عنصر، بالإضافة إلى اتجاه الكتابة
/// (RTL للعربية أو LTR للإنجليزية) المُكتشف تلقائيًا حسب نوع الأحرف.
library;

/// اتجاه الكتابة لكتلة نصية معينة.
/// ⚠️ سُمِّي OcrTextDirection (لا TextDirection) عمداً لتجنّب تعارض
/// الاسم مع dart:ui.TextDirection (المستخدَم في كل واجهات Flutter
/// لتحديد اتجاه عناصر الواجهة RTL/LTR) — كلا النوعين قد يكونان
/// مستوردين معاً في نفس الملف (كما في شاشات المراجعة)، فتعارض الاسم
/// كان يُسبب خطأ ترجمة "argument_type_not_assignable" حقيقياً.
enum OcrTextDirection { ltr, rtl }

/// صندوق إحداثيات بالبكسل بالنسبة لأبعاد الصورة الأصلية.
class OcrBoundingBox {
  final double left;
  final double top;
  final double width;
  final double height;

  const OcrBoundingBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  double get right => left + width;
  double get bottom => top + height;

  /// ينتج صندوقًا بنسب 0..1 بالنسبة لأبعاد الصورة، مفيد لإعادة الرسم
  /// على أي حجم عرض (شاشة أو صفحة PDF) بدون تشويه.
  OcrBoundingBoxNormalized normalize({
    required double imageWidth,
    required double imageHeight,
  }) {
    if (imageWidth <= 0 || imageHeight <= 0) {
      return const OcrBoundingBoxNormalized(left: 0, top: 0, width: 0, height: 0);
    }
    return OcrBoundingBoxNormalized(
      left: left / imageWidth,
      top: top / imageHeight,
      width: width / imageWidth,
      height: height / imageHeight,
    );
  }

  factory OcrBoundingBox.fromJson(Map<String, dynamic> json) {
    return OcrBoundingBox(
      left: (json['left'] as num).toDouble(),
      top: (json['top'] as num).toDouble(),
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'left': left,
        'top': top,
        'width': width,
        'height': height,
      };
}

/// نسخة طبيعية (0..1) من صندوق الإحداثيات، مستقلة عن الدقة الفعلية للصورة.
class OcrBoundingBoxNormalized {
  final double left;
  final double top;
  final double width;
  final double height;

  const OcrBoundingBoxNormalized({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
}

/// كلمة واحدة مع موقعها ومستوى ثقة المحرك في التعرف عليها (0-100).
class OcrWord {
  final String text;
  final OcrBoundingBox boundingBox;
  final double confidence;

  const OcrWord({
    required this.text,
    required this.boundingBox,
    required this.confidence,
  });

  /// ثقة منخفضة تشير إلى احتمال وجود خطأ في التعرف، تُستخدم لتمييز
  /// الكلمات بصريًا في واجهة المراجعة (تظليل بلون مختلف كما في Text Fairy
  /// لكن مع عرض رقم الثقة الفعلي بدل تظليل تقريبي فقط).
  bool get isLowConfidence => confidence < 65.0;

  factory OcrWord.fromJson(Map<String, dynamic> json) {
    return OcrWord(
      text: json['text'] as String,
      boundingBox: OcrBoundingBox.fromJson(json['boundingBox'] as Map<String, dynamic>),
      confidence: (json['confidence'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'text': text,
        'boundingBox': boundingBox.toJson(),
        'confidence': confidence,
      };
}

/// سطر نصي كامل، يحتوي على كلماته بالترتيب البصري الأصلي من المحرك،
/// مع اتجاه الكتابة المُستنتج من نوع الأحرف الغالب في السطر.
class OcrLine {
  final List<OcrWord> words;
  final OcrBoundingBox boundingBox;
  final OcrTextDirection direction;

  const OcrLine({
    required this.words,
    required this.boundingBox,
    required this.direction,
  });

  /// النص الكامل للسطر بترتيب القراءة الصحيح (يعكس ترتيب الكلمات لو كان
  /// السطر RTL، لأن Tesseract يُخرج الكلمات بترتيب الصندوق الأفقي
  /// (يسار->يمين) دائمًا بصرف النظر عن اتجاه اللغة).
  /// النص الكامل للسطر بترتيب القراءة الصحيح.
  ///
  /// ⚠️ إصلاح حقيقي (انعكاس ترتيب الكلمات داخل السطر): الاعتماد على
  /// `words.reversed` فقط (الإصدار السابق) كان خاطئاً لأنه يفترض أن
  /// عناصر `ocrx_word` في HOCR تَرِد بترتيب موضعها الأفقي (يسار->يمين)
  /// بالضبط دائماً، وهذا غير مضمون فعلياً — Tesseract قد يُخرجها بترتيب
  /// اكتشاف داخلي مختلف عن الترتيب البصري الحقيقي. هذا تحديداً ما ظهر
  /// فعلياً: سطر "بالنسبة لطريقة امتحان مادة العقيدة" خرج معكوساً جزئياً
  /// ("مادة امتحان لطريقة بالنسبة") رغم تطبيق reversed.
  ///
  /// الإصلاح الموثوق: نرتّب الكلمات أولاً فعلياً بحسب `boundingBox.left`
  /// (الإحداثي الأفقي الفعلي من HOCR، مضمون الدقة بصرف النظر عن ترتيب
  /// ظهورها في XML) تصاعدياً = يسار->يمين بصرياً، ثم نعكس هذا الترتيب
  /// المُصحَّح فقط لو كان السطر RTL — لا نعتمد على الترتيب الخام أبداً.
  String get readingOrderText {
    final sortedByPosition = [...words]
      ..sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
    final ordered = direction == OcrTextDirection.rtl
        ? sortedByPosition.reversed.toList()
        : sortedByPosition;
    return ordered.map((w) => w.text).join(' ');
  }

  double get averageConfidence {
    if (words.isEmpty) return 0;
    return words.map((w) => w.confidence).reduce((a, b) => a + b) / words.length;
  }

  factory OcrLine.fromJson(Map<String, dynamic> json) {
    return OcrLine(
      words: (json['words'] as List)
          .map((w) => OcrWord.fromJson(w as Map<String, dynamic>))
          .toList(),
      boundingBox: OcrBoundingBox.fromJson(json['boundingBox'] as Map<String, dynamic>),
      direction: json['direction'] == 'rtl' ? OcrTextDirection.rtl : OcrTextDirection.ltr,
    );
  }

  Map<String, dynamic> toJson() => {
        'words': words.map((w) => w.toJson()).toList(),
        'boundingBox': boundingBox.toJson(),
        'direction': direction == OcrTextDirection.rtl ? 'rtl' : 'ltr',
      };
}

/// كتلة نصية (فقرة) تجمع أسطرًا متتالية ذات تباعد متقارب، كما يحددها
/// محلل التخطيط الصفحي (PSM) في Tesseract.
class OcrBlock {
  final List<OcrLine> lines;
  final OcrBoundingBox boundingBox;

  const OcrBlock({required this.lines, required this.boundingBox});

  String get text => lines.map((l) => l.readingOrderText).join('\n');

  factory OcrBlock.fromJson(Map<String, dynamic> json) {
    return OcrBlock(
      lines: (json['lines'] as List)
          .map((l) => OcrLine.fromJson(l as Map<String, dynamic>))
          .toList(),
      boundingBox: OcrBoundingBox.fromJson(json['boundingBox'] as Map<String, dynamic>),
    );
  }

  Map<String, dynamic> toJson() => {
        'lines': lines.map((l) => l.toJson()).toList(),
        'boundingBox': boundingBox.toJson(),
      };
}

/// نتيجة OCR لصفحة واحدة (صورة واحدة أو صفحة واحدة من PDF ممسوح).
class OcrPageResult {
  /// مسار الصورة المصدر بعد المعالجة المسبقة (تصحيح الميل/التباين)،
  /// تُستخدم كخلفية لطبقة النص الشفافة في الـ Searchable PDF.
  final String sourceImagePath;
  final int imageWidthPx;
  final int imageHeightPx;
  final List<OcrBlock> blocks;

  /// مدة المعالجة بالمللي ثانية، تُعرض للمستخدم كمؤشر شفافية على الأداء.
  final int processingTimeMs;

  const OcrPageResult({
    required this.sourceImagePath,
    required this.imageWidthPx,
    required this.imageHeightPx,
    required this.blocks,
    required this.processingTimeMs,
  });

  String get fullText => blocks.map((b) => b.text).join('\n\n');

  double get averageConfidence {
    final allWords = blocks.expand((b) => b.lines).expand((l) => l.words).toList();
    if (allWords.isEmpty) return 0;
    return allWords.map((w) => w.confidence).reduce((a, b) => a + b) / allWords.length;
  }

  factory OcrPageResult.fromJson(Map<String, dynamic> json) {
    return OcrPageResult(
      sourceImagePath: json['sourceImagePath'] as String,
      imageWidthPx: json['imageWidthPx'] as int,
      imageHeightPx: json['imageHeightPx'] as int,
      blocks: (json['blocks'] as List)
          .map((b) => OcrBlock.fromJson(b as Map<String, dynamic>))
          .toList(),
      processingTimeMs: json['processingTimeMs'] as int,
    );
  }

  Map<String, dynamic> toJson() => {
        'sourceImagePath': sourceImagePath,
        'imageWidthPx': imageWidthPx,
        'imageHeightPx': imageHeightPx,
        'blocks': blocks.map((b) => b.toJson()).toList(),
        'processingTimeMs': processingTimeMs,
      };
}

/// نتيجة العملية الكاملة (وثيقة كاملة قد تحتوي صفحة واحدة أو أكثر
/// في حالة PDF ممسوح متعدد الصفحات).
class OcrDocumentResult {
  final List<OcrPageResult> pages;
  final DateTime createdAt;

  /// عنوان مقترح للمستند، يُستخرج من أول سطر منطوق في أول صفحة، ويُستخدم
  /// كاسم افتراضي عند الحفظ كـ DOCX أو PDF أو في سجل العمليات.
  String get suggestedTitle {
    if (pages.isEmpty || pages.first.blocks.isEmpty) return 'مستند ممسوح';
    final firstLine = pages.first.blocks.first.lines.isNotEmpty
        ? pages.first.blocks.first.lines.first.readingOrderText
        : '';
    if (firstLine.trim().isEmpty) return 'مستند ممسوح';
    return firstLine.length > 40 ? '${firstLine.substring(0, 40)}...' : firstLine;
  }

  String get combinedText => pages.map((p) => p.fullText).join('\n\n---\n\n');

  const OcrDocumentResult({required this.pages, required this.createdAt});

  factory OcrDocumentResult.fromJson(Map<String, dynamic> json) {
    return OcrDocumentResult(
      pages: (json['pages'] as List)
          .map((p) => OcrPageResult.fromJson(p as Map<String, dynamic>))
          .toList(),
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
        'pages': pages.map((p) => p.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
      };
}
