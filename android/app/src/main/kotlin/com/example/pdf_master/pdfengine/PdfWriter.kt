package com.example.pdf_master.pdfengine

import java.io.ByteArrayOutputStream
import java.util.zip.Deflater

/**
 * ═══════════════════════════════════════════════════════════════════════
 *  PdfWriter
 *  ───────────────────────────────────────────────────────────────────────
 *  كاتب PDF منخفض المستوى من الصفر — السبب الجذري الذي استبدلنا من أجله
 *  android.graphics.pdf.PdfDocument بالكامل في طبقة التصدير (انظر التعليق
 *  المطوَّل في NativePdfRenderer.kt الأصلي قبل هذا الإصلاح):
 *
 *  PdfDocument (الفئة الرسمية لأندرويد) تُصدِّر أي نص مرسوم عبر
 *  StaticLayout.draw()/Canvas.drawText() كمسارات هندسية متجهية خام
 *  (عوامل m/l/c/h في content stream) بدل عوامل نص PDF حقيقية (Tj/TJ).
 *  هذا قيد بنيوي في الفئة نفسها لا علاقة له بدقة كود الاستدعاء، وأثبت
 *  الفحص الفعلي لملف PDF ناتج (انظر سجل المحادثة) ثلاث أعراض متطابقة معه
 *  تماماً: (1) حجم ملف متضخم بشكل كارثي — صفحة نص واحدة عادية بلغت
 *  1.5-2 ميجابايت من تعليمات رسم خام بدل عشرات الكيلوبايتات لعوامل Tj
 *  المكافئة، (2) كل عنصر نصي مرسوم *مرتين* (طبقة هندسية مرئية + طبقة
 *  نصية شبه-مخفية لدعم البحث الجزئي الذي توفّره PdfDocument تلقائياً)،
 *  (3) النص العربي المُستخرَج من الطبقة النصية الخفية مكسور بالكامل
 *  (بايتات \u0000 فاصلة بين كل حرف) بسبب فشل خريطة ToUnicode التي تبنيها
 *  PdfDocument داخلياً مع التشكيل العربي المعقَّد (الترابطات/ligatures
 *  multi-character تُفقَد من الخريطة رغم ظهورها سليمة بصرياً).
 *
 *  الحل: نكتب ملف PDF يدوياً بالكامل (header → indirect objects → xref
 *  table → trailer) ونصدّر النص عبر عوامل Tj/TJ حقيقية مع خط Type0
 *  مركَّب (Composite Font / CIDFontType2) يحمل برنامج الخط TrueType
 *  الأصلي مُضمَّناً (FontFile2) — هذا النوع هو الطريقة القياسية والوحيدة
 *  في PDF لدعم Glyph IDs عشوائية (لا تطابق ترميز Latin-1/ASCII بسيط) وهو
 *  متطلَّب أساسي للعربي المُشكَّل (الترابطات/ligatures تُنتج Glyph IDs
 *  لا علاقة مباشرة لها بترميز الأحرف الأصلية).
 *
 *  نحتفظ بكامل منطق القياس والتخطيط والتجزئة على الصفحات في
 *  NativePdfRenderer.kt كما هو (StaticLayout لا يزال يقيس النص بدقة)،
 *  ونحتفظ بـ Minikin/HarfBuzz لتشكيل العربي كما هو (هذا يعمل بشكل صحيح
 *  تماماً ولا علاقة له بالخلل) — الاستبدال محصور فقط في *كيفية كتابة
 *  النتيجة النهائية إلى ملف PDF*، عبر android.graphics.text.TextShaper
 *  (الواجهة الرسمية لاستخراج Glyph IDs/مواضع حقيقية بعد التشكيل الكامل،
 *  متوفرة من API 31) بدل الاعتماد على PdfDocument لرسم النص وتصديره.
 * ═══════════════════════════════════════════════════════════════════════
 */
class PdfWriter {

