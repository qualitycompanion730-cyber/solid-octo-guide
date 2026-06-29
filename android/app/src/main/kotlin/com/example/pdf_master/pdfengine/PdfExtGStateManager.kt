package com.example.pdf_master.pdfengine

/**
 * ═══════════════════════════════════════════════════════════════════════
 *  PdfExtGStateManager
 *  ───────────────────────────────────────────────────────────────────────
 *  ⚠️ إصلاح حقيقي مؤكَّد (الشفافية المطلوبة في ألوان الظل كانت تُتجاهَل
 *  كلياً وتُرسَم معتمة بالكامل): تتبُّع دقيق لمسار setFillColor/
 *  setStrokeColor في PdfContentBuilder.kt كشف أنهما يستخرجان فقط القناة
 *  الحمراء/الخضراء/الزرقاء (Color.red/green/blue) من القيمة ARGB
 *  المُمرَّرة لهما، ويتجاهلان قناة الألفا (A) كلياً — أي قيمة ARGB تحمل
 *  شفافية (مثل ShadowSpec.colorArgb الافتراضي 0x59000000، أو
 *  WatermarkSpec.colorArgb الافتراضي 0x80C0C0C0) كانت تُرسَم في الواقع
 *  **معتمة بالكامل (100% تعتيم)** بصرف النظر عن قيمة الألفا المُرسَلة من
 *  Dart أو المفترضة افتراضياً — لأن PDF لا يحمل قناة ألفا في عوامل
 *  rg/RG نفسها أصلاً (لا تُشبه ARGB في هذا)؛ الشفافية في PDF تتطلَّب
 *  صريحاً عامل `gs` يُشير لكائن /ExtGState يحمل /ca (شفافية التعبئة)
 *  و/CA (شفافية الحد) — وهذا العامل لم يكن يُستخدَم إطلاقاً في أي مكان
 *  من المحرك قبل هذا الإصلاح (تأكَّد بالبحث الكامل عن "gs"/"ExtGState"
 *  في كل الملفات: applyExtGState كانت دالة معرَّفة لكن غير مُستدعاة من
 *  أي مكان).
 *
 *  هذا الكلاس يسجّل كائن /ExtGState واحداً فريداً لكل قيمة ألفا (0-255)
 *  تُطلَب فعلياً عبر [registerAlpha] — يُخزَّن بمفتاح الألفا نفسه (256
 *  قيمة ممكنة فقط، آمن تماماً للتخزين المؤقت الكامل عبر كل المستند، خلافاً
 *  للصور التي تختلف بايتاتها الفعلية في كل استدعاء). نفس كائن /ExtGState
 *  لقيمة ألفا معيَّنة يُعاد استخدامه عبر كل صفحات المستند بصرف النظر عن
 *  عدد المرات المطلوب فيها (تماماً كآلية الخطوط في PdfFontManager).
 * ═══════════════════════════════════════════════════════════════════════
 */
class PdfExtGStateManager(private val writer: PdfWriter) {

    private data class Entry(val resourceName: String, val objNum: Int)
    private val entriesByAlpha = HashMap<Int, Entry>()
    private var nextResourceIndex = 1

    /** يسجّل (أو يُعيد استخدام) كائن /ExtGState لقيمة ألفا مُعيَّنة
     *  (0-255، حيث 255 = معتم بالكامل/بلا شفافية، 0 = شفاف بالكامل)،
     *  ويُعيد اسم المصدر المختصر (مثل "GS3") لاستخدامه عبر
     *  PdfContentBuilder.applyExtGState. يحدّد كلا /ca و/CA لنفس القيمة
     *  معاً (شفافية موحَّدة للتعبئة والحد سواء) — يكفي تماماً لاستخدامات
     *  هذا المحرك الحالية (ظلال أشكال/حدود صفحات، التي لا تحتاج شفافية
     *  مختلفة للتعبئة عن الحد في نفس عملية الرسم). */
    fun registerAlpha(alpha255: Int): String {
        val a = alpha255.coerceIn(0, 255)
        entriesByAlpha[a]?.let { return it.resourceName }

        val resourceName = "GS${nextResourceIndex++}"
        val alphaFraction = a / 255f
        // PdfWriter.fmt يُستخدَم هنا عبر تنسيق يدوي مماثل (3 منازل عشرية
        // مُقلَّمة) للحفاظ على نفس اتساق التنسيق الرقمي المُستخدَم في كل
        // مكان آخر من الملف الناتج (تفادي صيغ علمية/Locale خاطئة).
        val alphaStr = PdfWriter.fmt(alphaFraction)
        val objNum = writer.addObject(
            "<<\n/Type /ExtGState\n/ca $alphaStr\n/CA $alphaStr\n>>"
        )
        entriesByAlpha[a] = Entry(resourceName, objNum)
        return resourceName
    }

    /** كل كائنات /ExtGState المسجَّلة فعلياً — تُستخدَم لبناء قاموس
     *  /Resources /ExtGState المشترك لكل صفحة (بنفس آلية الخطوط: كائن
     *  واحد لكل قيمة ألفا، يُشار إليه من كل الصفحات التي تحتاجه). */
    fun allRegistered(): List<Pair<String, Int>> =
        entriesByAlpha.values.map { it.resourceName to it.objNum }
}
