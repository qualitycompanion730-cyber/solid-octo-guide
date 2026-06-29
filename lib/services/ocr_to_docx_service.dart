/// خدمة تصدير نتيجة OCR كملف DOCX قابل للتعديل في Word.
///
/// نقطة تفوق على Text Fairy: تطبيق Text Fairy لا يُصدّر DOCX إطلاقًا
/// (فقط نص عادي .txt أو HTML بسيط)، بينما هنا نُصدّر مستند Word منسّق
/// حقيقي يحافظ على فقرات منفصلة، واتجاه الكتابة الصحيح لكل فقرة
/// (RTL للعربية تلقائيًا، LTR للإنجليزية)، وحجم خط مقروء، بدل تفريغ
/// النص في صورة سطر واحد طويل بدون أي بنية.
///
/// آلية البناء: ملف DOCX هو أرشيف ZIP يحتوي عدة ملفات XML (انظر توثيق
/// OOXML). نبني هنا الحد الأدنى الضروري لمستند صالح: `[Content_Types].xml`،
/// `_rels/.rels`، `word/document.xml`، `word/_rels/document.xml.rels`.
/// كل فقرة OCR تتحول إلى عنصر `w:p` مستقل، مع `w:bidi` و `w:rtl` على
/// مستوى الفقرة/التشغيلة إن كانت عربية، بما يتوافق مع معيار OOXML
/// لتحديد اتجاه الفقرة (نفس الآلية المستخدمة في باقي محرك PDF Master
/// لمحوّلات DOCX، لكن هنا بالاتجاه المعكوس: من نص خام إلى DOCX بدل العكس).
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

import '../models/ocr_result_model.dart';

class OcrToDocxService {
  /// يبني ملف DOCX من نتيجة OCR كاملة، فقرة لكل سطر مكتشف (مع تجميع
  /// أسطر الكتلة الواحدة كفقرة واحدة متعددة الأسطر إن رغب المستخدم،
  /// والافتراضي هنا فقرة لكل كتلة OCR وليس لكل سطر، لمحاكاة بنية
  /// الفقرات الطبيعية في المستند الأصلي بدل تكسير كل سطر بصري كفقرة).
  static Future<File> build(
    OcrDocumentResult document, {
    String? outputFileName,
  }) async {
    final paragraphsXml = StringBuffer();

    for (int pageIndex = 0; pageIndex < document.pages.length; pageIndex++) {
      final page = document.pages[pageIndex];

      for (final block in page.blocks) {
        final blockIsRtl = _isBlockPredominantlyRtl(block);
        final blockText = block.lines.map((l) => l.readingOrderText).join('\n');
        paragraphsXml.write(_buildParagraphXml(blockText, isRtl: blockIsRtl));
      }

      // فاصل صفحة بعد كل صفحة من المصدر (إلا الأخيرة)، حتى يحافظ
      // المستند على نفس تقسيم الصفحات الأصلي في حالة PDF متعدد الصفحات.
      if (pageIndex < document.pages.length - 1) {
        paragraphsXml.write(_pageBreakParagraphXml());
      }
    }

    final documentXml = _wrapDocumentXml(paragraphsXml.toString());

    final archive = Archive();
    archive.addFile(_textArchiveFile('[Content_Types].xml', _contentTypesXml));
    archive.addFile(_textArchiveFile('_rels/.rels', _rootRelsXml));
    archive.addFile(_textArchiveFile('word/_rels/document.xml.rels', _documentRelsXml));
    archive.addFile(_textArchiveFile('word/document.xml', documentXml));

    // ⚠️ ZipEncoder().encode(archive) يُعيد List<int>? (قد يفشل الترميز
    // ويُرجع null نظرياً)، بينما File.writeAsBytes تتطلب List<int> غير
    // nullable. نتحقق صريحاً بدل استخدام "!" غير الآمن.
    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null) {
      throw const OcrDocxBuildException('فشل ترميز أرشيف DOCX (ZipEncoder أعاد قيمة فارغة).');
    }

    final outputDir = await getTemporaryDirectory();
    final fileName = outputFileName ?? '${document.suggestedTitle}.docx';
    final outputFile = File('${outputDir.path}/$fileName');
    await outputFile.writeAsBytes(zipBytes, flush: true);

    return outputFile;
  }

  static bool _isBlockPredominantlyRtl(OcrBlock block) {
    final rtlLines = block.lines.where((l) => l.direction == OcrTextDirection.rtl).length;
    return rtlLines >= block.lines.length / 2;
  }

  static ArchiveFile _textArchiveFile(String path, String content) {
    final bytes = utf8.encode(content);
    return ArchiveFile(path, bytes.length, bytes);
  }

  /// يبني عنصر فقرة `w:p` واحد، مع تقسيم النص على أسطر داخلية بعلامة
  /// `w:br` بدل فقرات متعددة، حتى تبقى الكتلة الواحدة فقرة منطقية
  /// واحدة في Word (قابلة للتنسيق ككل لاحقًا من قبل المستخدم).
  static String _buildParagraphXml(String text, {required bool isRtl}) {
    final bidiTag = isRtl ? '<w:bidi/>' : '';
    final rtlRunTag = isRtl ? '<w:rtl/>' : '';
    final lines = text.split('\n');

    final runsXml = StringBuffer();
    for (int i = 0; i < lines.length; i++) {
      final escaped = _escapeXml(lines[i]);
      runsXml.write(
        '<w:r><w:rPr>$rtlRunTag</w:rPr><w:t xml:space="preserve">$escaped</w:t></w:r>',
      );
      if (i < lines.length - 1) {
        runsXml.write('<w:r><w:br/></w:r>');
      }
    }

    return '<w:p><w:pPr>$bidiTag<w:jc w:val="${isRtl ? 'right' : 'left'}"/></w:pPr>$runsXml</w:p>';
  }

  static String _pageBreakParagraphXml() {
    return '<w:p><w:r><w:br w:type="page"/></w:r></w:p>';
  }

  static String _escapeXml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static String _wrapDocumentXml(String bodyParagraphs) {
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    $bodyParagraphs
    <w:sectPr/>
  </w:body>
</w:document>''';
  }

  static const String _contentTypesXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''';

  static const String _rootRelsXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''';

  static const String _documentRelsXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
</Relationships>''';
}

class OcrDocxBuildException implements Exception {
  final String message;
  const OcrDocxBuildException(this.message);
  @override
  String toString() => message;
}