    // ── الكائنات غير المباشرة (Indirect Objects) ───────────────────────────
    // كل كائن PDF (صفحة، خط، صورة، content stream...) له رقم مرجعي فريد
    // (Object Number) يبدأ من 1. الكائن رقم 0 محجوز دوماً لجدول xref نفسه.
    private val objects = ArrayList<ByteArray?>()
    private var nextObjNum = 1

    /** يحجز رقم كائن جديد دون كتابة محتواه بعد — مفيد للمراجع الأمامية
     *  (مثل صفحة تشير لخط لم يُكتب محتواه الفعلي إلا لاحقاً). */
    fun reserveObject(): Int {
        objects.add(null)
        return nextObjNum++
    }

    /** يكتب محتوى كائن محجوز مسبقاً بـ [reserveObject]. */
    fun setObject(objNum: Int, content: ByteArray) {
        objects[objNum - 1] = content
    }

    /** يحجز ويكتب كائناً جديداً دفعة واحدة، ويُعيد رقمه. */
    fun addObject(content: ByteArray): Int {
        val n = reserveObject()
        setObject(n, content)
        return n
    }

    fun addObject(content: String): Int = addObject(content.toByteArray(Charsets.ISO_8859_1))

    /** مرجع غير مباشر بصيغة "N 0 R" — يُستخدَم داخل قواميس كائنات أخرى. */
    fun ref(objNum: Int): String = "$objNum 0 R"

    // ── أدوات بناء كائنات Stream (محتوى مع طول وضغط اختياري) ───────────────

    /**
     * يبني كائن Stream كامل (قاموس + محتوى) جاهزاً لـ addObject/setObject.
     * [extraDictEntries] قواميس إضافية تُدرَج قبل /Length (مثل /Filter
     * لصور JPEG، أو /Subtype لـ XObject).
     * الضغط بـ Flate (zlib) مفعَّل افتراضياً لكل المحتوى النصي (content
     * streams) — هذا تحديداً ما يضمن أن استبدال 1.5MB من مسارات هندسية
     * بعوامل Tj القصيرة ينعكس فعلياً في حجم الملف النهائي على القرص.
     */
    fun buildStreamObject(rawContent: ByteArray, extraDictEntries: String = "", compress: Boolean = true): ByteArray {
        val (data, filterEntry) = if (compress) {
            Pair(deflate(rawContent), "/Filter /FlateDecode\n")
        } else {
            Pair(rawContent, "")
        }
        val dict = buildString {
            append("<<\n")
            append(filterEntry)
            if (extraDictEntries.isNotEmpty()) append(extraDictEntries)
            append("/Length ${data.size}\n")
            append(">>\nstream\n")
        }
        val out = ByteArrayOutputStream()
        out.write(dict.toByteArray(Charsets.ISO_8859_1))
        out.write(data)
        out.write("\nendstream".toByteArray(Charsets.ISO_8859_1))
        return out.toByteArray()
    }

    private fun deflate(data: ByteArray): ByteArray {
        val deflater = Deflater(Deflater.BEST_COMPRESSION)
        deflater.setInput(data)
        deflater.finish()
        val out = ByteArrayOutputStream(data.size / 2 + 64)
        val buf = ByteArray(8192)
        while (!deflater.finished()) {
            val n = deflater.deflate(buf)
            out.write(buf, 0, n)
        }
        deflater.end()
        return out.toByteArray()
    }

    // ── التجميع النهائي: header + objects + xref + trailer ─────────────────

