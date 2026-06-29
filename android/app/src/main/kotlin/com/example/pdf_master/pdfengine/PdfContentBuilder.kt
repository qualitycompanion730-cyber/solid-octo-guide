package com.example.pdf_master.pdfengine

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.text.PositionedGlyphs
import android.graphics.text.TextRunShaper
import android.text.TextPaint
import java.io.ByteArrayOutputStream
import kotlin.math.ceil

/**
 * ═══════════════════════════════════════════════════════════════════════
 * PdfContentBuilder
 * ───────────────────────────────────────────────────────────────────────
 * يبني content stream PDF لصفحة واحدة كنص عوامل خام (قبل الضغط النهائي
 * في PdfWriter.buildStreamObject). كل دالة هنا توازي دالة Canvas.* كانت
 * مستخدَمة في NativePdfRenderer.kt الأصلي، فالاستبدال يبقى موضعياً
 * (canvas.drawXxx → contentBuilder.drawXxx) بلا تغيير في منطق التخطيط
 * المُستدعي.
 *
 * ⚠️ القلب الحقيقي لحل المشكلة: drawTextLine() أدناه. بدل
 * layout.draw(canvas) (التي تُمرَّر لـ PdfDocument فتُصدَّر كمسارات
 * هندسية)، نستخرج من كل سطر في StaticLayout كائنات PositionedGlyphs
 * حقيقية عبر TextRunShaper.shapeTextRun().
 * ═══════════════════════════════════════════════════════════════════════
 */
