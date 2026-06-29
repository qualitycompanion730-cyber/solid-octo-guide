// txt_to_pdf_converter.dart — يرسم عبر الجسر الأصلي لأندرويد
//
// ── ملخص إعادة البناء ──────────────────────────────────────────────────
// • المحلِّل (_parseText: اكتشاف العناوين/النقاط/الفقرات من نص خام) لم
//   يتغيّر إطلاقاً — منطق بحت لا علاقة له بمحرك الرسم.
// • حُذف بالكامل: _TxtPdfWriter (رسم Syncfusion المباشر).
// • أُضيف: _mapBlocksToDocSpec(...) يحوّل List<_ContentBlock> إلى
//   PdfDocSpec تصريحي.
// • تحميل الخطوط: parseToLayout() تستقبل preloadedFonts جاهزة (محمَّلة في
//   Main Isolate) بدل استدعاء rootBundle مباشرة — هذا الملف، كـ
//   html_to_pdf_converter.dart، لم يكن مُغلَّفاً بـ Isolate من قبل، فكان
//   التحويل يُجمِّد واجهة المستخدم على ملفات نصية كبيرة.

import '../pdf_engine/pdf_layout_model.dart';
import 'shared/arabic_text_utils.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  واجهة عامة
// ─────────────────────────────────────────────────────────────────────────────

class TxtConversionProgress {
  final double progress;
  final String stage;
  const TxtConversionProgress(this.progress, this.stage);
}

class TxtCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class TxtConversionException implements Exception {
  final String message;
  const TxtConversionException(this.message);
  @override
  String toString() => message;
}

class TxtCancelledException implements Exception {
  const TxtCancelledException();
  @override
  String toString() => 'تم إلغاء التحويل';
}

// ─────────────────────────────────────────────────────────────────────────────
//  خيارات التحويل
// ─────────────────────────────────────────────────────────────────────────────

enum TxtPageSize { a4, a5, letter, legal }

class TxtConversionOptions {
  final TxtPageSize pageSize;
  final bool rtl; // الاتجاه الافتراضي عند غياب حروف عربية/لاتينية واضحة
  final double baseFontSize;
  final double lineSpacing; // 1.0 طبيعي، 1.5 موسّع...
  final bool detectBullets; // "- "/"* "/"• " → نقطة قائمة منسّقة
  final bool detectHeadings; // سطر قصير محاط بسطر فارغ → عنوان بخط أكبر

