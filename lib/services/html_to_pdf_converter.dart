// html_to_pdf_converter.dart — يرسم عبر الجسر الأصلي لأندرويد
//
// ── ملخص إعادة البناء ──────────────────────────────────────────────────
// • المحلِّل (_parseHtml وكل الدوال المساعدة: استخراج CSS variables، حل
//   الوسوم المتداخلة، الجداول، القوائم، النماذج، SVG) لم يتغيّر إطلاقاً —
//   هذا منطق تحليل HTML بحت لا علاقة له بمحرك الرسم.
// • حُذف بالكامل: _HtmlPdfWriter (رسم Syncfusion المباشر، بما فيه تبسيط
//   "dominant span" الذي كان يفرض نمطاً واحداً على كل الفقرة حتى لو
//   احتوت عدة أنماط مختلطة — قيد Syncfusion's drawString لنمط واحد فقط
//   لكل نداء). النموذج الجديد يرسم كل span بنمطه الفعلي عبر StaticLayout
//   (تحسين حقيقي، لا مجرد استبدال محرك).
// • أُضيف: _mapBlocksToDocSpec(...) يحوّل List<_ContentBlock> إلى
//   PdfDocSpec تصريحي يُمرَّر لاحقاً إلى NativePdfBridge.renderDocument.
// • تحميل الخطوط: convert() القديمة كانت تستدعي rootBundle مباشرة. الآن
//   parseToLayout() تستقبل preloadedFonts جاهزة (محمَّلة في Main Isolate
//   عبر loadAllFontsOnMainIsolate من docx_to_pdf_converter.dart) — هذا
//   مهم بشكل خاص هنا لأن هذا الملف **لم يكن مُغلَّفاً بـ Isolate إطلاقاً
//   من قبل** (انظر isolate_support.dart لتفاصيل الإضافة الجديدة)، فكان
//   التحويل بأكمله يُجمِّد واجهة المستخدم على ملفات HTML الكبيرة.
//
// ⚠️ ملاحظة تكامل مهمة: lib/screens/tools/html_to_pdf_screen.dart **لم
// يكن يستخدم هذا الملف إطلاقاً** — كان يحتوي منطق استخراج نص خام بـ Regex
// ورسم Syncfusion مباشر بديل ومستقل تماماً، يُشغَّل على Main Isolate (لا
// isolate خلفي)، ويفرض RTL/محاذاة يمين دائماً حتى لمحتوى إنجليزي بحت. هذا
// الملف المُعاد بناؤه هو الخدمة الحقيقية الغنية (عناوين، جداول، قوائم،
// نماذج) التي يجب أن تستخدمها الشاشة فعلياً — راجع ملاحظة التكامل في
// README لتفاصيل ربط الشاشة بهذا الملف عبر convertHtmlInBackground.

import '../pdf_engine/pdf_layout_model.dart';
import 'shared/arabic_text_utils.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  واجهة عامة
// ─────────────────────────────────────────────────────────────────────────────

class HtmlConversionProgress {
  final double progress;
  final String stage;
  const HtmlConversionProgress(this.progress, this.stage);
}

class HtmlCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class HtmlConversionException implements Exception {
  final String message;
  const HtmlConversionException(this.message);
  @override
  String toString() => message;
}

class HtmlCancelledException implements Exception {
  const HtmlCancelledException();
  @override
  String toString() => 'تم إلغاء التحويل';
}

// ─────────────────────────────────────────────────────────────────────────────
//  خيارات التحويل
// ─────────────────────────────────────────────────────────────────────────────

enum HtmlPageSize { a4, a5, letter, legal }

class HtmlConversionOptions {
  final HtmlPageSize pageSize;
  final bool rtl;
  final bool removeScripts;
  final double baseFontSize;

