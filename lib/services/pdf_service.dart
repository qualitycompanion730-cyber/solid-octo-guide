import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

// ─────────────────────────────────────────────
//  PdfService — جميع عمليات إنشاء PDF
//  يعمل في Isolate منفصل لضمان أداء سلس
// ─────────────────────────────────────────────
class PdfService {
  PdfService._(); // singleton منع إنشاء كائنات

  // ───── واجهة عامة ─────

  /// تحويل صورة واحدة → PDF
  static Future<File> imageToPdf(String imagePath) =>
      imagesToPdf([imagePath]);

  /// تحويل قائمة صور → PDF مع إعدادات كاملة
  static Future<File> imagesToPdf(
    List<String> imagePaths, {
    String quality = 'high',
    String pageSize = 'A4',
    String pageOrientation = 'auto',
    int imagesPerPage = 1,
    String outputName = '',
  }) async {
    if (imagePaths.isEmpty) {
      throw ArgumentError('لا توجد صور لتحويلها.');
    }

    final Directory tmpDir = await getTemporaryDirectory();
    if (!tmpDir.existsSync()) tmpDir.createSync(recursive: true);

    final String fileName = outputName.isNotEmpty
        ? '${outputName.replaceAll(RegExp(r'[^\w\u0600-\u06FF]'), '_')}.pdf'
        : 'pdf_${DateTime.now().millisecondsSinceEpoch}.pdf';

    final params = _PdfParams(
      imagePaths: imagePaths,
      quality: quality,
      pageSize: pageSize,
      pageOrientation: pageOrientation,
      imagesPerPage: imagesPerPage,
      outputPath: '${tmpDir.path}/$fileName',
    );

    final String path = await compute(_buildPdf, params);

    final File result = File(path);
    if (!result.existsSync() || result.lengthSync() == 0) {
      throw Exception('فشل إنشاء ملف PDF في: $path');
    }
    return result;
  }

  // ───── Isolate worker ─────

