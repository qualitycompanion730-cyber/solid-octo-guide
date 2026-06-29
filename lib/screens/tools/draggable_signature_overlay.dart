// ═══════════════════════════════════════════════════════════════════════════
//  DraggableSignatureOverlay — التوقيع كعنصر حر فوق صورة صفحة PDF
// ═══════════════════════════════════════════════════════════════════════════
//
//  هذا الـ widget يمثّل الفرق الجوهري عن التصميم القديم (الذي كان يطلب من
//  المستخدم اختيار "موضع جاهز" من 3 خيارات ثم يعرض معاينة منفصلة). هنا
//  التوقيع نفسه عنصر مرئي قابل للسحب بإصبع واحدة وللتحجيم بإصبعين
//  (GestureDetector مع onScaleStart/Update يدعم كلا الإيماءتين معاً —
//  وهذا أسلوب Flutter القياسي حين نحتاج Pan + Scale من نفس المؤشر).
//
//  نظام الإحداثيات المُستخدَم:
//  كل القياسات (موضع/حجم) تُخزَّن كنسبة 0.0–1.0 من حجم الصفحة المعروضة
//  (وليس بالبكسل المطلق)، لأن:
//  - الصورة المعروضة قد تتغيّر دقتها (pixelRatio) دون أن يتغيّر موضع
//    التوقيع منطقياً.
//  - هذه النسبة هي ما يُضرَب مباشرة في pageWidthPt/pageHeightPt الحقيقيين
//    عند الرسم النهائي بـ Syncfusion — تطابق رياضي مباشر بلا أي تحويل
//    وحدات وسيط.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:typed_data';

import 'package:flutter/material.dart';

/// تمثيل موضع/حجم التوقيع كنسب من حجم الصفحة (0.0–1.0)، مستقل تماماً عن
/// حجم الشاشة الذي يُعرَض عليه — هذا ما يُمرَّر لاحقاً لمنطق الرسم النهائي.
class SignaturePlacement {
  /// نسبة إزاحة الزاوية العلوية اليسرى للتوقيع من عرض/ارتفاع الصفحة.
  final double xRatio;
  final double yRatio;

  /// نسبة عرض التوقيع من عرض الصفحة (الارتفاع يُحسَب من aspectRatio
  /// الأصلي للتوقيع، فلا تُخزَّن نسبة ارتفاع مستقلة لتفادي تمديد الصورة).
  final double widthRatio;

  const SignaturePlacement({
    required this.xRatio,
    required this.yRatio,
    required this.widthRatio,
  });

  SignaturePlacement copyWith({double? xRatio, double? yRatio, double? widthRatio}) {
    return SignaturePlacement(
      xRatio: xRatio ?? this.xRatio,
      yRatio: yRatio ?? this.yRatio,
      widthRatio: widthRatio ?? this.widthRatio,
    );
  }
}

class DraggableSignatureOverlay extends StatefulWidget {
  /// حجم الصفحة المنطقي (logical pixels) كما تُعرَض فعلياً على الشاشة —
  /// هذا هو "نظام الإحداثيات" الذي تُحسَب كل النسب بداخله.
  final Size pageDisplaySize;

  /// صورة التوقيع (بايتات PNG شفافة الخلفية) ونسبة عرضها/ارتفاعها الأصلية،
  /// لضمان عدم تمديد/تفليش الصورة عند تغيير حجمها.
  final Uint8List signatureBytes;
  final double signatureAspectRatio;

  final SignaturePlacement initialPlacement;
  final ValueChanged<SignaturePlacement> onPlacementChanged;

  /// لون حدّ التمييز حول التوقيع أثناء التحرير (لإعطاء إحساساً بأنه عنصر
  /// تفاعلي قابل للضبط، أسلوب متّبع في Adobe Fill & Sign وDocuSign).
  final Color accentColor;

  const DraggableSignatureOverlay({
    super.key,
    required this.pageDisplaySize,
    required this.signatureBytes,
    required this.signatureAspectRatio,
    required this.initialPlacement,
    required this.onPlacementChanged,
    required this.accentColor,
  });

  @override
  State<DraggableSignatureOverlay> createState() => _DraggableSignatureOverlayState();
}

class _DraggableSignatureOverlayState extends State<DraggableSignatureOverlay> {
  late SignaturePlacement _placement;

  // نخزّن نقطة/حجم البداية عند بدء إيماءة السحب/التحجيم، لحساب الفرق
  // التراكمي بدلاً من الفرق اللحظي بين كل عيّنة من onScaleUpdate — أكثر
  // استقراراً ويفادي انجراف الموضع مع الإيماءات السريعة.
  SignaturePlacement? _placementAtGestureStart;

  @override
  void initState() {
    super.initState();
    _placement = widget.initialPlacement;
  }