  const TxtConversionOptions({
    this.pageSize = TxtPageSize.a4,
    this.rtl = true,
    this.baseFontSize = 12,
    this.lineSpacing = 1.5,
    this.detectBullets = true,
    this.detectHeadings = true,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
//  نماذج البلوكات الداخلية
// ─────────────────────────────────────────────────────────────────────────────

enum _BlockType { heading, paragraph, listItem, blank }

class _ContentBlock {
  final _BlockType type;
  final String text;
  final bool rtl;
  const _ContentBlock(
      {required this.type, required this.text, required this.rtl});
}

// ─────────────────────────────────────────────────────────────────────────────
//  المحوّل الرئيسي
// ─────────────────────────────────────────────────────────────────────────────

class TxtToPdfConverter {
  TxtToPdfConverter._();

  /// يحلّل نصاً خاماً ويُعيد PdfDocSpec — نموذج تخطيط تصريحي بلا أي PDF
  /// مُولَّد بعد. لا يستدعي rootBundle أو أي MethodChannel، فهو آمن
  /// للاستدعاء من Worker Isolate.
  static Future<PdfDocSpec> parseToLayout(
    String textContent, {
    TxtConversionOptions options = const TxtConversionOptions(),
    void Function(TxtConversionProgress)? onProgress,
    TxtCancelToken? cancelToken,
  }) async {
    void report(double p, String stage) {
      if (cancelToken?.isCancelled != true) {
        onProgress?.call(TxtConversionProgress(p, stage));
      }
    }

    void checkCancelled() {
      if (cancelToken?.isCancelled == true) {
        throw const TxtCancelledException();
      }
    }

    report(0.05, 'التحقق من المحتوى...');
    if (textContent.trim().isEmpty) {
      throw const TxtConversionException('الملف النصي فارغ');
    }
    checkCancelled();

    report(0.3, 'تحليل النص...');
    final blocks = _parseText(textContent, options);
    checkCancelled();

    report(0.6, 'تجهيز التخطيط...');
    final (pgW, pgH) = _pageDims(options.pageSize);
    const marginH = 44.0;
    const marginV = 52.0;

    final spec = _mapBlocksToDocSpec(
      blocks: blocks,
      options: options,
      pageW: pgW,
      pageH: pgH,
      marginH: marginH,
      marginV: marginV,
    );

    report(0.75, 'اكتمل تجهيز التخطيط');
    return spec;
  }

  static (double, double) _pageDims(TxtPageSize size) {
    switch (size) {
      case TxtPageSize.a5:
        return (419.53, 595.28);
      case TxtPageSize.letter:
        return (612.0, 792.0);
      case TxtPageSize.legal:
        return (612.0, 1008.0);
      case TxtPageSize.a4:
      // ignore: unreachable_switch_default
      default:
        return (595.28, 841.89);
    }
  }

  

  // ─────────────────────────────────────────────────────────────────────────
  //  محلّل النص — يحوّل الأسطر الخام إلى بلوكات (عنوان/فقرة/نقطة/سطر فارغ)
  // ─────────────────────────────────────────────────────────────────────────

  static final _bulletRe = RegExp(r'^\s*([-*•●▪])\s+(.*)$');
  static final _sentenceEndRe = RegExp(r'[.!؟?,،؛:]$');

  static List<_ContentBlock> _parseText(
      String raw, TxtConversionOptions options) {
    final normalized = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');

    final blocks = <_ContentBlock>[];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();

      if (trimmed.isEmpty) {
        blocks
            .add(const _ContentBlock(type: _BlockType.blank, text: '', rtl: false));
        continue;
      }

      final rtl = hasArabic(trimmed) || (!hasLatin(trimmed) && options.rtl);

      // نقطة قائمة
      if (options.detectBullets) {
        final bm = _bulletRe.firstMatch(line);
        if (bm != null && bm.group(2)!.trim().isNotEmpty) {
          blocks.add(_ContentBlock(
              type: _BlockType.listItem, text: bm.group(2)!.trim(), rtl: rtl));
          continue;
        }
      }

      // عنوان: سطر قصير محاط بسطر فارغ (أو حافة الملف) ولا ينتهي بعلامة جملة
      if (options.detectHeadings && trimmed.length <= 70) {
        final prevBlank = i == 0 || lines[i - 1].trim().isEmpty;
        final nextBlank = i == lines.length - 1 || lines[i + 1].trim().isEmpty;
        if (prevBlank && nextBlank && !_sentenceEndRe.hasMatch(trimmed)) {
          blocks
              .add(_ContentBlock(type: _BlockType.heading, text: trimmed, rtl: rtl));
          continue;
        }
      }

      blocks.add(_ContentBlock(type: _BlockType.paragraph, text: trimmed, rtl: rtl));
    }

    return blocks;
  }
}



// ═══════════════════════════════════════════════════════════════════════
//  _mapBlocksToDocSpec — يستبدل _TxtPdfWriter بالكامل
//  ─────────────────────────────────────────────────────────────────────
//  يحوّل List<_ContentBlock> (نتاج _parseText أعلاه، بلا أي تعديل) إلى
//  PdfDocSpec تصريحي بصفحة واحدة متدفّقة (التجزئة الفعلية لصفحات PDF
//  تحدث داخل الجسر الأصلي بعد القياس الحقيقي بـ StaticLayout).
// ═══════════════════════════════════════════════════════════════════════

PdfDocSpec _mapBlocksToDocSpec({
  required List<_ContentBlock> blocks,
  required TxtConversionOptions options,
  required double pageW,
  required double pageH,
  required double marginH,
  required double marginV,
}) {
  final outBlocks = <PdfBlock>[];
  final lineSpacingMultiplier = options.lineSpacing;

  for (final block in blocks) {
    switch (block.type) {
      case _BlockType.blank:
        outBlocks.add(PdfBlockDivider(
          thicknessPt: 0,
          spaceAfterPt: options.baseFontSize * 0.6,
        ));

      case _BlockType.heading:
        outBlocks.add(PdfBlockParagraph(
          runs: [
            PdfTextRun(
              block.text,
              PdfFontSpec(
                family: block.rtl ? 'NotoNaskhArabic' : 'LiberationSans',
                sizePt: options.baseFontSize + 3,
                bold: true,
                colorArgb: 0xFF121226,
              ),
            ),
          ],
          align: block.rtl ? PdfTextAlign.right : PdfTextAlign.left,
          direction: block.rtl ? PdfTextDirection.rtl : PdfTextDirection.ltr,
          spaceBeforePt: 6,
          spaceAfterPt: 9,
        ));

      case _BlockType.listItem:
        outBlocks.add(PdfBlockParagraph(
          runs: [
            PdfTextRun(
              block.text,
              PdfFontSpec(
                family: block.rtl ? 'NotoNaskhArabic' : 'LiberationSans',
                sizePt: options.baseFontSize,
                colorArgb: 0xFF1A1A2E,
              ),
            ),
          ],
          align: block.rtl ? PdfTextAlign.right : PdfTextAlign.left,
          direction: block.rtl ? PdfTextDirection.rtl : PdfTextDirection.ltr,
          indentStartPt: 16.0,
          listLevel: 0,
          listOrdered: false,
          listMarkerOverride: '\u2022',
          lineSpacingMultiplier: lineSpacingMultiplier,
          spaceAfterPt: 3,
        ));

      case _BlockType.paragraph:
        outBlocks.add(PdfBlockParagraph(
          runs: [
            PdfTextRun(
              block.text,
              PdfFontSpec(
                family: block.rtl ? 'NotoNaskhArabic' : 'LiberationSans',
                sizePt: options.baseFontSize,
                colorArgb: 0xFF1A1A2E,
              ),
            ),
          ],
          align: block.rtl ? PdfTextAlign.right : PdfTextAlign.left,
          direction: block.rtl ? PdfTextDirection.rtl : PdfTextDirection.ltr,
          lineSpacingMultiplier: lineSpacingMultiplier,
          spaceAfterPt: 4,
        ));
    }
  }

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