  static Future<String> _buildPdf(_PdfParams p) async {
    final pdf = PdfDocument();
    try {
      pdf.pageSettings.margins.all = 0;
      _applyPageSettings(pdf, p.pageSize, p.pageOrientation);
      pdf.compressionLevel = _compressionLevel(p.quality);

      int rendered = 0;
      for (int i = 0; i < p.imagePaths.length; i += p.imagesPerPage) {
        final end = min(i + p.imagesPerPage, p.imagePaths.length);
        final batch = p.imagePaths.sublist(i, end);
        final page = pdf.pages.add();
        rendered +=
            _renderBatch(page, batch, page.getClientSize(), p.imagesPerPage);
      }

      if (pdf.pages.count == 0) throw Exception('لم يتم إضافة أي صفحة.');

      // إصلاح: الفحص القديم (pages.count == 0) لا يكتشف الحالة التي تفشل
      // فيها كل الصور بصمت (كل صورة بصيغة غير مدعومة أو تالفة) — كانت
      // الصفحات تُضاف بأي حال (page = pdf.pages.add() يحدث قبل محاولة رسم
      // الصورة)، فيخرج المستخدم بملف PDF صفحاته فارغة تماماً دون أي خطأ
      // يوضّح له السبب.
      if (rendered == 0) {
        throw Exception(
            'تعذّر رسم أي صورة — تأكد أن الصور بصيغة JPEG أو PNG صحيحة.');
      }

      final bytes = pdf.saveSync();
      final file = File(p.outputPath);
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes, flush: true);
      return file.path;
    } catch (e) {
      debugPrint('[PdfService] خطأ: $e');
      rethrow;
    } finally {
      pdf.dispose();
    }
  }

  // ───── مساعدات ─────

  static PdfCompressionLevel _compressionLevel(String q) {
    switch (q) {
      case 'low':
        return PdfCompressionLevel.bestSpeed;
      case 'medium':
        return PdfCompressionLevel.normal;
      default:
        return PdfCompressionLevel.best;
    }
  }

  static void _applyPageSettings(
      PdfDocument pdf, String size, String orientation) {
    double w, h;
    switch (size) {
      case 'Letter':
        w = 612;
        h = 792;
        break;
      case 'Legal':
        w = 612;
        h = 1008;
        break;
      default: // A4
        w = 595;
        h = 842;
    }
    if (orientation == 'landscape') {
      pdf.pageSettings.size = Size(h, w);
    } else if (orientation == 'portrait') {
      pdf.pageSettings.size = Size(w, h);
    }
    // 'auto' → حجم افتراضي حسب أول صورة (يُترك كما هو)
  }

  /// يرسم دُفعة من الصور على صفحة واحدة، ويُعيد عدد الصور التي نجح رسمها
  /// فعلياً (لتمييز "صفحة فيها صورة فعلاً" عن "صفحة فارغة بسبب صور تالفة").
  static int _renderBatch(
      PdfPage page, List<String> paths, Size pageSize, int perPage) {
    if (paths.isEmpty) return 0;
    int ok = 0;
    switch (perPage) {
      case 1:
        if (_fitImage(page, paths[0],
            Rect.fromLTWH(0, 0, pageSize.width, pageSize.height))) {
          ok++;
        }
        break;
      case 2:
        final half = pageSize.height / 2;
        if (_fitImage(
            page, paths[0], Rect.fromLTWH(0, 0, pageSize.width, half))) {
          ok++;
        }
        if (paths.length > 1) {
          if (_fitImage(page, paths[1],
              Rect.fromLTWH(0, half, pageSize.width, half))) {
            ok++;
          }
        }
        break;
      case 4:
        final hw = pageSize.width / 2, hh = pageSize.height / 2;
        final rects = [
          Rect.fromLTWH(0, 0, hw, hh),
          Rect.fromLTWH(hw, 0, hw, hh),
          Rect.fromLTWH(0, hh, hw, hh),
          Rect.fromLTWH(hw, hh, hw, hh),
        ];
        for (int i = 0; i < paths.length && i < rects.length; i++) {
          if (_fitImage(page, paths[i], rects[i])) ok++;
        }
        break;
      default:
        // إصلاح: كانت هذه الحالة (أي قيمة perPage غير 1/2/4) ترسم الصورة
        // الأولى من الدُفعة فقط وتتجاهل بقيتها بصمت — فقدان بيانات كامن لو
        // استُدعيت هذه الدالة بقيمة أخرى مستقبلاً (الواجهة الحالية تعرض
        // فقط 1/2/4 فهذا المسار غير مُفعَّل اليوم عملياً، لكنه كان فخاً
        // كامناً في كود عام static يمكن استدعاؤه من أي مكان مستقبلاً).
        // الآن نحسب شبكة عامة تتسع لأي عدد من الصور دون فقدان أي منها.
        final cols = sqrt(paths.length).ceil();
        final rows = (paths.length / cols).ceil();
        final cw = pageSize.width / cols;
        final ch = pageSize.height / rows;
        for (int i = 0; i < paths.length; i++) {
          final col = i % cols;
          final row = i ~/ cols;
          if (_fitImage(
              page, paths[i], Rect.fromLTWH(col * cw, row * ch, cw, ch))) {
            ok++;
          }
        }
    }
    return ok;
  }

  /// رسم صورة داخل إطار مع الحفاظ على النسبة (letterbox). يُعيد true عند
  /// النجاح، false عند فشل قراءة/فك الصورة (بدون تعطيل بقية التحويل).
  static bool _fitImage(PdfPage page, String path, Rect frame) {
    try {
      final f = File(path);
      if (!f.existsSync()) return false;
      final bytes = f.readAsBytesSync();
      final bmp = PdfBitmap(bytes);

      final ratio = min(frame.width / bmp.width, frame.height / bmp.height);
      final dw = bmp.width * ratio;
      final dh = bmp.height * ratio;
      final dx = frame.left + (frame.width - dw) / 2;
      final dy = frame.top + (frame.height - dh) / 2;

      page.graphics.drawImage(bmp, Rect.fromLTWH(dx, dy, dw, dh));
      return true;
    } catch (e) {
      // إصلاح: صورة تالفة أو بصيغة لا يدعمها PdfBitmap (يقبل PNG/JPEG فقط)
      // كانت تُسقط التحويل بالكامل حتى لو كانت بقية الصور في الدُفعة
      // سليمة. الآن نتجاهل هذه الصورة فقط ونستمر بباقي الصفحة/الدُفعة.
      debugPrint('[PdfService] تعذّر رسم الصورة $path: $e');
      return false;
    }
  }
}

// ─────────────────────────────────────────────
//  نموذج معاملات الـ Isolate (قابل للتمرير)
// ─────────────────────────────────────────────
class _PdfParams {
  final List<String> imagePaths;
  final String quality;
  final String pageSize;
  final String pageOrientation;
  final int imagesPerPage;
  final String outputPath;

  const _PdfParams({
    required this.imagePaths,
    required this.quality,
    required this.pageSize,
    required this.pageOrientation,
    required this.imagesPerPage,
    required this.outputPath,
  });
}
