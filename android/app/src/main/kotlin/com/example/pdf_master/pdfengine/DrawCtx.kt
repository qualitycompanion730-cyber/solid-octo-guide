package com.example.pdf_master.pdfengine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.text.TextPaint

// ═══════════════════════════════════════════════════════════════════════
//  DrawCtx.kt
//  ─────────────────────────────────────────────────────────────────────
//  مُستخرَجة من NativePdfRenderer.kt كجزء من إعادة هيكلة الملف الضخم إلى
//  ملفات بمسؤولية واحدة. كانت DrawCtx صنفاً متداخلاً خاصاً (private class
//  داخل NativePdfRenderer) — رُفِعت هنا إلى صنف top-level مرئي عبر كل
//  الموديول، لأنها أصبحت تُستخدَم من أربعة ملفات معاً: NativePdfRenderer.kt
//  (النواة)، ChartRenderer.kt، ShapeRenderer.kt، وأي ملف رسم مستقبلي.
//  سياق رسم لصفحة واحدة: يلف PdfContentBuilder بمنطق تحويل احداثيات
//  Canvas (اعلى-يسار، Y يتزايد لاسفل) الى احداثيات PDF (اسفل-يسار، Y
//  يتزايد لاعلى) في نقطة واحدة فقط.
// ═══════════════════════════════════════════════════════════════════════

/** ⚠️ إصلاح حقيقي جوهري (الروابط التشعبية بلا أي وظيفة فعلية): مستطيل
 *  نقر واحد مُجمَّع أثناء رسم النص الفعلي (drawLayoutLines في
 *  NativePdfRenderer.kt، حيث الموضع/العرض الحقيقي للنص معروف فقط بعد
 *  القياس والرسم الحقيقيين، لا تقريباً). uri (رابط خارجي) أو anchorName
 *  (اسم Bookmark داخلي، يُحَل لاحقاً لرقم/كائن صفحة فعلي عبر
 *  bookmarkResolution في renderDocument) — أحدهما فقط غير null عملياً
 *  لكل مستطيل (نفس TextRun.linkUri/linkAnchor الأصلي، يُفترَض كل واحد
 *  منهما حصرياً في طبقة Dart). الإحداثيات بالنقاط، بنظام PDF الأصلي
 *  (أسفل-يسار، Y يتزايد لأعلى — مُحوَّلة فعلاً عبر DrawCtx.pointY قبل
 *  الوصول هنا، فلا حاجة لأي تحويل إضافي عند الاستهلاك في finalizePage). */
data class PendingLinkAnnotation(
    val xMinPt: Float,
    val xMaxPt: Float,
    val yMinPt: Float,
    val yMaxPt: Float,
    val uri: String?,
    val anchorName: String?
)