  @override
  void didUpdateWidget(covariant DraggableSignatureOverlay old) {
    super.didUpdateWidget(old);
    // إن غيّر المستدعي initialPlacement من الخارج (مثل إعادة ضبط الموضع
    // الافتراضي عند تبديل الصفحة)، نتبع القيمة الجديدة بدل التمسك بالحالة
    // الداخلية القديمة.
    if (old.initialPlacement != widget.initialPlacement) {
      _placement = widget.initialPlacement;
    }
  }

  double get _widthPx => _placement.widthRatio * widget.pageDisplaySize.width;
  double get _heightPx => _widthPx / widget.signatureAspectRatio;
  double get _xPx => _placement.xRatio * widget.pageDisplaySize.width;
  double get _yPx => _placement.yRatio * widget.pageDisplaySize.height;

  void _emitChange(SignaturePlacement next) {
    // نُقيّد الموضع ليبقى التوقيع (أو جزء معقول منه) داخل حدود الصفحة،
    // بدل السماح بسحبه خارجها بالكامل وفقدانه عن العين.
    //
    // ⚠️ heightRatio (نسبة ارتفاع التوقيع من ارتفاع *الصفحة*، لا من عرضها)
    // يجب أن يأخذ بعين الاعتبار نسبة عرض/ارتفاع الصفحة نفسها، وليس فقط
    // aspectRatio الخاص بالتوقيع — لأن widthRatio مقيسة نسبة لعرض الصفحة
    // بينما الارتفاع الناتج (بالبكسل الحقيقي) يُقاس نسبة لارتفاع الصفحة.
    // الصيغة: heightPx = widthPx / sigAspect = (widthRatio * pageW) / sigAspect
    // heightRatio = heightPx / pageH = widthRatio * (pageW/pageH) / sigAspect
    final pageAspect =
        widget.pageDisplaySize.width / widget.pageDisplaySize.height;
    double heightRatioOf(double widthRatio) =>
        widthRatio * pageAspect / widget.signatureAspectRatio;

    final maxX = 1.0 - (next.widthRatio * 0.15);
    final maxY = 1.0 - (heightRatioOf(next.widthRatio) * 0.15);
    final clamped = next.copyWith(
      xRatio: next.xRatio.clamp(-(next.widthRatio * 0.85), maxX),
      yRatio:
          next.yRatio.clamp(-(heightRatioOf(next.widthRatio) * 0.85), maxY),
      widthRatio: next.widthRatio.clamp(0.08, 0.9),
    );
    setState(() => _placement = clamped);
    widget.onPlacementChanged(clamped);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: _xPx,
      top: _yPx,
      width: _widthPx,
      height: _heightPx,
      child: GestureDetector(
        onScaleStart: (_) {
          _placementAtGestureStart = _placement;
        },
        onScaleUpdate: (details) {
          final start = _placementAtGestureStart;
          if (start == null) return;
          // details.scale تراكمي تلقائياً من Flutter منذ onScaleStart، لذا
          // نضربه في widthRatio الثابتة عند بدء الإيماءة (start) للحصول
          // على القياس الصحيح في كل لحظة، دون تراكم يدوي.
          // أما focalPointDelta فهو فرق لحظي بين عيّنتين متتاليتين فقط
          // (غير تراكمي)، فنضيفه فوق _placement الحالية (آخر موضع مُحدَّث
          // فعلياً)، لا فوق start الثابتة — وهذا هو السلوك الصحيح لإزاحة
          // تتبع حركة الإصبع لحظة بلحظة.
          final newWidthRatio = (start.widthRatio * details.scale)
              .clamp(0.08, 0.9);
          final dx = details.focalPointDelta.dx / widget.pageDisplaySize.width;
          final dy = details.focalPointDelta.dy / widget.pageDisplaySize.height;
          _emitChange(_placement.copyWith(
            xRatio: _placement.xRatio + dx,
            yRatio: _placement.yRatio + dy,
            widthRatio: newWidthRatio,
          ));
        },
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: widget.accentColor, width: 1.5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Image.memory(widget.signatureBytes, fit: BoxFit.contain),
                ),
              ),
              // مقبض تحجيم صريح في الزاوية، إضافة لدعم onScaleUpdate
              // التلقائي بإصبعين — بعض المستخدمين يتوقعون مقبضاً مرئياً
              // (نمط شائع في DocuSign) حتى لو كانت إيماءة القرص تعمل أصلاً.
              Positioned(
                right: -10,
                bottom: -10,
                child: GestureDetector(
                  onPanStart: (_) {
                    _placementAtGestureStart = _placement;
                  },
                  onPanUpdate: (details) {
                    final dx = details.delta.dx / widget.pageDisplaySize.width;
                    final newWidthRatio =
                        (_placement.widthRatio + dx).clamp(0.08, 0.9);
                    _emitChange(_placement.copyWith(widthRatio: newWidthRatio));
                  },
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.accentColor,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: const [
                        BoxShadow(color: Colors.black26, blurRadius: 4),
                      ],
                    ),
                    child: const Icon(Icons.open_in_full_rounded,
                        size: 12, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