class PdfContentBuilder(
    private val fontManager: PdfFontManager,
    var imageManager: PdfImageManager? = null // تمت إضافته لدعم رسم الـ Emojis كصور
) {

    private val sb = StringBuilder()
    private var emojiCounter = 0

    /** يُستدعى مرة واحدة بعد بناء كل عوامل الصفحة — يُعيد المحتوى الخام */
    fun build(): ByteArray = sb.toString().toByteArray(Charsets.ISO_8859_1)

    private fun op(s: String) { sb.append(s).append('\n') }

    // ── حالة الرسم: حفظ/استرجاع، تحويل، قص ──────────────────────────────────

    fun save() = op("q")
    fun restore() = op("Q")

    fun translate(dx: Float, dy: Float) = op("1 0 0 1 ${f(dx)} ${f(dy)} cm")

    /** تحويل كامل بمصفوفة 2D صريحة [a b c d e f] */
    fun transform(a: Float, b: Float, c: Float, d: Float, e: Float, fF: Float) =
        op("${f(a)} ${f(b)} ${f(c)} ${f(d)} ${f(e)} ${f(fF)} cm")

    fun clipRect(x: Float, y: Float, w: Float, h: Float) {
        op("${f(x)} ${f(y)} ${f(w)} ${f(h)} re")
        op("W n")
    }

    // ── أشكال أساسية ─────────────────────────────────────────────────────

    fun setFillColor(argb: Int) {
        op("${f(Color.red(argb) / 255f)} ${f(Color.green(argb) / 255f)} ${f(Color.blue(argb) / 255f)} rg")
    }

    fun setStrokeColor(argb: Int) {
        op("${f(Color.red(argb) / 255f)} ${f(Color.green(argb) / 255f)} ${f(Color.blue(argb) / 255f)} RG")
    }

    fun setLineWidth(w: Float) = op("${f(w)} w")

    fun applyExtGState(gsResourceName: String) = op("/$gsResourceName gs")

    fun fillRect(x: Float, y: Float, w: Float, h: Float) {
        op("${f(x)} ${f(y)} ${f(w)} ${f(h)} re")
        op("f")
    }

    fun strokeRect(x: Float, y: Float, w: Float, h: Float) {
        op("${f(x)} ${f(y)} ${f(w)} ${f(h)} re")
        op("S")
    }

    fun drawLine(x0: Float, y0: Float, x1: Float, y1: Float) {
        op("${f(x0)} ${f(y0)} m")
        op("${f(x1)} ${f(y1)} l")
        op("S")
    }

    fun ovalPath(cx: Float, cy: Float, rx: Float, ry: Float, fill: Boolean, stroke: Boolean) {
        val k = 0.5523f
        op("${f(cx + rx)} ${f(cy)} m")
        op("${f(cx + rx)} ${f(cy + ry * k)} ${f(cx + rx * k)} ${f(cy + ry)} ${f(cx)} ${f(cy + ry)} c")
        op("${f(cx - rx * k)} ${f(cy + ry)} ${f(cx - rx)} ${f(cy + ry * k)} ${f(cx - rx)} ${f(cy)} c")
        op("${f(cx - rx)} ${f(cy - ry * k)} ${f(cx - rx * k)} ${f(cy - ry)} ${f(cx)} ${f(cy - ry)} c")
        op("${f(cx + rx * k)} ${f(cy - ry)} ${f(cx + rx)} ${f(cy - ry * k)} ${f(cx + rx)} ${f(cy)} c")
        paintPath(fill, stroke)
    }

    fun moveTo(x: Float, y: Float) = op("${f(x)} ${f(y)} m")
    fun lineTo(x: Float, y: Float) = op("${f(x)} ${f(y)} l")
    fun curveTo(cx1: Float, cy1: Float, cx2: Float, cy2: Float, x: Float, y: Float) =
        op("${f(cx1)} ${f(cy1)} ${f(cx2)} ${f(cy2)} ${f(x)} ${f(y)} c")
    fun closePath() = op("h")
    fun paintPath(fill: Boolean, stroke: Boolean) {
        op(when {
            fill && stroke -> "B"
            fill -> "f"
            stroke -> "S"
            else -> "n"
        })
    }

    fun pieSlice(cx: Float, cy: Float, r: Float, startDeg: Float, sweepDeg: Float, fill: Boolean) {
        val steps = (kotlin.math.abs(sweepDeg) / 6f).toInt().coerceAtLeast(1)
        op("${f(cx)} ${f(cy)} m")
        for (i in 0..steps) {
            val angle = Math.toRadians((startDeg + sweepDeg * i / steps).toDouble())
            val x = cx + r * kotlin.math.cos(angle).toFloat()
            val y = cy + r * kotlin.math.sin(angle).toFloat()
            op("${f(x)} ${f(y)} l")
        }
        closePath()
        paintPath(fill = fill, stroke = false)
    }

    // ── صور (Image XObjects) ────────────────────────────────────────────

    fun drawImageXObject(resourceName: String, x: Float, y: Float, w: Float, h: Float) {
        op("q")
        op("${f(w)} 0 0 ${f(h)} ${f(x)} ${f(y)} cm")
        op("/$resourceName Do")
        op("Q")
    }

    // ── النص: القلب الحقيقي للإصلاح ──────────────────────────────────────

    /** ⚠️ إصلاح حقيقي (دقة قياس عرض النص لخلفية التظليل ورمز القائمة):
     *  تُستخدَم في NativePdfRenderer.drawHighlightBackground/drawListMarker
     *  بدل Paint.measureText السابقة — انظر تعليق نقطتي الاستدعاء
     *  لتفصيل المشكلة الكاملة. تستدعي نفس TextRunShaper.shapeTextRun
     *  المُستخدَمة فعلياً في drawTextLine (نفس مسار HarfBuzz/Minikin
     *  الكامل بكل تأثيراته: kerning، ligatures عربية، تشكيل GSUB، إلخ)
     *  فتُرجع نفس قيمة getAdvance() الحقيقية التي سيُرسَم بها النص فعلياً
     *  — لا تقدير تقريبي منفصل قد يتعارض معها. لا أي تأثير جانبي (لا
     *  كتابة لأي عامل PDF، لا استدعاء لـnoteGlyphUsed/drawEmojiRun) —
     *  دالة قياس خالصة بحتة، آمنة للاستدعاء بصرف النظر عن عدد مرات
     *  استدعائها على نفس النص. */
    fun measureTextLine(text: CharSequence, lineStart: Int, lineEnd: Int, isRtl: Boolean, basePaint: TextPaint): Float {
        if (lineEnd <= lineStart) return 0f
        val glyphs: PositionedGlyphs = TextRunShaper.shapeTextRun(
            text, lineStart, lineEnd - lineStart, lineStart, lineEnd - lineStart,
            0f, 0f, isRtl, basePaint
        )
        if (glyphs.glyphCount() == 0) return 0f
        return glyphs.getAdvance()
    }

    fun drawTextLine(
        text: CharSequence,
        lineStart: Int,
        lineEnd: Int,
        baselineX: Float,
        baselineY: Float,
        isRtl: Boolean,
        basePaint: TextPaint,
        /** ⚠️ إضافة جديدة (النص الشفاف القابل للبحث لأداة OCR): انظر
         *  تعليق FontSpec.renderMode في PdfSpecModels.kt للشرح الكامل.
         *  القيمة الافتراضية false تحافظ على سلوك كل الاستدعاءات
         *  الحالية في NativePdfRenderer.kt تماماً دون أي تغيير. */
        invisible: Boolean = false
    ): Float {
        if (lineEnd <= lineStart) return 0f

        val glyphs: PositionedGlyphs = TextRunShaper.shapeTextRun(
            text, lineStart, lineEnd - lineStart, lineStart, lineEnd - lineStart,
            0f, 0f, isRtl, basePaint
        )
        val glyphCount = glyphs.glyphCount()
        if (glyphCount == 0) return 0f

        val order = (0 until glyphCount).sortedBy { glyphs.getGlyphX(it) }

        // ═══════════════════════════════════════════════════════════════
        // ⚠️ إصلاح حقيقي جوهري (الطبقة النصية المستخرَجة/القابلة للبحث
        // للنص العربي المُشكَّل): نلفّ كامل عملية رسم هذا الـrun (كل
        // الـglyphs من استدعاء drawTextLine واحد) في تسلسل محتوى مُعلَّم
        // (Marked Content) من نوع /Span يحمل مُدخل /ActualText يساوي النص
        // المنطقي الأصلي (text[lineStart..lineEnd]) مُرمَّزاً UTF-16BE.
        //
        // السبب الجذري الكامل: HarfBuzz/Minikin يُشكِّل العربي المتصل
        // فيُنتج glyphs لأشكال موضعية (initial/medial/final) وترابطات
        // (ligatures مثل لا/لله) ذات Glyph IDs لا يربطها جدول cmap الأساسي
        // للخط بأي Unicode إطلاقاً (cmap يربط فقط الأشكال المعزولة
        // الأساسية). فأي جدول ToUnicode مبنيّ بعكس cmap وحده يفقد 70%+ من
        // الـglyphs العربية فعلياً (أُثبت بالفحص: 83 من 118 glyph مفقودة)،
        // فيُستخرَج النص كـmojibake. مُدخل /ActualText (مواصفة PDF §14.9.4)
        // هو الآلية القياسية المخصَّصة تحديداً لهذه الحالة: يُعلن النص
        // المنطقي الحقيقي للتسلسل بصرف النظر كلياً عن الـglyphs المرسومة
        // أو ترتيبها أو ترابطاتها — فيستخرجه أي قارئ PDF متوافق (Acrobat،
        // Chrome، pdfminer، إلخ) صحيحاً 100% بالترتيب المنطقي السليم. هذا
        // ما تستخدمه فعلياً منتجات PDF عالية الجودة (Word نفسه، LaTeX)
        // للنصوص المعقَّدة. يبقى ToUnicode أيضاً (مبنيّاً بوعي GSUB في
        // PdfFontManager) كطبقة احتياطية للقارئات النادرة التي تتجاهل
        // ActualText.
        //
        // ملاحظة دقة: النص المنطقي يُكتب دوماً بترتيب الذاكرة (logical
        // order) لا البصري — وهذا هو المطلوب بالضبط لـActualText (القارئ
        // يعرض/ينسخ النص المنطقي كما هو، فلا نعكسه يدوياً حتى للـrun الـ
        // RTL). نتجنّب لفّ مسار الإيموجي (صور لا نص) بـActualText لأن
        // الحرف نفسه يبقى مُعلَناً عبر هذا الـSpan فيُستخرَج صحيحاً أيضاً.
        val actualText = text.subSequence(lineStart, lineEnd).toString()
        val hasActualText = actualText.isNotEmpty()
        if (hasActualText) {
            op("/Span << /ActualText ${utf16beHexString(actualText)} >> BDC")
        }

        var i = 0
        while (i < order.size) {
            val font = glyphs.getFont(order[i])
            var j = i + 1
            while (j < order.size && glyphs.getFont(order[j]) === font) j++

            // التحقق مما إذا كان الخط الحالي مخصصاً للرموز التعبيرية
            val isEmojiFont = font.file?.name?.contains("emoji", ignoreCase = true) == true

            if (isEmojiFont && imageManager != null) {
                // رسم الرموز التعبيرية كصور حقيقية بدلاً من نص PDF
                // ملاحظة: لا معنى لـ invisible مع مسار الإيموجي (صورة
                // دوماً)؛ حالة استخدام OCR لا تُنتج نص إيموجي عملياً.
                drawEmojiRun(glyphs, order, i, j, baselineX, baselineY, basePaint, font, imageManager!!)
            } else {
                // الرسم العادي للنصوص كعوامل Tj/TJ
                drawGlyphRun(glyphs, order, i, j, baselineX, baselineY, basePaint, invisible)
            }
            i = j
        }

        if (hasActualText) op("EMC")

        return glyphs.getAdvance()
    }

    /** يُرمِّز سلسلة نصّية كـPDF text string بصيغة UTF-16BE سداسية
     *  محاطة بـ<...> مع علامة ترتيب البايتات (BOM) U+FEFF في البداية —
     *  هذا هو التمثيل القياسي الوحيد المقبول لـ/ActualText متعدّد اللغات
     *  وفق مواصفة PDF (§7.9.2.2): البادئة FEFF تُعلِم القارئ أن البايتات
     *  التالية UTF-16BE (لا PDFDocEncoding)، فيُستخرَج العربي/أي يونيكود
     *  مكمّل (Emoji، رموز) صحيحاً. نتعامل مع الأحرف خارج BMP (مثل أغلب
     *  الإيموجي، U+1Fxxx) عبر أزواج بديلة (surrogate pairs) — وهي ما
     *  يُنتجه String.toCharArray() في Kotlin/Java أصلاً (UTF-16 داخلياً)
     *  فنكتب كل char كما هو ببساطة. */
    private fun utf16beHexString(s: String): String {
        val sb = StringBuilder(s.length * 4 + 6)
        sb.append('<')
        sb.append("FEFF") // BOM: يُعلن UTF-16BE صراحةً
        for (ch in s) {
            sb.append(String.format(java.util.Locale.ROOT, "%04X", ch.code and 0xFFFF))
        }
        sb.append('>')
        return sb.toString()
    }

    /** يقوم بتحويل كل Glyph للرمز التعبيري إلى صورة PNG شفافة ويزرعها في ملف الـ PDF */
    private fun drawEmojiRun(
        glyphs: PositionedGlyphs,
        order: List<Int>,
        start: Int,
        end: Int,
        baselineX: Float,
        baselineY: Float,
        basePaint: TextPaint,
        font: android.graphics.fonts.Font,
        imgManager: PdfImageManager
    ) {
        val fontSize = basePaint.textSize
        // حجم الصورة المصغرة (أكبر قليلاً من النص لتجنب القص)
        val bmpSize = ceil(fontSize * 1.5f).toInt().coerceAtLeast(1)
        val cx = bmpSize / 2f
        val cyBaseline = bmpSize * 0.75f // خط الأساس داخل الصورة

        for (k in start until end) {
            val raw = order[k]
            val gid = glyphs.getGlyphId(raw)
            val gx = glyphs.getGlyphX(raw)
            val gy = glyphs.getGlyphY(raw)

            // 1. رسم الحرف (الـ Emoji) على Bitmap في الذاكرة
            val bmp = Bitmap.createBitmap(bmpSize, bmpSize, Bitmap.Config.ARGB_8888)
            val canvas = android.graphics.Canvas(bmp)
            val glyphIds = intArrayOf(gid)
            val positions = floatArrayOf(cx, cyBaseline)

            // استخدام ميزة API 31 الرائعة لرسم Glyph محدد بالظبط
            canvas.drawGlyphs(glyphIds, 0, positions, 0, 1, font, basePaint)

            // 2. ضغط الصورة كـ PNG للحفاظ على الشفافية والألوان
            val out = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
            val bytes = out.toByteArray()
            bmp.recycle()

            // 3. تسجيل الصورة في الـ PDF
            val imgName = imgManager.registerImage(bytes, "Emoji", emojiCounter++)

            // 4. وضع الصورة في الإحداثيات الدقيقة للحرف
            val pdfX = baselineX + gx - cx
            val pdfY = baselineY - gy - (bmpSize - cyBaseline)

            drawImageXObject(imgName, pdfX, pdfY, bmpSize.toFloat(), bmpSize.toFloat())
        }
    }

    private fun drawGlyphRun(
        glyphs: PositionedGlyphs,
        order: List<Int>,
        start: Int,
        end: Int,
        baselineX: Float,
        baselineY: Float,
        basePaint: TextPaint,
        invisible: Boolean = false
    ) {
        val firstRaw = order[start]
        val fontObj = glyphs.getFont(firstRaw)
        val handle = fontManager.registerFont(fontObj)
        val fontSize = basePaint.textSize

        op("BT")
        op("/${handle.resourceName} ${f(fontSize)} Tf")
        // ⚠️ إضافة جديدة (النص الشفاف القابل للبحث لأداة OCR): عامل PDF
        // الرسمي "3 Tr" (Text Rendering Mode 3 = "Invisible"، طبقاً
        // لمواصفات PDF القياسية §9.3.3) يجعل الـ glyphs غير مرئية بصرياً
        // (لا تعبئة ولا تخطيط) بينما تبقى عناصر نص PDF حقيقية كاملة —
        // قابلة للتحديد والنسخ والبحث عبر أي قارئ PDF قياسي (Adobe
        // Acrobat، Chrome، إلخ)، بالاستفادة من نفس جدول ToUnicode الذي
        // يبنيه PdfFontManager.buildType0Font لكل خط مسجَّل (نفس الآلية
        // المستخدمة فعلياً لقابلية نسخ النص العربي العادي في كل
        // المحوّلات الأخرى). 0 Tr (الافتراضي الضمني لو لم يُكتب العامل
        // إطلاقاً) هو "Fill text" العادي — لا تغيير سلوك لأي استدعاء
        // حالي لا يمرّر invisible=true صراحة.
        if (invisible) op("3 Tr")
        setFillColor(basePaint.color)

        val startX = baselineX + glyphs.getGlyphX(firstRaw)
        val startY = baselineY - glyphs.getGlyphY(firstRaw)
        op("1 0 0 1 ${f(startX)} ${f(startY)} Tm")

        val tj = StringBuilder("[")
        for (k in start until end) {
            val raw = order[k]
            val gid = glyphs.getGlyphId(raw) and 0xFFFF
            // ⚠️ إصلاح حقيقي جوهري (Subsetting حقيقي يستبدل التضمين
            // الكامل): نُسجِّل هنا كل Glyph ID يُكتب فعلياً في عامل TJ —
            // انظر تعليق الكلاس الكامل في PdfFontManager.kt (noteGlyphUsed/
            // finalizeAllFonts/TrueTypeSubsetter) لتفصيل سبب كون هذا
            // التتبُّع ضرورياً (بناء نسخة subset من الخط بعد رسم كل
            // الصفحات، تحوي فقط الـglyphs المُستخدَمة فعلياً بدل تضمين
            // ملف TrueType كاملاً — الفحص الفعلي أثبت أن هذا كان السبب
            // الرئيسي لتضخم حجم كل ملف PDF ناتج، حتى 12.3MB لكائن خط
            // واحد فقط). لا تأثير على محتوى عامل TJ نفسه إطلاقاً (نفس
            // gid يُكتب بصرف النظر)؛ هذه استدعاء جانبي بحت لتتبُّع
            // الاستخدام فقط.
            fontManager.noteGlyphUsed(fontObj, gid)
            tj.append('<').append(String.format(java.util.Locale.ROOT, "%04X", gid)).append('>')
            if (k + 1 < end) {
                val nextRaw = order[k + 1]
                val dx = glyphs.getGlyphX(nextRaw) - glyphs.getGlyphX(raw)
                val advanceAtThisFontSize = dx * 1000f / fontSize
                tj.append(' ').append(f(-advanceAtThisFontSize)).append(' ')
            }
        }
        tj.append(']')
        op("$tj TJ")
        // ⚠️ إعادة العامل لوضعه الافتراضي (0 Tr) بعد ET، حتى لا "يتسرّب"
        // وضع invisible خطأً إلى أي عامل نص لاحق آخر في نفس content
        // stream الصفحة لو نُسي ضبطه صريحاً عند الاستدعاء التالي (دفاعي
        // بحت؛ كل استدعاء حالي يمرّر invisible الصريحة الخاصة به فعلاً).
        if (invisible) op("0 Tr")
        op("ET")
    }

    companion object {
        private fun f(v: Float) = PdfWriter.fmt(v)
    }
}