class DrawCtx(
    var cb: PdfContentBuilder,
    var imageManager: PdfImageManager,
    val pageHeightPt: Float,
    // ⚠️ إصلاح حقيقي (شفافية الظلال كانت تُتجاهَل وتُرسَم معتمة بالكامل)
    // — انظر تعليق الكلاس الكامل في PdfExtGStateManager.kt. يُمرَّر
    // مثيل واحد مشترك عبر كل صفحات المستند (بنفس آلية fontManager)،
    // افتراضي null يحافظ على السلوك القديم (بلا شفافية حقيقية) لأي
    // مسار استدعاء قديم لا يمرّره صراحة (دفاعي، لن يحدث عملياً بعد
    // ربط كل مواضع إنشاء DrawCtx في هذا الملف).
    var extGStateManager: PdfExtGStateManager? = null
    ) {

    private var imageCounter = 0

    /** ⚠️ إضافة جديدة (الروابط التشعبية): تتراكم هنا كل مستطيلات الروابط
     *  المُجمَّعة أثناء رسم *صفحة PDF واحدة فعلية* (يُعاد تعيينها/تُستهلَك
     *  بالكامل في finalizePage لكل صفحة على حدة — انظر تعليق
     *  PendingLinkAnnotation أعلاه وfinalizePage في NativePdfRenderer.kt). */
    val pendingLinks: MutableList<PendingLinkAnnotation> = ArrayList()

    fun rectY(yCanvasTop: Float, h: Float): Float = pageHeightPt - yCanvasTop - h
    fun pointY(yCanvas: Float): Float = pageHeightPt - yCanvas

    /** ⚠️ إصلاح حقيقي (شفافية الظلال): يطبّق شفافية حقيقية (عامل gs
     *  + كائن /ExtGState) لقناة الألفا المُستخرَجة من [argbWithAlpha]
     *  ثم يُنفِّذ [draw] داخل q/Q (حفظ/استرجاع حالة الرسم) فلا "تتسرّب"
     *  الشفافية لأي عملية رسم لاحقة بعد انتهاء هذا الاستدعاء. لو لم
     *  يكن extGStateManager متوفراً (نظرياً فقط، دفاعي)، يُنفِّذ
     *  [draw] مباشرة بلا أي شفافية (نفس السلوك القديم) بدل تجاهل
     *  الرسم كلياً. */
    fun withAlpha(argbWithAlpha: Int, draw: () -> Unit) {
        val alpha = (argbWithAlpha ushr 24) and 0xFF
        val mgr = extGStateManager
        if (mgr == null || alpha >= 255) {
            draw()
            return
        }
        val gsName = mgr.registerAlpha(alpha)
        cb.save()
        cb.applyExtGState(gsName)
        draw()
        cb.restore()
    }

    fun fillPageBackground(argb: Int, w: Float, h: Float) {
        cb.setFillColor(argb)
        cb.fillRect(0f, 0f, w, h)
    }

    fun drawBitmapCover(bytes: ByteArray, x: Float, yTop: Float, w: Float, h: Float) {
        try {
            val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return
            val srcRatio = bmp.width.toFloat() / bmp.height.toFloat()
            val dstRatio = w / h
            val cropped: Bitmap = if (srcRatio > dstRatio) {
                val cropW = (bmp.height * dstRatio).toInt().coerceAtLeast(1)
                val offset = ((bmp.width - cropW) / 2).coerceAtLeast(0)
                Bitmap.createBitmap(bmp, offset, 0, cropW.coerceAtMost(bmp.width - offset), bmp.height)
            } else {
                val cropH = (bmp.width / dstRatio).toInt().coerceAtLeast(1)
                val offset = ((bmp.height - cropH) / 2).coerceAtLeast(0)
                Bitmap.createBitmap(bmp, 0, offset, bmp.width, cropH.coerceAtMost(bmp.height - offset))
            }
            // ⚠️ إصلاح حقيقي (تقليص دقة صور الخلفية الكاملة لحجم العرض
            // الفعلي): نفس مبدأ الإصلاح المطبَّق في drawBitmapFit —
            // انظر تعليق الكلاس الكامل في PdfImageManager.kt. صورة
            // خلفية بدقة كاملة (مثلاً 4000×3000) تُعرَض بحجم صفحة A4
            // فعلي (~595×842 نقطة ≈ 1240×1754 بكسل عند 150 DPI) لا
            // تحتاج أي بكسل زائد عن ذلك — نُصغِّرها هنا *قبل* أول ضغط
            // JPEG (بخلاف الاعتماد فقط على downsampleIfNeeded الداخلية
            // في registerImage، التي لن تُفعَّل هنا لأن هذا المسار
            // يُمرِّر بايتات JPEG مُرمَّزة مسبقاً threshold-blind لا
            // Bitmap خاماً، فيُعاد فك ترميزها بدقتها الكاملة دون علم
            // مسبق بحجم العرض المطلوب لولا هذا التصغير اليدوي هنا أولاً).
            val targetPxW = (w / 72f * 150f).toInt().coerceAtLeast(1)
            val targetPxH = (h / 72f * 150f).toInt().coerceAtLeast(1)
            val scale = if (cropped.width > targetPxW || cropped.height > targetPxH) {
                maxOf(targetPxW.toFloat() / cropped.width, targetPxH.toFloat() / cropped.height).coerceAtMost(1f)
            } else 1f
            val finalBmp = if (scale < 0.999f) {
                Bitmap.createScaledBitmap(
                    cropped,
                    (cropped.width * scale).toInt().coerceAtLeast(1),
                    (cropped.height * scale).toInt().coerceAtLeast(1),
                    true
                )
            } else cropped
            val out = java.io.ByteArrayOutputStream()
            finalBmp.compress(Bitmap.CompressFormat.JPEG, 90, out)
            val name = imageManager.registerImage(out.toByteArray(), "Img", imageCounter++)
            cb.drawImageXObject(name, x, rectY(yTop, h), w, h)
            if (finalBmp !== cropped) finalBmp.recycle()
            if (cropped !== bmp) cropped.recycle()
            bmp.recycle()
        } catch (e: Exception) {
            android.util.Log.w("NativePdfRenderer", "فشل رسم صورة الخلفية (cover): ${e.message}")
        }
    }

    fun drawBitmapFit(bytes: ByteArray, x: Float, yTop: Float, w: Float, h: Float) {
        try {
            // ⚠️ إصلاح حقيقي (تقليص دقة الصور لحجم العرض الفعلي): w/h
            // هنا (نقطة PDF) تمرَّر الآن صريحاً لـregisterImage عبر
            // targetWidthPt/targetHeightPt — انظر تعليق الكلاس الكامل
            // في PdfImageManager.kt لتفصيل المشكلة والحل (صور بدقة
            // كاميرا كاملة كانت تُضمَّن بصرف النظر عن حجم عرضها
            // الفعلي الصغير غالباً في المستند).
            val name = imageManager.registerImage(bytes, "Img", imageCounter++, w, h)
            cb.drawImageXObject(name, x, rectY(yTop, h), w, h)
        } catch (e: Exception) {
            android.util.Log.w("NativePdfRenderer", "فشل رسم صورة: ${e.message}")
        }
    }

    fun drawWatermark(wm: WatermarkSpec, pageW: Float, pageH: Float) {
        if (wm.text.isBlank()) return
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = wm.colorArgb
            textSize = 54f
            typeface = Typeface.DEFAULT_BOLD
        }
        cb.save()
        val cx = pageW / 2f
        val cyPdf = pageH / 2f
        val rad = Math.toRadians(-wm.rotationDegrees)
        val cos = kotlin.math.cos(rad).toFloat()
        val sin = kotlin.math.sin(rad).toFloat()
        cb.transform(cos, sin, -sin, cos, cx, cyPdf)
        val textWidth = paint.measureText(wm.text)
        // ⚠️ إصلاح حقيقي مؤكَّد (شفافية العلامة المائية كانت تُتجاهَل
        // وتُرسَم معتمة بالكامل): paint.color = wm.colorArgb يحمل قناة
        // ألفا حقيقية (مثل الافتراضي 0x80C0C0C0، ~50% تعتيم) في كائن
        // Paint/TextPaint نفسه (الذي يدعم ARGB كاملاً)، لكن المسار
        // الفعلي للرسم (drawTextLineBidiAware → cb.drawTextLine →
        // drawGlyphRun → setFillColor(basePaint.color)) يستخرج فقط RGB
        // من هذه القيمة عبر عامل rg الذي لا يحمل ألفا في PDF أصلاً —
        // فكانت العلامة المائية تُرسَم نصاً معتماً 100% فوق المحتوى
        // (يحجبه كلياً) بدل علامة شبه شفافة كما يُتوقَّع تصميمياً من
        // أي علامة مائية. withAlpha هنا تُطبِّق الشفافية الحقيقية عبر
        // /ExtGState حول استدعاء الرسم النصي بالكامل، بلا أي حاجة
        // للمس drawGlyphRun (المسار العام المُستخدَم لكل نص آخر في
        // المستند، حيث الشفافية النصية الحقيقية حالة نادرة جداً
        // خارج هذا الاستخدام المحدَّد).
        withAlpha(wm.colorArgb) {
            drawTextLineBidiAware(cb, wm.text, -textWidth / 2f, 0f, paint)
        }
        cb.restore()
    }

    /** ⚠️ إصلاح حقيقي (ظل حد الصفحة مفقود كلياً): PageBorderSpec.shadow
     *  (Boolean) يُقرأ من Dart (map["shadow"]) ويصل فعلياً للنموذج،
     *  لكن drawPageBorder (الإصدار السابق) كانت تتجاهله تماماً — تُرسم
     *  دوماً مستطيلاً محدَّداً بسيطاً بصرف النظر عن قيمة الحقل، فلا أي
     *  فرق بصري بين border.shadow=true و=false إطلاقاً، رغم أن DOCX
     *  page border بخاصية "Shadow" (ضمن خصائص w:pgBorders) يُظهر فعلياً
     *  ظلاً واضحاً (إزاحة سفلية-يمينية مائلة، نفس تأثير ظل النوافذ/
     *  الشكل المتوفر فعلياً لعناصر ShapeBlock عبر ShadowSpec أدناه في
     *  drawShape — نتبع هنا نفس الأسلوب المرئي المُبسَّط المُستخدَم فعلياً
     *  هناك بدل تمويه Gaussian حقيقي [غير متاح أصلاً في أي مكان من هذا
     *  المحرك، يتطلَّب SMask/Transparency Group كاملة، خارج النطاق
     *  الحالي]: نرسم نسخة معتمة شبه شفافة من نفس المستطيل، مُزاحة قليلاً
     *  لأسفل ويمين، خلف المستطيل الفعلي، فتُحاكي ظلاً مسطَّحاً واضحاً
     *  دون أي تكلفة تقنية إضافية تتجاوز ما يدعمه هذا المحرك فعلياً). */
    fun drawPageBorder(border: PageBorderSpec, pageW: Float, pageH: Float) {
        val inset = (border.widthPt / 2 + 18).toFloat()
        val rectW = pageW - 2 * inset
        val rectH = pageH - 2 * inset
        if (border.shadow) {
            val shadowOffset = (border.widthPt.toFloat() * 1.5f).coerceAtLeast(3f)
            // ⚠️ إصلاح حقيقي (شفافية ظل حد الصفحة): نفس مبدأ إصلاح ظل
            // الأشكال أعلاه — withAlpha هنا تُطبِّق شفافية حقيقية (40%
            // تعتيم، 0x66 من 0xFF) عبر كائن /ExtGState فعلي بدل اللون
            // المعتم بالكامل الذي كان سيُكتب لو استُخدِم setStrokeColor
            // وحدها مباشرة (تتجاهل قناة الألفا كلياً في أي حال).
            withAlpha(0x66000000) {
                cb.save()
                cb.setStrokeColor(0x66000000) // RGB فقط من هذه القيمة (أسود)؛ الشفافية الفعلية تأتي من withAlpha أعلاه
                cb.setLineWidth(border.widthPt.toFloat())
                cb.strokeRect(inset + shadowOffset, inset - shadowOffset, rectW, rectH)
                cb.restore()
            }
        }
        cb.setStrokeColor(border.colorArgb)
        cb.setLineWidth(border.widthPt.toFloat())
        cb.strokeRect(inset, inset, rectW, rectH)
    }
    }