  const HtmlConversionOptions({
    this.pageSize = HtmlPageSize.a4,
    this.rtl = true,
    this.removeScripts = true,
    this.baseFontSize = 11,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
//  نماذج البلوكات الداخلية
// ─────────────────────────────────────────────────────────────────────────────

enum _BlockType {
  paragraph,
  heading,
  listItem,
  codeBlock,
  tableRow,
  divider,
  formField,
  svgPlaceholder,
}

enum _TextAlign { start, center, end, justify, left, right }

class _TextSpan {
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strikethrough;
  final bool code;
  final double? fontSize;
  final String? colorHex;
  final bool isLink;

  const _TextSpan({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.code = false,
    this.colorHex,
    // ignore: unused_element_parameter
    this.isLink = false,
    // ignore: unused_element_parameter
    this.fontSize,
  });
}

class _ContentBlock {
  final _BlockType type;
  final List<_TextSpan> spans;
  final int headingLevel;
  final int listLevel;
  final bool isOrdered;
  final int orderIndex;
  // جدول: كل صف هو قائمة خلايا، كل خلية قائمة spans
  final List<List<_TextSpan>> tableCells;
  // عدد الأعمدة الممتدة لكل خلية (colspan)
  final List<int> tableColspans;
  // عدد الصفوف الممتدة لكل خلية (rowspan) — يُستخدَم مع خوارزمية شبكة
  // الإشغال في طبقة الربط لإنتاج امتداد عمودي حقيقي بدل تجاهله.
  final List<int> tableRowSpans;
  final bool isTableHeader;
  final _TextAlign align;
  final bool rtl;
  // بيانات إضافية (اسم حقل النموذج، placeholder SVG ...)
  final String? extra;

  const _ContentBlock({
    required this.type,
    this.spans = const [],
    this.headingLevel = 0,
    this.listLevel = 0,
    this.isOrdered = false,
    this.orderIndex = 0,
    this.tableCells = const [],
    this.tableColspans = const [],
    this.tableRowSpans = const [],
    this.isTableHeader = false,
    this.align = _TextAlign.start,
    this.rtl = false,
    this.extra,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
//  المحوّل الرئيسي
// ─────────────────────────────────────────────────────────────────────────────

class HtmlToPdfConverter {
  HtmlToPdfConverter._();

  /// يحلّل نص HTML ويُعيد PdfDocSpec — نموذج تخطيط تصريحي بلا أي PDF
  /// مُولَّد بعد. لا يستدعي rootBundle أو أي MethodChannel، فهو آمن
  /// للاستدعاء من Worker Isolate. لتوليد بايتات PDF فعلية مرّر النتيجة
  /// إلى NativePdfBridge.renderDocument() من Main Isolate.
  static Future<PdfDocSpec> parseToLayout(
    String htmlContent, {
    HtmlConversionOptions options = const HtmlConversionOptions(),
    void Function(HtmlConversionProgress)? onProgress,
    HtmlCancelToken? cancelToken,
  }) async {
    void report(double p, String stage) {
      if (cancelToken?.isCancelled != true) {
        onProgress?.call(HtmlConversionProgress(p, stage));
      }
    }

    void checkCancelled() {
      if (cancelToken?.isCancelled == true) {
        throw const HtmlCancelledException();
      }
    }

    report(0.05, 'التحقق من المحتوى...');
    if (htmlContent.trim().isEmpty) {
      throw const HtmlConversionException('محتوى HTML فارغ');
    }
    checkCancelled();

    report(0.15, 'تحليل بنية HTML...');
    final blocks = _parseHtml(htmlContent, options);
    checkCancelled();

    report(0.40, 'تجهيز التخطيط...');
    final (pgW, pgH) = _pageDims(options.pageSize);
    const marginH = 50.0;
    const marginV = 50.0;

    final spec = _mapBlocksToDocSpec(
      blocks: blocks,
      options: options,
      pageW: pgW,
      pageH: pgH,
      marginH: marginH,
      marginV: marginV,
    );

    report(0.60, 'اكتمل تجهيز التخطيط');
    return spec;
  }

  static (double, double) _pageDims(HtmlPageSize size) {
    switch (size) {
      case HtmlPageSize.a5:
        return (419.53, 595.28);
      case HtmlPageSize.letter:
        return (612.0, 792.0);
      case HtmlPageSize.legal:
        return (612.0, 1008.0);
      case HtmlPageSize.a4:
      // ignore: unreachable_switch_default
      default:
        return (595.28, 841.89);
    }
  }

  

  // ─────────────────────────────────────────────────────────────────────────
  //  محلل HTML
  // ─────────────────────────────────────────────────────────────────────────

  static List<_ContentBlock> _parseHtml(
      String html, HtmlConversionOptions options) {
    // 1. حل CSS variables من :root
    final cssVars = _extractCssVars(html);

    // 2. حذف <script> و <style>
    var text = html;
    if (options.removeScripts) {
      text = text.replaceAll(
          RegExp(r'<script[^>]*>.*?</script>',
              dotAll: true, caseSensitive: false),
          '');
    }
    text = text.replaceAll(
        RegExp(r'<style[^>]*>.*?</style>', dotAll: true, caseSensitive: false),
        '');
    text = text.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

    // 3. استبدال CSS vars في style attributes
    text = _resolveCssVars(text, cssVars);

    // 4. استخراج <body>
    final bodyMatch =
        RegExp(r'<body[^>]*>(.*?)</body>', dotAll: true, caseSensitive: false)
            .firstMatch(text);
    final body = bodyMatch?.group(1) ?? text;

    final blocks = <_ContentBlock>[];
    _extractBlocks(body, blocks, options, level: 0, orderedCounters: {});
    return blocks;
  }

  /// استخراج متغيرات CSS من :root { --name: value; }
  static Map<String, String> _extractCssVars(String html) {
    final vars = <String, String>{};
    final rootMatch =
        RegExp(r':root\s*\{([^}]+)\}', dotAll: true).firstMatch(html);
    if (rootMatch == null) return vars;

    final body = rootMatch.group(1) ?? '';
    final varRe = RegExp(r'--([a-zA-Z0-9-]+)\s*:\s*([^;]+);');
    for (final m in varRe.allMatches(body)) {
      vars['--${m.group(1)!}'] = m.group(2)!.trim();
    }
    return vars;
  }

  static String _resolveCssVars(String html, Map<String, String> vars) {
    if (vars.isEmpty) return html;
    return html.replaceAllMapped(RegExp(r'var\((--[a-zA-Z0-9-]+)\)'), (m) {
      return vars[m.group(1)] ?? m.group(0)!;
    });
  }

  // وسوم "block-level" التي نعالجها
  static final _blockTagRe = RegExp(
    r'<(h[1-6]|p|div|section|article|header|footer|main|nav|aside|'
    r'ul|ol|li|table|thead|tbody|tr|th|td|blockquote|pre|code|figure|'
    r'figcaption|hr|br|form|fieldset|input|textarea|select|button|svg)\b[^>]*?>',
    caseSensitive: false,
  );

  /// يبحث عن علامة الإغلاق المطابقة (بعدّ العمق) لتجنب التطابق المبكر
  static ({int closeStart, int afterClose})? _findClose(
      String html, int from, String tag) {
    final re = RegExp('<(/?)$tag\\b[^>]*>', caseSensitive: false);
    int depth = 1;
    for (final m in re.allMatches(html, from)) {
      final isClose = m.group(1) == '/';
      if (!isClose) {
        depth++;
      } else {
        depth--;
        if (depth == 0) return (closeStart: m.start, afterClose: m.end);
      }
    }
    return null;
  }

  static const _selfClosingTags = {'br', 'hr', 'input', 'img'};

  static const _containerTags = {
    'div',
    'section',
    'article',
    'header',
    'footer',
    'main',
    'nav',
    'aside',
    'form',
    'fieldset',
    'figure',
    'ul',
    'ol',
  };

  static void _extractBlocks(
    String html,
    List<_ContentBlock> blocks,
    HtmlConversionOptions options, {
    required int level,
    required Map<String, int> orderedCounters,
  }) {
    int pos = 0;

    while (pos < html.length) {
      RegExpMatch? m;
      for (final c in _blockTagRe.allMatches(html, pos)) {
        m = c;
        break;
      }
      if (m == null) break;

      // نص حر قبل الوسم
      if (m.start > pos) {
        _addTextBlock(html.substring(pos, m.start), blocks, options,
            level: level);
      }

      final tag = m.group(1)!.toLowerCase();
      final openTag = m.group(0)!;
      final tagAttrs = openTag;

      // وسوم ذاتية الإغلاق
      if (_selfClosingTags.contains(tag) ||
          openTag.trimRight().endsWith('/>')) {
        pos = m.end;
        if (tag == 'hr' || tag == 'br') {
          blocks.add(const _ContentBlock(type: _BlockType.divider));
        } else if (tag == 'input') {
          final type = _attr(openTag, 'type') ?? 'text';
          final value = _attr(openTag, 'value') ?? '';
          final placeholder = _attr(openTag, 'placeholder') ?? '';
          blocks.add(_ContentBlock(
            type: _BlockType.formField,
            extra: _renderFormControl(type, value, placeholder, openTag),
          ));
        }
        continue;
      }

      final innerStart = m.end;
      int innerEnd;
      int matchEnd;

      if (_containerTags.contains(tag)) {
        final close = _findClose(html, m.end, tag);
        innerEnd = close?.closeStart ?? html.length;
        matchEnd = close?.afterClose ?? html.length;
      } else {
        final closeRe = RegExp('</$tag\\s*>', caseSensitive: false);
        final closeM = closeRe.firstMatch(html.substring(m.end));
        innerEnd = closeM != null ? m.end + closeM.start : html.length;
        matchEnd = closeM != null ? m.end + closeM.end : html.length;
      }

      final inner = html.substring(innerStart, innerEnd);
      pos = matchEnd;

      // هل العنصر محدد اتجاهه صراحةً، أم نعتمد على محتواه الفعلي؟
      // ⚠️ إصلاح خلل حقيقي مؤكَّد على جهاز فعلي: كان elementRtl يرث
      // options.rtl (افتراض المستند الكلي) فوراً عند غياب dir صريح، حتى
      // لمحتوى لا يحوي حرفاً عربياً واحداً (مثل أكواد ألوان hex خالصة
      // "#1E2761"). فرض اتجاه RTL على نص لا صلة له بالعربية يُفعِّل
      // خوارزمية Unicode Bidi الحقيقية على تتابعات أرقام/رموز ضعيفة
      // الاتجاه، فتُعكَس بصرياً بشكل غير متوقَّع وغير متّسق (تأكيد فعلي:
      // "#F96167" ظهرت "F96167#" بينما "#065A82" ظهرت سليمة في نفس
      // الصفحة). الإصلاح: نفحص محتوى العنصر نفسه أولاً؛ لا نرث الافتراض
      // الكلي إلا إن لم يُحدَّد dir صراحةً ولم يحوِ العنصر حرفاً عربياً.
      final elementRtl = _detectElementRtl(tagAttrs, options, inner);

      switch (tag) {
        // ── عناوين ──────────────────────────────────────────────────────
        case 'h1':
        case 'h2':
        case 'h3':
        case 'h4':
        case 'h5':
        case 'h6':
          final lvl = int.parse(tag.substring(1));
          final spans = _parseInlineSpans(inner, lvl <= 2);
          final text = spans.map((s) => s.text).join();
          if (text.trim().isNotEmpty) {
            blocks.add(_ContentBlock(
              type: _BlockType.heading,
              headingLevel: lvl,
              spans: spans,
              rtl: elementRtl || hasArabic(text),
              align: _detectAlign(tagAttrs),
            ));
          }

        // ── فقرة ────────────────────────────────────────────────────────
        case 'p':
          final spans = _parseInlineSpans(inner, false);
          final text = spans.map((s) => s.text).join();
          if (text.trim().isNotEmpty) {
            blocks.add(_ContentBlock(
              type: _BlockType.paragraph,
              spans: spans,
              rtl: elementRtl || hasArabic(text),
              align: _detectAlign(tagAttrs),
            ));
          }

        // ── حاويات (div, section, article...) ───────────────────────────
        case 'div':
        case 'section':
        case 'article':
        case 'header':
        case 'footer':
        case 'main':
        case 'nav':
        case 'aside':
        case 'figure':
        case 'figcaption':
          _extractBlocks(inner, blocks, options,
              level: level, orderedCounters: orderedCounters);

        // ── قوائم ───────────────────────────────────────────────────────
        case 'ul':
          _extractListItems(inner, blocks, options,
              level: level, isOrdered: false, counters: orderedCounters);
        case 'ol':
          final key = 'ol_$level';
          orderedCounters[key] = 0;
          _extractListItems(inner, blocks, options,
              level: level, isOrdered: true, counters: orderedCounters);

        // ── جداول ───────────────────────────────────────────────────────
        case 'table':
          _extractTable(inner, blocks, options, elementRtl, tagAttrs);

        // ── اقتباس ──────────────────────────────────────────────────────
        case 'blockquote':
          final spans = _parseInlineSpans(inner, false);
          final text = spans.map((s) => s.text).join().trim();
          if (text.isNotEmpty) {
            blocks.add(_ContentBlock(
              type: _BlockType.paragraph,
              spans: [
                _TextSpan(
                  text: '❝  $text  ❞',
                  italic: true,
                  colorHex: '718096',
                )
              ],
              rtl: elementRtl || hasArabic(text),
            ));
          }

        // ── كود ─────────────────────────────────────────────────────────
        case 'pre':
        case 'code':
          final text = _decodeEntities(_stripTags(inner));
          if (text.trim().isNotEmpty) {
            blocks.add(_ContentBlock(
              type: _BlockType.codeBlock,
              spans: [_TextSpan(text: text, code: true)],
              rtl: false,
            ));
          }

        // ── نماذج ───────────────────────────────────────────────────────
        case 'form':
        case 'fieldset':
          // استخرج عناصر النموذج من داخله
          _extractFormElements(inner, blocks);

        case 'textarea':
          final text = _decodeEntities(_stripTags(inner)).trim();
          if (text.isNotEmpty) {
            blocks.add(_ContentBlock(
              type: _BlockType.formField,
              extra: '[ Textarea ]\n$text',
            ));
          }

        case 'select':
          final options0 = RegExp(
                  r'<option[^>]*(?:selected[^>]*)?>([^<]+)</option>',
                  caseSensitive: false)
              .allMatches(inner)
              .map((m) => _decodeEntities(m.group(1) ?? ''))
              .join(' / ');
          if (options0.isNotEmpty) {
            blocks.add(_ContentBlock(
              type: _BlockType.formField,
              extra: '[ Select: $options0 ]',
            ));
          }

        case 'button':
          final text = _decodeEntities(_stripTags(inner)).trim();
          if (text.isNotEmpty) {
            blocks.add(_ContentBlock(
              type: _BlockType.formField,
              extra: '[ Button: $text ]',
            ));
          }

        // ── SVG ─────────────────────────────────────────────────────────
        case 'svg':
          // استخرج النصوص من داخل SVG
          final svgTexts =
              RegExp(r'<text[^>]*>([^<]+)</text>', caseSensitive: false)
                  .allMatches(inner)
                  .map((m) => _decodeEntities(m.group(1) ?? ''))
                  .where((t) => t.trim().isNotEmpty)
                  .join(' · ');

          final w = _attr(openTag, 'width') ?? '?';
          final h0 = _attr(openTag, 'height') ?? '?';
          blocks.add(_ContentBlock(
            type: _BlockType.svgPlaceholder,
            extra: 'SVG $w×$h0${svgTexts.isNotEmpty ? ' — $svgTexts' : ''}',
          ));
      }
    }

    // نص متبقٍّ
    if (pos < html.length) {
      _addTextBlock(html.substring(pos), blocks, options, level: level);
    }
  }

  static void _addTextBlock(
    String raw,
    List<_ContentBlock> blocks,
    HtmlConversionOptions options, {
    required int level,
  }) {
    final clean = _decodeEntities(_stripTags(raw)).trim();
    if (clean.isEmpty) return;
    final isRtl = hasArabic(clean) || options.rtl;
    blocks.add(_ContentBlock(
      type: _BlockType.paragraph,
      spans: [_TextSpan(text: clean)],
      rtl: isRtl,
    ));
  }

  static bool _detectElementRtl(
      String attrs, HtmlConversionOptions options, String content) {
    if (attrs.contains('dir="rtl"') || attrs.contains("dir='rtl'")) {
      return true;
    }
    if (attrs.contains('dir="ltr"') || attrs.contains("dir='ltr'")) {
      return false;
    }
    // لا اتجاه صريح: نفحص محتوى العنصر نفسه أولاً. محتوى يحوي عربياً
    // فعلياً يأخذ RTL بصرف النظر عن افتراض المستند؛ محتوى خالٍ من العربية
    // (أرقام/رموز/لاتيني بحت) لا يجب أن يُفرَض عليه RTL فقط لأن المستند
    // الكلي افتراضه RTL — هذا يُسبِّب انعكاس بصري غير متوقَّع لتتابعات
    // الأرقام/الرموز عبر خوارزمية Unicode Bidi الحقيقية (راجع التعليق في
    // موضع الاستدعاء لتفصيل الحالة المؤكَّدة فعلياً).
    if (hasArabic(content)) return true;
    if (hasLatin(content)) return false;
    // لا عربي ولا لاتيني واضح (أرقام/رموز فقط، أو عنصر بلا نص مباشر مثل
    // حاوية تحوي عناصر فرعية فقط) — نرجع لافتراض المستند الكلي كحل أخير
    // معقول، لأن المحتوى نفسه غير حاسم في تحديد الاتجاه.
    return options.rtl;
  }

  

  /// استخراج عناصر <li> مع دعم القوائم المتداخلة
  static void _extractListItems(
    String html,
    List<_ContentBlock> blocks,
    HtmlConversionOptions options, {
    required int level,
    required bool isOrdered,
    required Map<String, int> counters,
  }) {
    final key = 'ol_$level';
    int pos = 0;

    while (pos < html.length) {
      final liStart = html.indexOf('<li', pos);
      if (liStart == -1) break;
      final tagEnd = html.indexOf('>', liStart);
      if (tagEnd == -1) break;

      final close = _findClose(html, tagEnd + 1, 'li');
      final innerEnd = close?.closeStart ?? html.length;
      final matchEnd = close?.afterClose ?? html.length;

      final inner = html.substring(tagEnd + 1, innerEnd);
      pos = matchEnd;

      // احذف القوائم المتداخلة من نص العنصر
      final withoutNested = inner
          .replaceAll(
              RegExp(r'<ul[^>]*>.*?</ul>', dotAll: true, caseSensitive: false),
              '')
          .replaceAll(
              RegExp(r'<ol[^>]*>.*?</ol>', dotAll: true, caseSensitive: false),
              '');

      final spans = _parseInlineSpans(withoutNested, false);
      final text = spans.map((s) => s.text).join().trim();

      int idx = 0;
      if (isOrdered) {
        counters[key] = (counters[key] ?? 0) + 1;
        idx = counters[key]!;
      }

      if (text.isNotEmpty) {
        blocks.add(_ContentBlock(
          type: _BlockType.listItem,
          spans: spans,
          listLevel: level,
          isOrdered: isOrdered,
          orderIndex: idx,
          rtl: hasArabic(text) || false,
        ));
      }

      // قوائم متداخلة
      final nestedUl =
          RegExp(r'<ul[^>]*>(.*?)</ul>', dotAll: true, caseSensitive: false)
              .firstMatch(inner);
      if (nestedUl != null) {
        _extractListItems(nestedUl.group(1) ?? '', blocks, options,
            level: level + 1, isOrdered: false, counters: counters);
      }
      final nestedOl =
          RegExp(r'<ol[^>]*>(.*?)</ol>', dotAll: true, caseSensitive: false)
              .firstMatch(inner);
      if (nestedOl != null) {
        _extractListItems(nestedOl.group(1) ?? '', blocks, options,
            level: level + 1, isOrdered: true, counters: counters);
      }
    }
  }

  /// استخراج جدول — مع دعم colspan
  static void _extractTable(
    String html,
    List<_ContentBlock> blocks,
    HtmlConversionOptions options,
    bool tableRtl,
    String tableTagAttrs,
  ) {
    // ⚠️ إصلاح خلل حقيقي مؤكَّد على جهاز فعلي: عندما لا يحدّد <table> اتجاهه
    // صراحةً (لا dir="rtl" ولا dir="ltr")، كان tableRtl يرث افتراض المستند
    // الكلي (options.rtl) بصرف النظر عن محتوى الجدول الفعلي — فجدول إنجليزي
    // بحت داخل مستند افتراضه RTL كان يُعرَض معكوس الأعمدة (يمين-إلى-يسار)
    // رغم كونه إنجليزياً صرفاً. الإصلاح: إن لم يحدّد <table> اتجاهه صراحةً،
    // نفحص محتوى الجدول نفسه (أي حرف عربي في أي خلية) قبل اللجوء لافتراض
    // المستند الكلي — نفس المنطق المُستخدَم لكل فقرة عادية في هذا الملف
    // (elementRtl || _hasArabic(text)).
    final hasExplicitDir = tableTagAttrs.contains('dir="rtl"') ||
        tableTagAttrs.contains("dir='rtl'") ||
        tableTagAttrs.contains('dir="ltr"') ||
        tableTagAttrs.contains("dir='ltr'");
    final effectiveTableRtl = hasExplicitDir ? tableRtl : hasArabic(html);

    final rowRe =
        RegExp(r'<tr\b[^>]*>(.*?)</tr>', dotAll: true, caseSensitive: false);

    for (final rowMatch in rowRe.allMatches(html)) {
      final rowInner = rowMatch.group(1) ?? '';
      // هل هذا الصف داخل <thead>؟
      final beforeRow = html.substring(0, rowMatch.start).toLowerCase();
      final inThead = _countBetween(beforeRow, '<thead', '</thead') > 0 ||
          rowInner.contains('<th');

      final cells = <List<_TextSpan>>[];
      final colspans = <int>[];
      final rowspans = <int>[];

      final cellRe = RegExp(r'<t([dh])\b([^>]*)>(.*?)</t[dh]>',
          dotAll: true, caseSensitive: false);
      for (final cellM in cellRe.allMatches(rowInner)) {
        final cellAttrs = cellM.group(2) ?? '';
        final cellInner = cellM.group(3) ?? '';
        final isHeader = cellM.group(1)?.toLowerCase() == 'h';
        final spans = _parseInlineSpans(cellInner, isHeader || inThead);
        cells.add(spans);
        // colspan/rowspan: نحتفظ بالقيم الحقيقية على الخلية نفسها (لا
        // نُوسِّعها إلى خلايا فارغة تالية) — طبقة الربط (_mapBlocksToDocSpec)
        // تبني شبكة إشغال حقيقية منها، تماماً كما في XLSX/PPTX. توسيع
        // colspan لخلايا فارغة سابقاً كان يفقد معلومة الامتداد كلياً فيُعرض
        // الجدول بخلايا منفصلة بدل خلية واحدة ممتدة بصرياً.
        final cs = int.tryParse(
                RegExp(r'colspan="(\d+)"').firstMatch(cellAttrs)?.group(1) ??
                    '1') ??
            1;
        colspans.add(cs);
        final rs = int.tryParse(
                RegExp(r'rowspan="(\d+)"').firstMatch(cellAttrs)?.group(1) ??
                    '1') ??
            1;
        rowspans.add(rs);
      }

      if (cells.isNotEmpty) {
        blocks.add(_ContentBlock(
          type: _BlockType.tableRow,
          tableCells: cells,
          tableColspans: colspans,
          tableRowSpans: rowspans,
          isTableHeader: inThead,
          rtl: effectiveTableRtl,
        ));
      }
    }
  }

  /// يحسب كم مرة فُتح tag بدون أن يُغلق في النص المعطى
  static int _countBetween(String html, String openTag, String closeTag) {
    final opens = RegExp(openTag).allMatches(html).length;
    final closes = RegExp(closeTag).allMatches(html).length;
    return opens - closes;
  }

  /// استخراج عناصر النموذج كنص وصفي
  static void _extractFormElements(String html, List<_ContentBlock> blocks) {
    // input
    for (final m
        in RegExp(r'<input\b([^>]*)>', caseSensitive: false).allMatches(html)) {
      final attrs = m.group(1) ?? '';
      final type = _attr(attrs, 'type') ?? 'text';
      final value = _attr(attrs, 'value') ?? '';
      final placeholder = _attr(attrs, 'placeholder') ?? '';
      final label = _renderFormControl(type, value, placeholder, attrs);
      if (label.isNotEmpty) {
        blocks.add(_ContentBlock(type: _BlockType.formField, extra: label));
      }
    }
    // textarea
    for (final m in RegExp(r'<textarea[^>]*>(.*?)</textarea>',
            dotAll: true, caseSensitive: false)
        .allMatches(html)) {
      final text = _decodeEntities(_stripTags(m.group(1) ?? '')).trim();
      if (text.isNotEmpty) {
        blocks.add(_ContentBlock(
            type: _BlockType.formField, extra: '[ Textarea ]\n$text'));
      }
    }
    // select
    for (final m in RegExp(r'<select[^>]*>(.*?)</select>',
            dotAll: true, caseSensitive: false)
        .allMatches(html)) {
      final opts =
          RegExp(r'<option[^>]*>([^<]+)</option>', caseSensitive: false)
              .allMatches(m.group(1) ?? '')
              .map((o) => _decodeEntities(o.group(1) ?? ''))
              .join(' / ');
      if (opts.isNotEmpty) {
        blocks.add(_ContentBlock(
            type: _BlockType.formField, extra: '[ Select: $opts ]'));
      }
    }
    // button
    for (final m in RegExp(r'<button[^>]*>(.*?)</button>',
            dotAll: true, caseSensitive: false)
        .allMatches(html)) {
      final text = _decodeEntities(_stripTags(m.group(1) ?? '')).trim();
      if (text.isNotEmpty) {
        blocks.add(_ContentBlock(
            type: _BlockType.formField, extra: '[ Button: $text ]'));
      }
    }
  }

  static String _renderFormControl(
      String type, String value, String placeholder, String attrs) {
    switch (type.toLowerCase()) {
      case 'checkbox':
        final checked = attrs.contains('checked');
        return '${checked ? '☑' : '☐'}  ${value.isNotEmpty ? value : 'Checkbox'}';
      case 'radio':
        final checked = attrs.contains('checked');
        return '${checked ? '◉' : '○'}  ${value.isNotEmpty ? value : 'Radio'}';
      case 'submit':
        return '[ Submit: ${value.isNotEmpty ? value : 'Submit'} ]';
      case 'reset':
        return '[ Reset: ${value.isNotEmpty ? value : 'Reset'} ]';
      case 'button':
        return '[ Button: $value ]';
      case 'password':
        return '[ Password: ••••••• ]';
      default:
        if (value.isNotEmpty) return '[ $value ]';
        if (placeholder.isNotEmpty) return '[ $placeholder ]';
        return '';
    }
  }

  /// تحليل النصوص المضمّنة (bold, italic, underline, strikethrough, code, ...)
  static List<_TextSpan> _parseInlineSpans(String html, bool forceBold) {
    final spans = <_TextSpan>[];

    final pattern = RegExp(
      r'<(strong|b|em|i|u|s|del|ins|a|span|code|mark|small|big|sup|sub|'
      r'kbd|abbr|cite|q|dfn|bdi|bdo)\b([^>]*)>(.*?)</\1>|([^<]+)',
      dotAll: true,
      caseSensitive: false,
    );

    for (final m in pattern.allMatches(html)) {
      final tag = (m.group(1) ?? '').toLowerCase();
      final attrs = m.group(2) ?? '';
      final inner = m.group(3);
      final plain = m.group(4);

      if (plain != null) {
        final t = _decodeEntities(plain);
        if (t.trim().isNotEmpty) spans.add(_TextSpan(text: t, bold: forceBold));
        continue;
      }

      if (inner == null || tag.isEmpty) continue;
      final innerText = _decodeEntities(_stripTags(inner));
      if (innerText.isEmpty) continue;

      String? colorHex = _extractInlineColor(attrs, 'color');
      final isBold = forceBold ||
          tag == 'strong' ||
          tag == 'b' ||
          tag == 'mark' ||
          tag == 'kbd';
      final isItalic = tag == 'em' || tag == 'i' || tag == 'cite';
      final isUnderline = tag == 'u' || tag == 'ins' || tag == 'a';
      final isStrike = tag == 's' || tag == 'del';
      final isCode = tag == 'code' || tag == 'kbd';

      spans.add(_TextSpan(
        text: innerText,
        bold: isBold,
        italic: isItalic,
        underline: isUnderline,
        strikethrough: isStrike,
        code: isCode,
        colorHex: colorHex ?? (tag == 'a' ? '3182CE' : null),
        isLink: tag == 'a',
      ));
    }

    if (spans.isEmpty) {
      final t = _decodeEntities(_stripTags(html)).trim();
      if (t.isNotEmpty) spans.add(_TextSpan(text: t, bold: forceBold));
    }
    return spans;
  }

  /// يستخرج لون من inline style: color: #hex أو color: name
  static String? _extractInlineColor(String attrs, String prop) {
    final styleM =
        RegExp('style="([^"]*)"', caseSensitive: false).firstMatch(attrs);
    if (styleM == null) return null;
    final style = styleM.group(1) ?? '';

    // #RRGGBB أو #RGB
    final hexM = RegExp('$prop:\\s*#([0-9a-fA-F]{3,6})').firstMatch(style);
    if (hexM != null) {
      var h = hexM.group(1)!;
      if (h.length == 3) {
        h = '${h[0]}${h[0]}${h[1]}${h[1]}${h[2]}${h[2]}';
      }
      return h;
    }

    // اسم لوني شائع
    final nameM = RegExp('$prop:\\s*([a-zA-Z]+)').firstMatch(style);
    if (nameM != null) {
      return _namedColor(nameM.group(1)!.toLowerCase());
    }
    return null;
  }

  static String? _namedColor(String name) {
    const map = {
      'red': 'CC0000',
      'green': '228822',
      'blue': '0044CC',
      'black': '000000',
      'white': 'FFFFFF',
      'gray': '888888',
      'grey': '888888',
      'orange': 'E67300',
      'purple': '8B008B',
      'teal': '008080',
      'navy': '1E2761',
    };
    return map[name];
  }

  static _TextAlign _detectAlign(String tag) {
    final lc = tag.toLowerCase();
    if (lc.contains('text-align:center') ||
        lc.contains('text-align: center') ||
        lc.contains('align="center"')) {
      return _TextAlign.center;
    }
    if (lc.contains('text-align:right') ||
        lc.contains('text-align: right') ||
        lc.contains('align="right"')) {
      // ⚠️ إصلاح خلل حقيقي مؤكَّد على جهاز فعلي: "right" الصريحة في CSS
      // تعني محاذاة يمين مطلقة بصرف النظر عن اتجاه المستند، لا "end"
      // المرتبطة بالاتجاه (كانت end تُحسَب يمين في RTL ويسار في LTR —
      // ما يطابق "right" المطلقة فقط في حالة RTL، فيُكسَر السلوك في
      // فقرة إنجليزية LTR صريحة داخل مستند افتراضه RTL).
      return _TextAlign.right;
    }
    if (lc.contains('text-align:left') ||
        lc.contains('text-align: left') ||
        lc.contains('align="left"')) {
      // نفس الإصلاح: "left" الصريحة مطلقة دوماً، وليست "start" المرتبطة
      // بالاتجاه. هذا هو الخلل الذي رصده الاختبار الفعلي تحديداً: فقرة
      // "text-align:left" داخل مستند RTL كانت تُعرَض يمين الصفحة بدل
      // يسارها لأن _TextAlign.start كانت القيمة الافتراضية تماماً كما لو
      // لم تُحدَّد محاذاة صريحة إطلاقاً.
      return _TextAlign.left;
    }
    if (lc.contains('text-align:justify') ||
        lc.contains('text-align: justify')) {
      return _TextAlign.justify;
    }
    return _TextAlign.start;
  }

  static String? _attr(String html, String name) {
    final m = RegExp('$name="([^"]*)"', caseSensitive: false).firstMatch(html);
    return m?.group(1);
  }

  static String _stripTags(String html) =>
      html.replaceAll(RegExp(r'<[^>]+>'), ' ');

  static String _decodeEntities(String s) {
    return s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&mdash;', '—')
        .replaceAll('&ndash;', '–')
        .replaceAll('&laquo;', '«')
        .replaceAll('&raquo;', '»')
        .replaceAll('&hellip;', '…')
        .replaceAll('&copy;', '©')
        .replaceAll('&reg;', '®')
        .replaceAll('&trade;', '™')
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
          final code = int.tryParse(m.group(1) ?? '');
          return code != null ? String.fromCharCode(code) : m.group(0) ?? '';
        })
        .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
          final code = int.tryParse(m.group(1) ?? '', radix: 16);
          return code != null ? String.fromCharCode(code) : m.group(0) ?? '';
        })
        .replaceAll(RegExp(r'&[a-zA-Z]+;'), '')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  _mapBlocksToDocSpec — يستبدل _HtmlPdfWriter بالكامل
//  ─────────────────────────────────────────────────────────────────────
//  يحوّل List<_ContentBlock> (نتاج _parseHtml أعلاه، بلا أي تعديل) إلى
//  PdfDocSpec تصريحي. صفوف الجدول المتتالية (tableRow) تُجمَّع في جدول
//  PdfBlockTable واحد (نفس منطق تجميع _pendingTableRows/_flushTable
//  الأصلي)، وكل فقرة تُرسم بكل أنماط spans الفعلية (لا تبسيط إلى نمط
//  "غالب" واحد كما كان ضرورياً مع Syncfusion's drawString أحادي النمط).
// ═══════════════════════════════════════════════════════════════════════

PdfTextAlign _mapHtmlAlign(_TextAlign a, bool rtl) {
  switch (a) {
    case _TextAlign.center:
      return PdfTextAlign.center;
    case _TextAlign.justify:
      return PdfTextAlign.justify;
    case _TextAlign.left:
      return PdfTextAlign.left; // مطلقة دوماً — بصرف النظر عن اتجاه المستند
    case _TextAlign.right:
      return PdfTextAlign.right; // مطلقة دوماً — بصرف النظر عن اتجاه المستند
    case _TextAlign.end:
      return rtl ? PdfTextAlign.left : PdfTextAlign.right;
    case _TextAlign.start:
      return rtl ? PdfTextAlign.right : PdfTextAlign.left;
  }
}

int _htmlColorArgb(String? hex, {int fallback = 0xFF1E1E1E}) {
  if (hex == null) return fallback;
  var h = hex.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length != 6) return fallback;
  final v = int.tryParse(h, radix: 16);
  if (v == null) return fallback;
  return 0xFF000000 | v;
}

/// يحوّل قائمة spans فقرة واحدة إلى PdfTextRun بنفس نمط كل span الفعلي
/// (تحسين حقيقي عن _dominantSpan الأصلية التي كانت تفرض نمطاً واحداً على
/// كل الفقرة لقيد Syncfusion's drawString أحادي النمط لكل نداء).
List<PdfTextRun> _mapHtmlSpans(
    List<_TextSpan> spans, double baseFontSize, String family) {
  return [
    for (final s in spans)
      if (s.text.isNotEmpty)
        PdfTextRun(
          s.text,
          PdfFontSpec(
            family: family,
            sizePt: s.fontSize ?? baseFontSize,
            bold: s.bold,
            italic: s.italic,
            underline: s.underline,
            strikethrough: s.strikethrough,
            colorArgb: _htmlColorArgb(s.colorHex),
          ),
        ),
  ];
}

const List<int> _htmlHeadingColorsArgb = [
  0xFF1A202C,
  0xFF2D3748,
  0xFF4A5568,
  0xFF718096,
  0xFF718096,
  0xFF718096,
];
const List<double> _htmlHeadingSizes = [20, 16, 14, 12.5, 11.5, 11];
const List<double> _htmlHeadingSpaceBefore = [12, 10, 8, 6, 5, 4];
const List<double> _htmlHeadingSpaceAfter = [7, 6, 5, 4, 3, 2];

/// يحوّل كل الكتل إلى PdfDocSpec بصفحة واحدة متدفّقة (continuous flow،
/// مطابق لطبيعة HTML المستمرة)، مع جمع صفوف الجدول المتتالية في جدول
/// واحد (نفس آلية _pendingTableRows/_flushTable الأصلية).
PdfDocSpec _mapBlocksToDocSpec({
  required List<_ContentBlock> blocks,
  required HtmlConversionOptions options,
  required double pageW,
  required double pageH,
  required double marginH,
  required double marginV,
}) {
  final outBlocks = <PdfBlock>[];
  final pendingRows = <_ContentBlock>[];

  String family(bool rtl) => rtl ? 'NotoNaskhArabic' : 'LiberationSans';

  void flushTable() {
    if (pendingRows.isEmpty) return;
    // عدد الأعمدة الفعلي = أكبر مجموع colspans في أي صف (لا عدد الخلايا
    // الخام، لأن الخلايا لم تُوسَّع لفِلر بعد الإصلاح).
    int colCount = 0;
    for (final row in pendingRows) {
      final sum = row.tableColspans.isNotEmpty
          ? row.tableColspans.fold<int>(0, (a, b) => a + b)
          : row.tableCells.length;
      if (sum > colCount) colCount = sum;
    }
    if (colCount == 0) {
      pendingRows.clear();
      return;
    }
    final fs = options.baseFontSize - 0.5;
    final rows = <List<PdfTableCell>>[];
    for (final row in pendingRows) {
      final rowCells = <PdfTableCell>[];
      for (int ci = 0; ci < row.tableCells.length; ci++) {
        final spans = row.tableCells[ci];
        final text = spans.map((s) => s.text).join().trim();
        final isBold =
            row.isTableHeader || (spans.isNotEmpty && spans.first.bold);
        final colSpan =
            ci < row.tableColspans.length ? row.tableColspans[ci] : 1;
        final rowSpan =
            ci < row.tableRowSpans.length ? row.tableRowSpans[ci] : 1;
        rowCells.add(PdfTableCell(
          blocks: text.isEmpty
              ? const []
              : [
                  PdfBlockParagraph(
                    runs: [
                      PdfTextRun(
                        text,
                        PdfFontSpec(
                          family: family(row.rtl),
                          sizePt: fs,
                          bold: isBold,
                          colorArgb:
                              row.isTableHeader ? 0xFF1A202C : 0xFF1E1E1E,
                        ),
                      ),
                    ],
                    align: row.rtl ? PdfTextAlign.right : PdfTextAlign.left,
                    direction:
                        row.rtl ? PdfTextDirection.rtl : PdfTextDirection.ltr,
                  ),
                ],
          colSpan: colSpan,
          rowSpan: rowSpan,
          backgroundColorArgb: row.isTableHeader ? 0xFFEBF0FA : null,
          edgeBorders: const PdfCellEdgeBorders(
            top: PdfBorderSpec(0.5, 0xFFC8D2DC),
            bottom: PdfBorderSpec(0.5, 0xFFC8D2DC),
            left: PdfBorderSpec(0.5, 0xFFC8D2DC),
            right: PdfBorderSpec(0.5, 0xFFC8D2DC),
          ),
          paddingPt: 4.5,
        ));
      }
      rows.add(rowCells);
    }
    outBlocks.add(PdfBlockTable(
      rows: rows,
      direction:
          pendingRows.first.rtl ? PdfTextDirection.rtl : PdfTextDirection.ltr,
    ));
    outBlocks.add(const PdfBlockDivider(
        thicknessPt: 0, spaceBeforePt: 0, spaceAfterPt: 6));
    pendingRows.clear();
  }

  /// يغلّف نصاً في صندوق منسَّق (مستخدَم لحقول النماذج وSVG placeholder)
  /// عبر جدول 1×1 — نفس الحيلة المُستخدَمة في DOCX للفقرات المُظلَّلة.
  PdfBlock boxedText(
    String text, {
    required int bgArgb,
    required int borderArgb,
    required int textArgb,
    bool italic = false,
    PdfTextAlign align = PdfTextAlign.left,
    int? leftAccentArgb,
  }) {
        return PdfBlockTable(
      rows: [
        [
          PdfTableCell(
            blocks: [
              PdfBlockParagraph(
                runs: [

                  PdfTextRun(
                    text,
                    PdfFontSpec(
                      family: family(hasArabic(text)),
                      sizePt: options.baseFontSize - 0.5,
                      italic: italic,
                      colorArgb: textArgb,
                    ),
                  ),
                ],
                align: align,
              ),
            ],
            backgroundColorArgb: bgArgb,
            border:
                leftAccentArgb == null ? PdfBorderSpec(0.6, borderArgb) : null,
            edgeBorders: leftAccentArgb != null
                ? PdfCellEdgeBorders(
                    // شريط لوني سميك على اليسار (مطابق للشريط الزخرفي في
                    // _writeCodeBlock الأصلية: drawRectangle بعرض 3.5pt)،
                    // مع حدود رفيعة عادية على باقي الأطراف.
                    left: PdfBorderSpec(3.5, leftAccentArgb),
                    top: PdfBorderSpec(0.6, borderArgb),
                    bottom: PdfBorderSpec(0.6, borderArgb),
                    right: PdfBorderSpec(0.6, borderArgb),
                  )
                : null,
            paddingPt: 8,
          ),
        ],
      ],
    );
  }

  for (final block in blocks) {
    if (block.type != _BlockType.tableRow && pendingRows.isNotEmpty) {
      flushTable();
    }

    switch (block.type) {
      case _BlockType.heading:
        final lvl = block.headingLevel.clamp(1, 6);
        final text = block.spans.map((s) => s.text).join();
        if (text.trim().isEmpty) break;
        outBlocks.add(PdfBlockParagraph(
          runs: [
            PdfTextRun(
              text,
              PdfFontSpec(
                family: family(block.rtl),
                sizePt: _htmlHeadingSizes[lvl - 1],
                bold: true,
                colorArgb: _htmlHeadingColorsArgb[lvl - 1],
              ),
            ),
          ],
          align: _mapHtmlAlign(block.align, block.rtl),
          direction: block.rtl ? PdfTextDirection.rtl : PdfTextDirection.ltr,
          spaceBeforePt: _htmlHeadingSpaceBefore[lvl - 1],
          spaceAfterPt: _htmlHeadingSpaceAfter[lvl - 1],
        ));
        if (lvl <= 2) {
          outBlocks.add(PdfBlockDivider(
            thicknessPt: lvl == 1 ? 1.2 : 0.6,
            colorArgb: 0xFFB4B4B4,
            spaceBeforePt: 3,
            spaceAfterPt: 4,
          ));
        }

      case _BlockType.paragraph:
        if (block.spans.isEmpty) break;
        final text = block.spans.map((s) => s.text).join().trim();
        if (text.isEmpty) {
          outBlocks.add(const PdfBlockDivider(thicknessPt: 0, spaceAfterPt: 3));
          break;
        }
        outBlocks.add(PdfBlockParagraph(
          runs: _mapHtmlSpans(
              block.spans, options.baseFontSize, family(block.rtl)),
          align: _mapHtmlAlign(block.align, block.rtl),
          direction: block.rtl ? PdfTextDirection.rtl : PdfTextDirection.ltr,
          spaceAfterPt: 4,
          lineSpacingMultiplier: 1.3,
        ));

      case _BlockType.listItem:
        final text = block.spans.map((s) => s.text).join().trim();
        if (text.isEmpty) break;
        const bullets = ['\u2022', '\u25E6', '\u25AA'];
        final marker = block.isOrdered
            ? '${block.orderIndex}.'
            : bullets[block.listLevel % bullets.length];
        outBlocks.add(PdfBlockParagraph(
          runs: [
            PdfTextRun(
              text,
              PdfFontSpec(
                  family: family(block.rtl), sizePt: options.baseFontSize),
            ),
          ],
          align: block.rtl ? PdfTextAlign.right : PdfTextAlign.left,
          direction: block.rtl ? PdfTextDirection.rtl : PdfTextDirection.ltr,
          indentStartPt: 12.0 + block.listLevel * 14.0,
          listLevel: block.listLevel,
          listOrdered: block.isOrdered,
          listMarkerOverride: marker,
          spaceAfterPt: 3,
        ));

      case _BlockType.codeBlock:
        final text = block.spans.map((s) => s.text).join();
        if (text.trim().isEmpty) break;
        outBlocks.add(boxedText(
          text,
          bgArgb: 0xFFF1F5F9,
          borderArgb: 0xFFCBD5E1,
          textArgb: 0xFF1E1E3C,
          align: PdfTextAlign.left,
          leftAccentArgb: 0xFF38BDF8,
        ));
        outBlocks.add(const PdfBlockDivider(thicknessPt: 0, spaceAfterPt: 8));

      case _BlockType.tableRow:
        pendingRows.add(block);

      case _BlockType.divider:
        outBlocks.add(const PdfBlockDivider(
          thicknessPt: 0.7,
          colorArgb: 0xFFCBD5E1,
          spaceBeforePt: 5,
          spaceAfterPt: 9,
        ));

      case _BlockType.formField:
        final text = block.extra ?? '';
        if (text.isEmpty) break;
        outBlocks.add(boxedText(
          text,
          bgArgb: 0xFFF8FAFC,
          borderArgb: 0xFFCBD5E1,
          textArgb: 0xFF32465A,
        ));
        outBlocks.add(const PdfBlockDivider(thicknessPt: 0, spaceAfterPt: 6));

      case _BlockType.svgPlaceholder:
        final label = block.extra ?? 'SVG';
        outBlocks.add(boxedText(
          '[ $label ]',
          bgArgb: 0xFFF0F5FF,
          borderArgb: 0xFFB4BEDC,
          textArgb: 0xFF788CB4,
          italic: true,
          align: PdfTextAlign.center,
        ));
        outBlocks.add(const PdfBlockDivider(thicknessPt: 0, spaceAfterPt: 6));
    }
  }
  flushTable();

  return PdfDocSpec(
    pages: [
      PdfPageSpec(
        widthPt: pageW,
        heightPt: pageH,
        marginTopPt: marginV,
        marginBottomPt: marginV,
        marginLeftPt: marginH,
        marginRightPt: marginH,
        blocks: outBlocks,
      ),
    ],
    isPrecomposed: false,
  );
}