    /**
     * يجمع كل الكائنات المُسجَّلة في ملف PDF صالح، ويُعيده كـ ByteArray.
     * [catalogObjNum] رقم كائن /Catalog الجذري (يُبنى عادة بعد كل الصفحات
     * لأنه يحتاج مرجعاً لشجرة /Pages المُجمَّعة مسبقاً).
     */
    fun build(catalogObjNum: Int): ByteArray {
        val out = ByteArrayOutputStream()
        val offsets = IntArray(objects.size + 1) // index 0 غير مستخدَم (محجوز للكائن 0 الحر)

        out.write(PDF_HEADER)

        for (i in objects.indices) {
            val objNum = i + 1
            offsets[objNum] = out.size()
            val content = objects[i] ?: ByteArray(0) // كائن محجوز لكن لم يُكتب أبداً: فارغ بأمان بدل استثناء
            out.write("$objNum 0 obj\n".toByteArray(Charsets.ISO_8859_1))
            out.write(content)
            out.write("\nendobj\n".toByteArray(Charsets.ISO_8859_1))
        }

        val xrefOffset = out.size()
        val total = objects.size + 1
        out.write("xref\n0 $total\n".toByteArray(Charsets.ISO_8859_1))
        out.write("0000000000 65535 f \n".toByteArray(Charsets.ISO_8859_1))
        for (objNum in 1 until total) {
            val off = offsets[objNum]
            // ⚠️ إصلاح خلل جذري حقيقي مؤكَّد بالفحص الفعلي: بلا
            // Locale.ROOT صريح، هذا الرقم يُنسَّق بخانات هندية شرقية على
            // أجهزة بـ Locale عربي، فيتحول لـ '?' عند الكتابة بـISO-8859-1
            // — جدول xref بأكمله يصبح فاسداً (إزاحات خاطئة)، فتضطر قارئات
            // PDF المتسامحة "للبحث" عن الكائنات بدل القفز المباشر إليها،
            // وهذا بالضبط ما يفسر التضخم الكارثي (~30+ ميجابايت) المرصود
            // فعلياً على نسخة قبل هذا الإصلاح.
            out.write(String.format(java.util.Locale.ROOT, "%010d 00000 n \n", off).toByteArray(Charsets.ISO_8859_1))
        }

        out.write(
            ("trailer\n<<\n/Size $total\n/Root ${ref(catalogObjNum)}\n>>\nstartxref\n$xrefOffset\n%%EOF")
                .toByteArray(Charsets.ISO_8859_1)
        )

        return out.toByteArray()
    }

    companion object {
        private val PDF_HEADER = "%PDF-1.7\n%\u00E2\u00E3\u00CF\u00D3\n".toByteArray(Charsets.ISO_8859_1)

        /** يُهرِّب سلسلة نصية PDF Literal String — يُسبِق ( ) \ بشرطة مائلة
         *  معكوسة، ويستبدل أسطراً جديدة بـ \n حرفية كي لا تكسر بنية الملف. */
        fun escapeLiteralString(s: String): String {
            val sb = StringBuilder(s.length + 8)
            for (c in s) {
                when (c) {
                    '(', ')', '\\' -> { sb.append('\\'); sb.append(c) }
                    '\n' -> sb.append("\\n")
                    '\r' -> sb.append("\\r")
                    else -> sb.append(c)
                }
            }
            return sb.toString()
        }

        /** ينسّق رقماً عشرياً بأقل عدد منازل ممكن (PDF يقبل عشرية مباشرة في
         *  أغلب السياقات الرقمية) — يقلّل حجم الملف عبر تقليم الأصفار
         *  الزائدة بدل دائماً 6 منازل عشرية ثابتة. */
        fun fmt(v: Float): String {
            // ⚠️ إصلاح خلل جذري حقيقي مؤكَّد بالفحص الفعلي: هذا التابع
            // يُستخدَم لكل قيمة رقمية في كل عوامل المحتوى وقواميس الصفحات
            // (/MediaBox، مواضع Tm، إزاحات TJ، مستطيلات الرسم...). بلا
            // Locale.ROOT صريح، على جهاز بـ Locale عربي ينسّق
            // String.format الأرقام بخانات هندية شرقية (٠-٩) لا ASCII،
            // وهذه الأحرف خارج نطاق ISO-8859-1 الذي يُكتَب به الملف بالكامل
            // فتتحول لـ '?' — هذا تحديداً ما ظهر فعلياً كـ
            // "/MediaBox [0 0 ??????? ???????]" في فحص الملف الناتج.
            if (v == v.toLong().toFloat()) return v.toLong().toString()
            return String.format(java.util.Locale.ROOT, "%.3f", v).trimEnd('0').trimEnd('.')
        }

        fun fmt(v: Double): String = fmt(v.toFloat())
    }
}
