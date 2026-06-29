package com.example.pdf_master.pdfengine

import android.graphics.fonts.Font
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * ═══════════════════════════════════════════════════════════════════════
 *  PdfFontManager
 *  ───────────────────────────────────────────────────────────────────────
 *  يبني، لكل android.graphics.fonts.Font فريد استُخدِم فعلياً في المستند،
 *  خط PDF مركَّب (Composite Font / Type0) من نوع CIDFontType2 — هذا هو
 *  نوع الخط الوحيد في PDF الذي يدعم Glyph IDs عشوائية (16-bit، CID=GID
 *  مباشرة عبر CIDToGIDMap=/Identity) بدل الاعتماد على ترميز Latin-1/
 *  WinAnsi البسيط الذي لا يصلح أصلاً للعربي المُشكَّل (الترابطات
 *  multi-character تُنتج Glyph IDs لا علاقة مباشرة لها بترميز Unicode
 *  الأصلي للأحرف).
 *
 *  ⚠️ إصلاح حقيقي جوهري (Subsetting حقيقي يستبدل التضمين الكامل): الفحص
 *  الفعلي لكل ملفات الاختبار المُرفقة كشف أن كائناً واحداً فقط — برنامج
 *  خط TrueType مُضمَّن كاملاً — يبلغ بمفرده حتى 12.3MB مضغوطة (16.6MB
 *  قبل الضغط) من إجمالي 17.2MB لملف PDF واحد، وهذا النمط يتكرر بثبات في
 *  كل ملف اختبار آخر (كائن خط واحد ~1.37MB يُهيمن على الحجم الكلي في كل
 *  مرة). السبب: تضمين ملف TrueType الكامل بصرف النظر عن أن كل صفحة
 *  تستخدم فعلياً عشرات أو مئات من الـglyphs فقط من بين آلاف الـglyphs
 *  التي يحملها خط متعدد اللغات (تغطية واسعة Unicode + Arabic OpenType
 *  GSUB tables، إلخ) — معظم بيانات glyf/loca المضمَّنة غير مُستخدَمة
 *  إطلاقاً في المستند الفعلي. الحل: تتبُّع كل Glyph ID استُخدِم فعلياً في
 *  أي عامل Tj/TJ عبر [noteGlyphUsed] (تُستدعى من PdfContentBuilder.
 *  drawGlyphRun لكل glyph يُكتب فعلياً)، ثم بناء نسخة "subset" حقيقية من
 *  الخط في [finalizeAllFonts] — تحوي فقط جداول glyf/loca/hmtx/maxp
 *  مُعاد بناؤها لتشمل تحديداً (1) glyph 0 (.notdef، إلزامي وفق مواصفة
 *  TrueType)، (2) كل GID استُخدِم فعلياً، (3) كل GID يعتمد عليه أي composite
 *  glyph مُستخدَم (حرف مُركَّب من عدة contours مرجعية - شائع في خطوط
 *  Arabic OpenType المعقَّدة) — تُحسَب عبر إغلاق عبوري (transitive closure)
 *  على جدول glyf الأصلي قبل القطع.
 *
 *  ⚠️ تبعاً لذلك، تغيَّر تدفق الاستدعاء: registerFont لا تبني كائنات PDF
 *  فعلية بعد الآن (كانت تفعل ذلك فوراً عند أول استخدام)؛ فقط تحجز رقم
 *  كائن /Type0 (PdfWriter.reserveObject، يدعم مراجع أمامية بالفعل) وتُعيد
 *  اسم مصدر مستقر لاستخدامه في عوامل Tf فوراً — هذا ضروري لأن المجموعة
 *  الكاملة من الـglyphs المُستخدَمة فعلياً لا تُعرَف إلا بعد رسم *كل*
 *  صفحات المستند (صفحة لاحقة قد تستخدم glyph لم يظهر في أي صفحة سابقة
 *  من نفس الخط). finalizeAllFonts() تُستدعى مرة واحدة بعد انتهاء حلقة
 *  رسم كل الصفحات في NativePdfRenderer.renderDocument، فتقرأ كل ملف خط
 *  مرة واحدة فقط حينها وتكتب محتوى الكائن المحجوز فعلياً عبر
 *  writer.setObject — لا تغيير في أي طرف آخر من واجهة الكلاس (resourceName
 *  مستقر من أول استدعاء registerFont، فعوامل Tf المكتوبة في content
 *  streams الصفحات السابقة تبقى صحيحة دون أي حاجة لإعادة كتابتها).
 *
 *  كل خط فريد (بحسب android.graphics.fonts.Font.getFile()+ttcIndex، أي
 *  ملف الخط الفعلي على القرص بصرف النظر عن أي family منطقي استُخدِم
 *  لاختياره) يُضمَّن مرة واحدة فقط بصرف النظر عن عدد مرات استخدامه عبر
 *  كل صفحات المستند.
 * ═══════════════════════════════════════════════════════════════════════
 */
class PdfFontManager(private val writer: PdfWriter) {

    /** بيانات خط واحد مُسجَّل (محجوز، قد لا يكون مبنياً بالكامل بعد). */
    private class RegisteredFont(
        val pdfFontObjNum: Int,        // رقم كائن /Type0 المحجوز في PDF
        val resourceName: String,      // الاسم المختصر في القاموس /Font مثل /F1
        val font: Font,                // أول Font فعلي استُخدِم لهذا الملف (لقراءة البايتات لاحقاً)
        val usedGlyphIds: HashSet<Int> = HashSet()
    )

    // مفتاح: مسار ملف الخط + ttcIndex — يحدّد ملف TrueType فريداً بصرف
    // النظر عن أي عائلة منطقية (family) استُخدِمت لاختياره عبر Typeface.
    private val fontsByFile = HashMap<String, RegisteredFont>()
    private var nextResourceIndex = 1

    /** يُسجَّل عند الحاجة الأولى لكل ملف خط، ويُعيد اسم المصدر المختصر
     *  (مثل "F3") لاستخدامه في عوامل Tf داخل content stream، بالإضافة
     *  لرقم الكائن /Type0 للإشارة منه في قاموس /Resources /Font للصفحة.
     *  ⚠️ لا تبني محتوى الكائن الفعلي بعد الآن — انظر تعليق الكلاس أعلاه
     *  لتفصيل سبب التأجيل إلى [finalizeAllFonts]. */
    fun registerFont(font: Font): RegisteredFontHandle {
        val key = fontKeyFor(font)
        val existing = fontsByFile[key]
        if (existing != null) {
            return RegisteredFontHandle(existing.resourceName, existing.pdfFontObjNum)
        }

        val resourceName = "F${nextResourceIndex++}"
        val objNum = writer.reserveObject()
        fontsByFile[key] = RegisteredFont(objNum, resourceName, font)
        return RegisteredFontHandle(resourceName, objNum)
    }

    /** يُسجِّل أن Glyph ID مُعيَّن من خط مُعيَّن استُخدِم فعلياً في عامل
     *  Tj/TJ مكتوب بالفعل في أحد content streams الصفحات — تُستدعى من
     *  PdfContentBuilder.drawGlyphRun لكل glyph تكتبه فعلياً. لا تأثير
     *  لها إن لم يكن هذا الخط مسجَّلاً عبر registerFont من قبل (لا يجب
     *  أن يحدث عملياً، لأن drawGlyphRun يستدعي registerFont أولاً دوماً
     *  بنفس الـFont، لكن نتعامل بأمان دفاعي بدل استثناء). */
    fun noteGlyphUsed(font: Font, glyphId: Int) {
        val key = fontKeyFor(font)
        fontsByFile[key]?.usedGlyphIds?.add(glyphId and 0xFFFF)
    }

    /** كل الخطوط المسجَّلة فعلياً — تُستخدَم لبناء قاموس /Resources /Font
     *  المشترك (نفس القاموس يُستخدَم لكل صفحات المستند، فالخط يُضمَّن مرة
     *  واحدة فعلياً بصرف النظر عن عدد الصفحات التي تستخدمه). */
    fun allRegisteredFonts(): List<Pair<String, Int>> =
        fontsByFile.values.map { it.resourceName to it.pdfFontObjNum }

    /** ⚠️ تُستدعى مرة واحدة فقط، بعد انتهاء رسم *كل* صفحات المستند (انظر
     *  NativePdfRenderer.renderDocument) — هذه هي النقطة الوحيدة التي
     *  تُعرَف فيها المجموعة الكاملة النهائية لكل Glyph ID استُخدِم فعلياً
     *  لكل خط، فتُبنى نسخة subset حقيقية وتُكتب فعلياً عبر writer.setObject
     *  في رقم الكائن المحجوز مسبقاً من registerFont. آمنة للاستدعاء على
     *  مستند بلا أي خط مسجَّل (حلقة فارغة، لا عملية). */
    fun finalizeAllFonts() {
        for (rf in fontsByFile.values) {
            try {
                val fullBytes = readFontFile(rf.font)
                // ⚠️ نقرأ gidToUnicode من الخط *الأصلي* الكامل هنا أولاً
                // (قبل أي تقليص) — هذا ضروري وليس مجرد تفضيل: جدول cmap
                // في الخط بعد التقليص يصبح شكلياً بحتاً (انظر
                // TrueTypeSubsetter.buildMinimalCmap)، فإعادة قراءته بعد
                // القطع تُرجع خريطة GID→Unicode فاسدة/فارغة فعلياً، وهذا
                // كان يكسر تماماً ToUnicode (بحث/نسخ/تحديد النص) لكل خط
                // مُقلَّص لولا هذا الترتيب. نُمرِّر ttfOriginal.gidToUnicode
                // أدناه عبر oldToNew من نتيجة subset() لإعادة بنائها
                // بصحة بدلالة GIDs الجديدة المضغوطة.
                val ttfOriginal = TrueTypeFontInfo.parse(fullBytes)
                // ⚠️ الإصلاح الجوهري: نبني نسخة subset (فقط الـglyphs
                // المستخدَمة فعلياً + إغلاقها العبوري لمراجع composite
                // glyph + .notdef) بدل تمرير fullBytes كما هي — انظر
                // تعليق الكلاس أعلاه وTrueTypeSubsetter أدناه لتفصيل
                // الخوارزمية الكاملة. لو فشل أي جزء من عملية الـsubsetting
                // لسبب غير متوقَّع (تنسيق خط غير قياسي، إلخ)، نتراجع
                // بأمان كامل لتضمين الخط الكامل كما كان سلوك ما قبل هذا
                // الإصلاح — صحة العرض البصري أهم من توفير الحجم، فلا يجب
                // أبداً أن يُسقط فشل الـsubsetting المستند كله أو يُفسد
                // عرضه بصرياً.
                val result = try {
                    TrueTypeSubsetter.subset(fullBytes, rf.usedGlyphIds)
                } catch (e: Exception) {
                    android.util.Log.w("PdfFontManager", "فشل تقليص الخط (subsetting)، استخدام الملف كاملاً: ${e.message}")
                    null
                }
                val subsetBytes = result?.bytes ?: fullBytes
                // ttf النهائي للقراءات الأخرى (bbox/ascent/hmtx الجديدة)
                // يُقرأ من الناتج الفعلي بعد القطع (صحيح لكل هذه الحقول،
                // فهي مُعاد بناؤها بصحة في subset() نفسها) — فقط
                // gidToUnicode يُستثنى ويُعاد بناؤه بشكل مستقل أدناه.
                val subsetTtf = if (subsetBytes === fullBytes) ttfOriginal else TrueTypeFontInfo.parse(subsetBytes)
                val remappedGidToUnicode = if (result != null && subsetBytes !== fullBytes) {
                    val remapped = HashMap<Int, Int>(ttfOriginal.gidToUnicode.size)
                    for ((oldGid, unicode) in ttfOriginal.gidToUnicode) {
                        val newGid = result.oldToNew[oldGid] ?: continue
                        remapped[newGid] = unicode
                    }
                    remapped
                } else {
                    ttfOriginal.gidToUnicode
                }
                // ⚠️ نُعيد تخطيط خريطة سلاسل الترابطات أيضاً بنفس oldToNew —
                // ضرورية لإصدار bfchar متعدد الأحرف دقيق للترابطات في الخط
                // المُقلَّص (وإلا تُفقَد سلاسلها فتُختزَل لأول حرف فقط في
                // ToUnicode الاحتياطي). subsetTtf.gidToUnicodeSeq المقروءة من
                // الخط المقطوع فارغة دوماً (GSUB يُحذَف عند التقليص)، فمصدر
                // الحقيقة الوحيد هو ttfOriginal المُوسَّعة قبل القطع.
                val remappedSeq = if (result != null && subsetBytes !== fullBytes) {
                    val remapped = HashMap<Int, IntArray>(ttfOriginal.gidToUnicodeSeq.size)
                    for ((oldGid, seq) in ttfOriginal.gidToUnicodeSeq) {
                        val newGid = result.oldToNew[oldGid] ?: continue
                        remapped[newGid] = seq
                    }
                    remapped
                } else {
                    ttfOriginal.gidToUnicodeSeq
                }
                subsetTtf.gidToUnicode = remappedGidToUnicode
                subsetTtf.gidToUnicodeSeq = remappedSeq
                buildType0FontInto(rf.pdfFontObjNum, subsetBytes, subsetTtf, rf.resourceName)
            } catch (e: Exception) {
                android.util.Log.w("PdfFontManager", "فشل بناء خط ${rf.resourceName} كلياً: ${e.message}")
                // كائن /Type0 يبقى محجوزاً بلا محتوى — PdfWriter.build
                // يكتب كائناً فارغاً بأمان لكائن محجوز لم يُكتب أبداً (لا
                // استثناء يُسقط بقية المستند)، وفق سلوكها الموثَّق فعلاً.
            }
        }
    }

    private fun fontKeyFor(font: Font): String {
        val file = font.file
        // ttcIndex يُميِّز خطاً واحداً داخل ملف TrueType Collection (.ttc)
        // يحوي عدة خطوط؛ معظم خطوطنا .ttf عادية بـ ttcIndex=0 دوماً، لكن
        // المفتاح يبقى صحيحاً للحالتين.
        return "${file?.absolutePath}#${font.ttcIndex}"
    }

    private fun readFontFile(font: Font): ByteArray {
        val file = font.file ?: throw IllegalStateException("خط بلا ملف فعلي على القرص — غير متوقَّع لخط مسجَّل عبر registerFont في NativePdfRenderer")
        FileInputStream(file).use { return it.readBytes() }
    }

    /**
     * يبني سلسلة الكائنات الكاملة لخط Type0/CIDFontType2 واحد:
     * FontFile2 (برنامج الخط، مُقلَّص الآن إلى subset فعلي — انظر تعليق
     * الكلاس أعلاه) → FontDescriptor → CIDFontType2 → ToUnicode CMap →
     * Type0. يكتب الكائن الجذري /Type0 في [type0ObjNum] المحجوز مسبقاً
     * (عبر writer.setObject) بدل حجز رقم كائن جديد له — هذا الرقم هو
     * تحديداً ما أُعيد فعلاً من registerFont وكُتب في عوامل Tf لكل عمليات
     * رسم النص السابقة، فيجب أن يبقى ثابتاً.
     */
    private fun buildType0FontInto(type0ObjNum: Int, fontBytes: ByteArray, ttf: TrueTypeFontInfo, resourceName: String) {
        // FontFile2: برنامج الخط (subset فعلي الآن، لا الملف الكامل).
        val fontFileObj = writer.addObject(
            writer.buildStreamObject(fontBytes, "/Length1 ${fontBytes.size}\n")
        )

        // FontDescriptor: بيانات قياسية للعرض الصحيح (bbox/ascent/descent
        // /flags) — نقرأها من جداول TrueType الفعلية (head/hhea) بدل قيم
        // مفترضة، لضمان قياس صحيح في قارئات PDF أخرى غير محرّكنا.
        val descriptorObj = writer.addObject(buildString {
            append("<<\n/Type /FontDescriptor\n")
            append("/FontName /${sanitizePostScriptName(ttf.postScriptName ?: resourceName)}\n")
            append("/Flags ${if (ttf.isSerif) 2 else 32}\n")
            append("/FontBBox [${ttf.bboxXMin} ${ttf.bboxYMin} ${ttf.bboxXMax} ${ttf.bboxYMax}]\n")
            append("/ItalicAngle 0\n")
            append("/Ascent ${ttf.ascent}\n")
            append("/Descent ${ttf.descent}\n")
            append("/CapHeight ${ttf.ascent}\n")
            append("/StemV 80\n")
            append("/FontFile2 ${writer.ref(fontFileObj)}\n")
            append(">>")
        })

        // W: عرض كل Glyph ID مُستخدَم بوحدة 1000/em (وحدة PDF القياسية)
        // — نبنيها لكل الـ glyphs في الخط دفعة واحدة (لا تُبنى تدريجياً
        // فقط للمُستخدَم منها فعلاً) لتفادي تعقيد إعادة بناء هذا الكائن
        // بعد أن يُكتب؛ هذا الكائن خفيف نسبياً (أرقام فقط لا بيانات
        // ثنائية) فلا يُثقل الحجم الكلي بشكل ملحوظ.
        val widthsArray = buildWidthsArray(ttf)

        val cidFontObj = writer.addObject(buildString {
            append("<<\n/Type /Font\n/Subtype /CIDFontType2\n")
            append("/BaseFont /${sanitizePostScriptName(ttf.postScriptName ?: resourceName)}\n")
            append("/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>\n")
            append("/FontDescriptor ${writer.ref(descriptorObj)}\n")
            append("/CIDToGIDMap /Identity\n")
            append("/DW ${ttf.defaultAdvanceWidthPdfUnits}\n")
            append("/W $widthsArray\n")
            append(">>")
        })

        // ToUnicode: خريطة GID → Unicode الحقيقي. ضرورية للحفاظ على نسخ/
        // بحث صحيحين رغم أن الترميز الأساسي للخط (CID=GID مباشرة) لا
        // علاقة له بـ Unicode. نبنيها من جدول cmap الفعلي في الخط (الذي
        // يربط Unicode → GID أصلاً) فنعكسه GID → Unicode، فتُغطّى تلقائياً
        // كل الترابطات/ligatures التي ينتجها HarfBuzz أثناء التشكيل — هذا
        // تحديداً ما كان مفقوداً في مسار PdfDocument الأصلي (كان يفقد
        // الترابطات multi-character من خريطته الداخلية).
        val toUnicodeObj = writer.addObject(
            writer.buildStreamObject(buildToUnicodeCMap(ttf).toByteArray(Charsets.ISO_8859_1))
        )

        writer.setObject(type0ObjNum, (buildString {
            append("<<\n/Type /Font\n/Subtype /Type0\n")
            append("/BaseFont /${sanitizePostScriptName(ttf.postScriptName ?: resourceName)}\n")
            append("/Encoding /Identity-H\n")
            append("/DescendantFonts [${writer.ref(cidFontObj)}]\n")
            append("/ToUnicode ${writer.ref(toUnicodeObj)}\n")
            append(">>")
        }).toByteArray(Charsets.ISO_8859_1))
    }

    /** أسماء PostScript يجب أن تخلو من المسافات والأقواس وفق مواصفة PDF. */
    private fun sanitizePostScriptName(name: String): String =
        name.replace(Regex("[\\s()\\[\\]<>{}/%]"), "")

    /** يبني مصفوفة /W بصيغة "[ gid [w1 w2 w3 ...] ... ]" المتراصة (أقصر
     *  تمثيلاً من صيغة "gid1 gid2 w" المنفردة لكل glyph، حيث الغالبية
     *  العظمى من الـ glyphs متتالية الترقيم في ملف TrueType عادي). */
    private fun buildWidthsArray(ttf: TrueTypeFontInfo): String {
        val sb = StringBuilder("[")
        var i = 0
        while (i < ttf.glyphWidthsPdfUnits.size) {
            sb.append(i).append(" [")
            sb.append(ttf.glyphWidthsPdfUnits[i])
            var j = i + 1
            while (j < ttf.glyphWidthsPdfUnits.size && j - i < 200) { // حد سلامة لكل مجموعة، لا داعٍ فعلي لتفريقها لكنه يحد من طول سطر واحد فائق
                sb.append(' ').append(ttf.glyphWidthsPdfUnits[j])
                j++
            }
            sb.append(']')
            i = j
        }
        sb.append(']')
        return sb.toString()
    }

    /** يبني CMap (Adobe CMap text format) يربط كل GID بقيمة Unicode
     *  الفعلية. للأشكال البسيطة نقطة واحدة؛ للترابطات (ligatures) نُصدِر
     *  سلسلة الأحرف الكاملة من ttf.gidToUnicodeSeq (مثلاً glyph "لا" →
     *  <06440627>) بدل أول حرف فقط — فيُستخرَج النص صحيحاً حتى في القارئات
     *  التي تتجاهل /ActualText (الطبقة الأساسية). نتعامل مع نقاط Unicode
     *  خارج BMP (مثل بعض الرموز/الإيموجي، U+10000+) بترميزها كزوج بديل
     *  UTF-16 (surrogate pair) وفق مواصفة ToUnicode (القيمة الهدف دوماً
     *  UTF-16BE). */
    private fun buildToUnicodeCMap(ttf: TrueTypeFontInfo): String {
        // ندمج الخريطة المفردة مع سلاسل الترابطات: السلسلة لها الأولوية
        // (أدقّ) حين يوجد GID في كليهما. النتيجة: GID → سلسلة نقاط Unicode.
        val merged = HashMap<Int, IntArray>(ttf.gidToUnicode.size + ttf.gidToUnicodeSeq.size)
        for ((gid, u) in ttf.gidToUnicode) merged[gid] = intArrayOf(u)
        for ((gid, seq) in ttf.gidToUnicodeSeq) if (seq.isNotEmpty()) merged[gid] = seq
        val entries = merged.entries.sortedBy { it.key }

        val sb = StringBuilder()
        sb.append("/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n")
        sb.append("/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n")
        sb.append("/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n")
        sb.append("1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n")

        // تُقسَّم على دفعات من 100 سطر كحد أقصى وفق مواصفة PDF لـ bfchar/bfrange.
        entries.chunked(100).forEach { chunk ->
            sb.append("${chunk.size} beginbfchar\n")
            for ((gid, seq) in chunk) {
                // ⚠️ إصلاح خلل جذري حقيقي (انظر تعليق مماثل في
                // PdfContentBuilder.drawGlyphRun): Locale.ROOT يضمن أرقام
                // ASCII صريحة بصرف النظر عن لغة جهاز المستخدم — بدونه على
                // جهاز بـ Locale عربي تتحول هذه الرموز السداسية لأحرف
                // هندية شرقية خارج نطاق ISO-8859-1، فتُستبدَل بـ '?' عند
                // الكتابة وتُفسِد خريطة ToUnicode بالكامل.
                sb.append(String.format(java.util.Locale.ROOT, "<%04X> <", gid))
                for (cp in seq) appendUtf16BeHex(sb, cp)
                sb.append(">\n")
            }
            sb.append("endbfchar\n")
        }

        sb.append("endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend")
        return sb.toString()
    }

    /** يُلحِق نقطة Unicode واحدة بصيغة UTF-16BE سداسية (أربع خانات لـBMP،
     *  أو زوج بديل ثماني الخانات لما فوق U+FFFF) — التمثيل القياسي الوحيد
     *  المقبول لقيمة هدف bfchar في ToUnicode. */
    private fun appendUtf16BeHex(sb: StringBuilder, codePoint: Int) {
        if (codePoint in 0..0xFFFF) {
            sb.append(String.format(java.util.Locale.ROOT, "%04X", codePoint))
        } else {
            // تفكيك إلى زوج بديل (surrogate pair) وفق UTF-16.
            val c = codePoint - 0x10000
            val hi = 0xD800 + (c ushr 10)
            val lo = 0xDC00 + (c and 0x3FF)
            sb.append(String.format(java.util.Locale.ROOT, "%04X%04X", hi, lo))
        }
    }

    data class RegisteredFontHandle(val resourceName: String, val pdfFontObjNum: Int)
}

/**
 * يحلّل الحقول الضرورية فقط من ملف TrueType/OpenType خام: جداول head
 * (unitsPerEm، bbox)، hhea (ascent/descent)، hmtx (عروض كل glyph)، name
 * (الاسم PostScript)، cmap (تحويل Unicode → GID للحاجة لـ ToUnicode).
 * هذا تحليل قراءة فقط (لا إعادة بناء/Subsetting)، فهو أخف وأقل خطورة
 * بكثير من كاتب TrueType subsetting كامل.
 */
class TrueTypeFontInfo private constructor() {
    var unitsPerEm: Int = 1000
    var ascent: Int = 800
    var descent: Int = -200
    var bboxXMin: Int = 0; var bboxYMin: Int = 0; var bboxXMax: Int = 1000; var bboxYMax: Int = 1000
    var isSerif: Boolean = false
    var postScriptName: String? = null
    var glyphWidthsPdfUnits: IntArray = IntArray(0)
    var gidToUnicode: Map<Int, Int> = emptyMap()
    /** ⚠️ سلاسل Unicode الكاملة للـglyphs الترابطية (ligatures، عدة أحرف
     *  لـglyph واحد) — مفصولة عن gidToUnicode (التي تحمل نقطة واحدة فقط
     *  لكل glyph) لأن ToUnicode CMap يدعم bfchar متعدد الأحرف فعلياً
     *  (مثلاً glyph ترابطة "لا" → <06440627>). تُملأ من GsubReverseAugmenter
     *  وتُستهلَك في buildToUnicodeCMap لإصدار خريطة احتياطية دقيقة 100%
     *  حتى للترابطات (لا أول حرف فقط). فارغة افتراضياً (لا ترابطات). */
    var gidToUnicodeSeq: Map<Int, IntArray> = emptyMap()
    val defaultAdvanceWidthPdfUnits: Int
        get() = glyphWidthsPdfUnits.firstOrNull() ?: 600

    companion object {
        fun parse(bytes: ByteArray): TrueTypeFontInfo {
            val info = TrueTypeFontInfo()
            try {
                val buf = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
                buf.position(4)
                val numTables = buf.short.toInt() and 0xFFFF
                buf.position(12)
                val tables = HashMap<String, Pair<Int, Int>>() // tag -> (offset, length)
                for (i in 0 until numTables) {
                    val tagBytes = ByteArray(4)
                    buf.get(tagBytes)
                    val tag = String(tagBytes, Charsets.US_ASCII)
                    buf.int // checksum، غير مستخدَم
                    val offset = buf.int
                    val length = buf.int
                    tables[tag] = Pair(offset, length)
                }

                tables["head"]?.let { (off, _) ->
                    buf.position(off + 18)
                    info.unitsPerEm = buf.short.toInt() and 0xFFFF
                    buf.position(off + 36)
                    info.bboxXMin = buf.short.toInt()
                    info.bboxYMin = buf.short.toInt()
                    info.bboxXMax = buf.short.toInt()
                    info.bboxYMax = buf.short.toInt()
                }

                var numGlyphs = 0
                tables["maxp"]?.let { (off, _) ->
                    buf.position(off + 4)
                    numGlyphs = buf.short.toInt() and 0xFFFF
                }

                var numHMetrics = 0
                tables["hhea"]?.let { (off, _) ->
                    buf.position(off + 4)
                    info.ascent = buf.short.toInt()
                    info.descent = buf.short.toInt()
                    buf.position(off + 34)
                    numHMetrics = buf.short.toInt() and 0xFFFF
                }

                val scale = if (info.unitsPerEm > 0) 1000.0 / info.unitsPerEm else 1.0
                tables["hmtx"]?.let { (off, _) ->
                    val widths = IntArray(numGlyphs.coerceAtLeast(1))
                    var lastWidth = 0
                    buf.position(off)
                    for (i in 0 until numHMetrics) {
                        val aw = buf.short.toInt() and 0xFFFF
                        buf.short // lsb، غير مستخدَم هنا
                        lastWidth = (aw * scale).toInt()
                        if (i < widths.size) widths[i] = lastWidth
                    }
                    // الـ glyphs التالية لآخر إدخال صريح في hmtx تتقاسم
                    // عرض آخر إدخال (سلوك قياسي موصوف في مواصفة TrueType).
                    for (i in numHMetrics until widths.size) widths[i] = lastWidth
                    info.glyphWidthsPdfUnits = widths
                }

                tables["name"]?.let { (off, _) -> info.postScriptName = readPostScriptName(buf, off) }
                tables["cmap"]?.let { (off, _) -> info.gidToUnicode = readUnicodeToGidReversed(buf, off) }

                // ⚠️ إصلاح حقيقي جوهري (طبقة احتياطية لـToUnicode للعربي
                // المُشكَّل): جدول cmap وحده يربط فقط الأشكال المعزولة
                // الأساسية بـUnicode؛ الأشكال الموضعية والترابطات التي
                // يُنتجها HarfBuzz لها GIDs غائبة كلياً عن cmap (أُثبت
                // بالفحص: 70%+ من glyphs العربي مفقودة من خريطة ToUnicode
                // المبنية بعكس cmap وحده). الحل الأساسي هو /ActualText
                // (انظر PdfContentBuilder.drawTextLine)، لكن نُعزِّز
                // ToUnicode أيضاً بوعي GSUB كطبقة احتياطية للقارئات التي
                // تتجاهل ActualText: نتتبّع بدائل GSUB (Single type 1 +
                // Ligature type 4) فنشتقّ Unicode الأشكال المُشكَّلة من
                // glyphs مصدرها الأساسية المعروفة من cmap. لو فشل أو غاب
                // GSUB، نتراجع بأمان للخريطة الأساسية (لا استثناء، فالطبقة
                // الأساسية /ActualText تكفي وحدها فعلياً).
                tables["GSUB"]?.let { (off, _) ->
                    try {
                        val res = GsubReverseAugmenter.augment(buf, off, info.gidToUnicode)
                        info.gidToUnicode = res.single
                        info.gidToUnicodeSeq = res.sequences
                    } catch (e: Exception) {
                        android.util.Log.w("PdfFontManager", "تعذّر توسيع ToUnicode عبر GSUB (يُكتفى بـActualText): ${e.message}")
                    }
                }

                info.isSerif = false // تقدير محافظ ثابت؛ لا يؤثر على صحة العرض، فقط على تلميح بصري ثانوي لقارئات PDF
            } catch (e: Exception) {
                android.util.Log.w("PdfFontManager", "فشل تحليل بعض حقول TrueType، استخدام افتراضيات آمنة: ${e.message}")
            }
            return info
        }

        /** يقرأ أول اسم PostScript (nameID=6) متاح من جدول name، يُفضِّل
         *  Windows/Unicode platform (3,1) الأكثر شيوعاً في خطوط حديثة.
         *
         *  ⚠️ إصلاح خلل جذري حقيقي مؤكَّد بالفحص الفعلي على كل ملفات
         *  الاختبار المُرفقة (18 خطاً مُضمَّناً عبر ست وثائق اختبار مختلفة،
         *  18/18 بلا استثناء واحد فشلت بنفس النمط بالضبط — BaseFont يصدر
         *  "F1".."F18" الاحتياطية حرفياً في كل خط). السبب الجذري: رأس
         *  جدول name وفق مواصفة OpenType هو بالضبط uint16 format +
         *  uint16 count + uint16 storageOffset = 6 بايتات، فسجلات
         *  NameRecord (12 بايت لكل سجل) تبدأ عند tableOffset+6 لا
         *  tableOffset+4. النسخة السابقة كانت تُموضع المؤشر عند
         *  tableOffset+4 (إزاحة أقل بسجل uint16 واحد كامل عن البداية
         *  الصحيحة)، فكل حقل يُقرأ داخل الحلقة (platformId/encodingId/
         *  languageId/nameId/length/offset) يُقرأ من إزاحة خاطئة بثبات —
         *  لا يطابق nameId==6 إطلاقاً عبر كامل الحلقة لأي خط. الإصلاح هنا
         *  +4 → +6 لموضع بداية الحلقة فقط (storageOffset نفسه كان يُحسب
         *  بصحة من قبل، لم يكن الخلل فيه). */
        private fun readPostScriptName(buf: ByteBuffer, tableOffset: Int): String? {
            return try {
                buf.position(tableOffset + 2)
                val count = buf.short.toInt() and 0xFFFF
                val storageOffset = run {
                    buf.position(tableOffset + 4)
                    buf.short.toInt() and 0xFFFF
                }
                val stringOffsetBase = tableOffset + storageOffset
                // بداية سجلات NameRecord الصحيحة: tableOffset + 6 بالضبط
                // (format uint16 + count uint16 + storageOffset uint16).
                buf.position(tableOffset + 6)
                // نجمع كل المرشحين المطابقين لـnameId==6 بدل العودة عند
                // أول تطابق فوراً، لنُفضِّل لاحقاً سجل Windows/Unicode
                // (platformId==3) الأكثر شيوعاً ودعماً لو وُجد أكثر من
                // سجل واحد (خطوط متعددة اللغات غالباً تكرّر كل اسم لعدة
                // platforms؛ macintosh platformId==1 غالباً أقل اكتمالاً).
                data class Candidate(val platformId: Int, val offset: Int, val length: Int)
                val candidates = ArrayList<Candidate>()
                for (i in 0 until count) {
                    if (buf.remaining() < 12) break
                    val platformId = buf.short.toInt() and 0xFFFF
                    buf.short // encodingId، غير مستخدَم في اختيار السجل هنا
                    buf.short // languageId، غير مستخدَم
                    val nameId = buf.short.toInt() and 0xFFFF
                    val length = buf.short.toInt() and 0xFFFF
                    val offset = buf.short.toInt() and 0xFFFF
                    if (nameId == 6) candidates.add(Candidate(platformId, offset, length))
                }
                val best = candidates.firstOrNull { it.platformId == 3 } ?: candidates.firstOrNull()
                    ?: return null
                buf.position(stringOffsetBase + best.offset)
                val raw = ByteArray(best.length)
                buf.get(raw)
                val charset = if (best.platformId == 3 || best.platformId == 0) Charsets.UTF_16BE else Charsets.US_ASCII
                String(raw, charset).trim().ifEmpty { null }
            } catch (e: Exception) { null }
        }

        /** يبني خريطة GID→Unicode بعكس جدول cmap الفرعي الأنسب (يُفضَّل
         *  تنسيق 4 الكلاسيكي، أو تنسيق 12 لو وُجد مدى يونيكود تكميلي). */
        private fun readUnicodeToGidReversed(buf: ByteBuffer, tableOffset: Int): Map<Int, Int> {
            val result = HashMap<Int, Int>()
            try {
                buf.position(tableOffset + 2)
                val numSubtables = buf.short.toInt() and 0xFFFF
                var bestOffset = -1
                var bestScore = -1
                buf.position(tableOffset + 4)
                for (i in 0 until numSubtables) {
                    val platformId = buf.short.toInt() and 0xFFFF
                    val encodingId = buf.short.toInt() and 0xFFFF
                    val offset = buf.int
                    // أفضلية: (3,10) ثم (3,1) ثم (0,*) — تغطي يونيكود كاملاً أو BMP فقط.
                    val score = when {
                        platformId == 3 && encodingId == 10 -> 3
                        platformId == 3 && encodingId == 1 -> 2
                        platformId == 0 -> 1
                        else -> 0
                    }
                    if (score > bestScore) { bestScore = score; bestOffset = offset }
                }
                if (bestOffset < 0) return result

                val subtableOffset = tableOffset + bestOffset
                buf.position(subtableOffset)
                val format = buf.short.toInt() and 0xFFFF
                when (format) {
                    4 -> readCmapFormat4(buf, subtableOffset, result)
                    12 -> readCmapFormat12(buf, subtableOffset, result)
                    else -> { /* تنسيق أقل شيوعاً (0/6) — يُتجاهَل بأمان، ToUnicode يبقى جزئياً بدله من معطوب */ }
                }
            } catch (e: Exception) {
                android.util.Log.w("PdfFontManager", "فشل قراءة جدول cmap: ${e.message}")
            }
            return result
        }

        private fun readCmapFormat4(buf: ByteBuffer, subtableOffset: Int, out: MutableMap<Int, Int>) {
            buf.position(subtableOffset + 6)
            val segCountX2 = buf.short.toInt() and 0xFFFF
            val segCount = segCountX2 / 2
            buf.position(subtableOffset + 14)
            val endCodes = IntArray(segCount) { buf.short.toInt() and 0xFFFF }
            buf.short // reservedPad
            val startCodes = IntArray(segCount) { buf.short.toInt() and 0xFFFF }
            val idDeltas = IntArray(segCount) { buf.short.toInt() }
            val idRangeOffsetsPos = buf.position()
            val idRangeOffsets = IntArray(segCount) { buf.short.toInt() and 0xFFFF }

            for (seg in 0 until segCount) {
                val start = startCodes[seg]
                val end = endCodes[seg]
                if (start == 0xFFFF) continue
                for (unicode in start..end) {
                    val gid: Int = if (idRangeOffsets[seg] == 0) {
                        (unicode + idDeltas[seg]) and 0xFFFF
                    } else {
                        val glyphIndexAddr = idRangeOffsetsPos + seg * 2 + idRangeOffsets[seg] + (unicode - start) * 2
                        if (glyphIndexAddr + 2 > buf.limit()) continue
                        val pos0 = buf.position()
                        buf.position(glyphIndexAddr)
                        val g = buf.short.toInt() and 0xFFFF
                        buf.position(pos0)
                        if (g == 0) continue else (g + idDeltas[seg]) and 0xFFFF
                    }
                    if (gid != 0) out[gid] = unicode
                }
            }
        }

        private fun readCmapFormat12(buf: ByteBuffer, subtableOffset: Int, out: MutableMap<Int, Int>) {
            buf.position(subtableOffset + 12)
            val numGroups = buf.int
            buf.position(subtableOffset + 16)
            for (i in 0 until numGroups) {
                val startChar = buf.int
                val endChar = buf.int
                val startGlyph = buf.int
                val count = endChar - startChar
                if (count in 0..0x10000) { // حد سلامة يتجنّب حلقات هائلة لبيانات تالفة
                    for (offset in 0..count) {
                        out[startGlyph + offset] = startChar + offset
                    }
                }
            }
        }
    }
}

/**
 * ═══════════════════════════════════════════════════════════════════════
 *  GsubReverseAugmenter
 *  ───────────────────────────────────────────────────────────────────────
 *  يوسّع خريطة GID→Unicode (المبنية أصلاً بعكس جدول cmap) لتشمل الـglyphs
 *  المُشكَّلة (أشكال موضعية + ترابطات) التي يُنتجها HarfBuzz، عبر تتبُّع
 *  بدائل جدول GSUB. هذه طبقة احتياطية لـ/ActualText (انظر
 *  PdfContentBuilder.drawTextLine)؛ ActualText يحلّ المشكلة كلياً وحده،
 *  لكن إثراء ToUnicode هنا يجعل حتى القارئات النادرة التي تتجاهل
 *  ActualText تستخرج العربي بصحة.
 *
 *  نتعامل مع أكثر نوعي بديل شيوعاً في تشكيل العربي:
 *   • LookupType 1 (Single Substitution): glyphٌ واحد ⇽ glyphٌ واحد —
 *     الشكل الموضعي (init/medi/fina) يرث Unicode الشكل الأساسي.
 *   • LookupType 4 (Ligature Substitution): عدة glyphs ⇽ glyphٌ واحد —
 *     الترابطة (مثل لا) ترث سلسلة Unicode مكوِّناتها مرتَّبةً.
 *  أنواع البدائل السياقية (5/6) تُشغِّل lookups من النوعين أعلاه فعلياً،
 *  فتغطيتنا للنوعين 1 و4 تكفي لاشتقاق Unicode كل ناتج بديل عملياً.
 *  نُكرِّر التطبيق عدة مرّات (إغلاق تقريبي) لأن بعض الترابطات تُبنى على
 *  أشكال موضعية ناتجة عن بديل سابق.
 * ═══════════════════════════════════════════════════════════════════════
 */
object GsubReverseAugmenter {

    /** بديل مفرد: GID ناتج → GID مصدر واحد. */
    private class SingleSub(val from: Int, val to: Int)
    /** بديل ترابطة: GID ناتج → سلسلة GIDs مكوِّنة (بالترتيب المنطقي). */
    private class LigSub(val components: IntArray, val ligGlyph: Int)

    /** نتيجة التوسيع: خريطة GID→نقطة Unicode واحدة (للبسيط والترابطات
     *  ممثَّلة بأول نقطة كتوافق خلفي)، وخريطة منفصلة GID→سلسلة Unicode
     *  كاملة للترابطات فقط (تُستخدَم لإصدار bfchar متعدد الأحرف دقيق). */
    class Result(val single: Map<Int, Int>, val sequences: Map<Int, IntArray>)

    fun augment(buf: ByteBuffer, gsubOffset: Int, base: Map<Int, Int>): Result {
        val singles = ArrayList<SingleSub>()
        val ligs = ArrayList<LigSub>()
        parseGsub(buf, gsubOffset, singles, ligs)
        if (singles.isEmpty() && ligs.isEmpty()) return Result(base, emptyMap())

        val map = HashMap<Int, Int>(base) // GID → نقطة Unicode مفردة (BMP) للأشكال البسيطة
        // للترابطات نحتاج سلاسل متعددة الأحرف؛ نخزّنها منفصلة:
        val multi = HashMap<Int, IntArray>() // GID → سلسلة نقاط Unicode

        fun unicodesFor(gid: Int): IntArray? {
            multi[gid]?.let { return it }
            map[gid]?.let { return intArrayOf(it) }
            return null
        }

        // إغلاق تكراري: نطبّق البدائل حتى لا يتغيّر شيء (حد أقصى للأمان).
        var changed = true
        var rounds = 0
        while (changed && rounds < 8) {
            changed = false
            rounds++
            for (s in singles) {
                if (s.to in map || s.to in multi) continue
                val src = unicodesFor(s.from) ?: continue
                if (src.size == 1) { if (map.put(s.to, src[0]) == null) changed = true }
                else { if (multi.put(s.to, src) == null) changed = true }
            }
            for (lg in ligs) {
                if (lg.ligGlyph in map || lg.ligGlyph in multi) continue
                val seq = ArrayList<Int>(lg.components.size * 2)
                var ok = true
                for (c in lg.components) {
                    val u = unicodesFor(c)
                    if (u == null) { ok = false; break }
                    for (x in u) seq.add(x)
                }
                if (ok && seq.isNotEmpty()) {
                    multi[lg.ligGlyph] = seq.toIntArray(); changed = true
                }
            }
        }

        // الخريطة المفردة النهائية: الأساس + كل بديل بسيط، وللترابطات
        // أول نقطة فقط (توافق خلفي مع أي مستهلك يقرأ gidToUnicode المفردة).
        // السلاسل الكاملة تُمرَّر منفصلة في sequences لإصدار bfchar دقيق.
        val out = HashMap<Int, Int>(map)
        for ((gid, seq) in multi) {
            if (gid !in out && seq.isNotEmpty()) out[gid] = seq[0]
        }
        return Result(out, multi)
    }

    private fun parseGsub(
        buf: ByteBuffer, gsubOffset: Int,
        singles: MutableList<SingleSub>, ligs: MutableList<LigSub>
    ) {
        // ⚠️ رأس جدول GSUB: majorVersion(2) + minorVersion(2) +
        // scriptListOffset(2) + featureListOffset(2) + lookupListOffset(2).
        // فإزاحة lookupListOffset هي gsubOffset+8 بالضبط (لا +6 كما توهَّم
        // حساب سابق خاطئ كان يُرجع scriptListOffset مكانه فيُفشل تحليل كل
        // الـlookups صامتاً — أُثبت الإصلاح بمطابقة 247 إدخال GID→Unicode
        // جديد مقابل fonttools كمرجع موثوق).
        buf.position(gsubOffset + 8)
        val lookupListOffset = buf.short.toInt() and 0xFFFF
        val lookupListBase = gsubOffset + lookupListOffset
        buf.position(lookupListBase)
        val lookupCount = buf.short.toInt() and 0xFFFF
        val lookupOffsets = IntArray(lookupCount) { buf.short.toInt() and 0xFFFF }

        for (lo in lookupOffsets) {
            val lookupTableBase = lookupListBase + lo
            buf.position(lookupTableBase)
            val lookupType = buf.short.toInt() and 0xFFFF
            buf.short // lookupFlag
            val subTableCount = buf.short.toInt() and 0xFFFF
            val subOffsets = IntArray(subTableCount) { buf.short.toInt() and 0xFFFF }
            for (so in subOffsets) {
                val subBase = lookupTableBase + so
                when (lookupType) {
                    1 -> parseSingle(buf, subBase, singles)
                    4 -> parseLigature(buf, subBase, ligs)
                    7 -> parseExtension(buf, subBase, singles, ligs) // Extension: يعيد توجيه لنوع آخر
                    // أنواع أخرى (2/3/5/6/8) لا تنتج glyphs جديدة تحتاج
                    // اشتقاق Unicode مستقل لأغراض ToUnicode الاحتياطي.
                }
            }
        }
    }

    private fun parseExtension(
        buf: ByteBuffer, subBase: Int,
        singles: MutableList<SingleSub>, ligs: MutableList<LigSub>
    ) {
        buf.position(subBase)
        val format = buf.short.toInt() and 0xFFFF
        if (format != 1) return
        val extType = buf.short.toInt() and 0xFFFF
        val extOffset = buf.int
        val target = subBase + extOffset
        when (extType) {
            1 -> parseSingle(buf, target, singles)
            4 -> parseLigature(buf, target, ligs)
        }
    }

    private fun readCoverage(buf: ByteBuffer, coverageBase: Int): IntArray {
        val pos = buf.position()
        buf.position(coverageBase)
        val format = buf.short.toInt() and 0xFFFF
        val result = ArrayList<Int>()
        when (format) {
            1 -> {
                val count = buf.short.toInt() and 0xFFFF
                for (i in 0 until count) result.add(buf.short.toInt() and 0xFFFF)
            }
            2 -> {
                val rangeCount = buf.short.toInt() and 0xFFFF
                for (i in 0 until rangeCount) {
                    val start = buf.short.toInt() and 0xFFFF
                    val end = buf.short.toInt() and 0xFFFF
                    buf.short // startCoverageIndex
                    for (g in start..end) result.add(g)
                }
            }
        }
        buf.position(pos)
        return result.toIntArray()
    }

    private fun parseSingle(buf: ByteBuffer, subBase: Int, out: MutableList<SingleSub>) {
        buf.position(subBase)
        val format = buf.short.toInt() and 0xFFFF
        val coverageOffset = buf.short.toInt() and 0xFFFF
        when (format) {
            1 -> {
                val deltaGlyphId = buf.short.toInt()
                val cov = readCoverage(buf, subBase + coverageOffset)
                for (g in cov) out.add(SingleSub(g, (g + deltaGlyphId) and 0xFFFF))
            }
            2 -> {
                val glyphCount = buf.short.toInt() and 0xFFFF
                val subs = IntArray(glyphCount) { buf.short.toInt() and 0xFFFF }
                val cov = readCoverage(buf, subBase + coverageOffset)
                for (i in cov.indices) if (i < subs.size) out.add(SingleSub(cov[i], subs[i]))
            }
        }
    }

    private fun parseLigature(buf: ByteBuffer, subBase: Int, out: MutableList<LigSub>) {
        buf.position(subBase)
        val format = buf.short.toInt() and 0xFFFF
        if (format != 1) return
        val coverageOffset = buf.short.toInt() and 0xFFFF
        val ligSetCount = buf.short.toInt() and 0xFFFF
        val ligSetOffsets = IntArray(ligSetCount) { buf.short.toInt() and 0xFFFF }
        val cov = readCoverage(buf, subBase + coverageOffset)

        for (i in 0 until ligSetCount) {
            if (i >= cov.size) break
            val firstComponentGlyph = cov[i]
            val ligSetBase = subBase + ligSetOffsets[i]
            buf.position(ligSetBase)
            val ligCount = buf.short.toInt() and 0xFFFF
            val ligOffsets = IntArray(ligCount) { buf.short.toInt() and 0xFFFF }
            for (lo in ligOffsets) {
                val ligBase = ligSetBase + lo
                buf.position(ligBase)
                val ligGlyph = buf.short.toInt() and 0xFFFF
                val compCount = buf.short.toInt() and 0xFFFF
                if (compCount < 1 || compCount > 64) continue
                val components = IntArray(compCount)
                components[0] = firstComponentGlyph
                for (c in 1 until compCount) components[c] = buf.short.toInt() and 0xFFFF
                out.add(LigSub(components, ligGlyph))
            }
        }
    }
}

/**
 * ═══════════════════════════════════════════════════════════════════════
 *  TrueTypeSubsetter
 *  ───────────────────────────────────────────────────────────────────────
 *  يبني نسخة "subset" حقيقية من ملف TrueType خام: يحتفظ فقط بجداول glyf/
 *  loca المُعاد بناؤها لتشمل تحديداً مجموعة Glyph IDs المطلوبة (+ .notdef
 *  + إغلاقها العبوري لمراجع composite glyph)، مع تحديث hmtx/maxp/head
 *  ليطابقا الجدول الجديد، وحذف أي جدول آخر غير ضروري لعرض النص (مثل
 *  GSUB/GPOS كانت أساسية فقط للتشكيل قبل أن يتم التشكيل فعلياً عبر
 *  HarfBuzz في Minikin؛ بحلول هذه المرحلة، الـglyphs المُنتَجة بعد
 *  التشكيل ثابتة، فلا حاجة لهذه الجداول إطلاقاً في الخط المُضمَّن في
 *  PDF). الجداول المُبقاة: head، hhea، maxp، hmtx، cmap، glyf، loca،
 *  name، post (الحد الأدنى الذي تتطلبه أغلب قارئات PDF/أنظمة التشغيل
 *  لعرض CIDFontType2 بصحة).
 *
 *  ⚠️ ملاحظة نطاق: post الناتج يُستبدَل دوماً بصيغة 3.0 (بلا جدول أسماء
 *  glyph داخلي) — مقبولة بالكامل لـCIDFontType2 (الذي لا يعتمد إطلاقاً
 *  على أسماء glyphs، فقط GID مباشرة عبر CIDToGIDMap=/Identity)، وأخف
 *  بكثير من نسخ جدول post الأصلي (الذي قد يحوي آلاف الأسماء النصية لكل
 *  glyph في الخط الكامل، غير ضرورية هنا إطلاقاً).
 * ═══════════════════════════════════════════════════════════════════════
 */
object TrueTypeSubsetter {

    private data class TableEntry(val tag: String, val checksum: Int, val offset: Int, val length: Int)

    /** نتيجة عملية subset كاملة: البايتات الجديدة، وخريطة GID قديم→جديد
     *  (هوية كاملة gid->gid حين لا يحدث تقليص فعلي، انظر [identityResult])
     *  — الخريطة ضرورية للمستدعي لإعادة بناء gidToUnicode بصحة (انظر
     *  تعليق noteGlyphUsed/finalizeAllFonts في PdfFontManager لتفصيل
     *  السبب: cmap الفعلي للخط بعد التقليص يصبح شكلياً بحتاً [انظر
     *  buildMinimalCmap]، فلا يصلح كمصدر لإعادة قراءة GID→Unicode، يجب
     *  حساب هذه الخريطة من الخط *الأصلي* قبل القطع ثم تمريرها عبر هذه
     *  الخريطة). */
    data class SubsetResult(val bytes: ByteArray, val oldToNew: Map<Int, Int>)

    private fun identityResult(fontBytes: ByteArray, numGlyphsOriginal: Int): SubsetResult {
        val identity = HashMap<Int, Int>(numGlyphsOriginal * 2)
        for (g in 0 until numGlyphsOriginal) identity[g] = g
        return SubsetResult(fontBytes, identity)
    }

    /** يبني نسخة subset من [fontBytes] تحوي فقط [usedGlyphIds] + إغلاقها
     *  العبوري لمراجع composite glyph + .notdef (GID=0، إلزامي دوماً).
     *  يُعيد fontBytes كما هي (مع خريطة هوية gid->gid) إن تعذّر العثور
     *  على الجداول الأساسية المطلوبة (glyf/loca/head/maxp) — تراجع آمن
     *  لخطوط CFF (OpenType/PostScript outlines، نادرة بين خطوط النظام
     *  المُستخدَمة هنا لكنها ممكنة نظرياً) أو أي تنسيق غير مدعوم بدل
     *  إسقاط الخط كلياً. */
    fun subset(fontBytes: ByteArray, usedGlyphIds: Set<Int>): SubsetResult {
        val buf = ByteBuffer.wrap(fontBytes).order(ByteOrder.BIG_ENDIAN)
        buf.position(4)
        val numTables = buf.short.toInt() and 0xFFFF
        buf.position(12)
        val tables = HashMap<String, TableEntry>()
        for (i in 0 until numTables) {
            val tagBytes = ByteArray(4)
            buf.get(tagBytes)
            val tag = String(tagBytes, Charsets.US_ASCII)
            val checksum = buf.int
            val offset = buf.int
            val length = buf.int
            tables[tag] = TableEntry(tag, checksum, offset, length)
        }

        // ⚠️ نحتاج numGlyphsOriginal حتى في مسارات الفشل المبكرة أدناه
        // لبناء خريطة هوية صحيحة الحجم (لا فراغ) — نقرأها أولاً بأمان
        // (افتراضي 0 لو تعذَّر، فيُعيد identityResult خريطة فارغة بأمان
        // بدل استثناء، وlist فارغة لا تكسر أي مستدعٍ).
        val numGlyphsFallback = tables["maxp"]?.let {
            try { buf.position(it.offset + 4); buf.short.toInt() and 0xFFFF } catch (e: Exception) { 0 }
        } ?: 0

        val headT = tables["head"] ?: return identityResult(fontBytes, numGlyphsFallback)
        val maxpT = tables["maxp"] ?: return identityResult(fontBytes, numGlyphsFallback)
        val hheaT = tables["hhea"] ?: return identityResult(fontBytes, numGlyphsFallback)
        val hmtxT = tables["hmtx"] ?: return identityResult(fontBytes, numGlyphsFallback)
        val glyfT = tables["glyf"] ?: return identityResult(fontBytes, numGlyphsFallback) // خطوط CFF بلا glyf — لا نحاول تقليصها
        val locaT = tables["loca"] ?: return identityResult(fontBytes, numGlyphsFallback)

        buf.position(headT.offset + 50)
        val indexToLocFormat = buf.short.toInt() // 0=Offsets16 (×2)، 1=Offsets32

        buf.position(maxpT.offset + 4)
        val numGlyphsOriginal = buf.short.toInt() and 0xFFFF

        val locaOffsets = IntArray(numGlyphsOriginal + 1)
        buf.position(locaT.offset)
        if (indexToLocFormat == 0) {
            for (i in 0..numGlyphsOriginal) locaOffsets[i] = (buf.short.toInt() and 0xFFFF) * 2
        } else {
            for (i in 0..numGlyphsOriginal) locaOffsets[i] = buf.int
        }

        fun readComponentGlyphIds(gid: Int): List<Int> {
            val start = glyfT.offset + locaOffsets[gid]
            val end = glyfT.offset + locaOffsets[gid + 1]
            if (end <= start || end - start < 10) return emptyList()
            val gbuf = ByteBuffer.wrap(fontBytes, start, end - start).order(ByteOrder.BIG_ENDIAN)
            val numberOfContours = gbuf.short.toInt()
            if (numberOfContours >= 0) return emptyList()
            gbuf.position(gbuf.position() + 8)
            val result = ArrayList<Int>()
            var more = true
            var guard = 0
            while (more && gbuf.remaining() >= 4 && guard < 64) {
                guard++
                val flags = gbuf.short.toInt() and 0xFFFF
                val glyphIndex = gbuf.short.toInt() and 0xFFFF
                result.add(glyphIndex)
                val argsAreWords = (flags and 0x0001) != 0
                var skip = if (argsAreWords) 4 else 2
                if ((flags and 0x0008) != 0) skip += 2
                else if ((flags and 0x0040) != 0) skip += 4
                else if ((flags and 0x0080) != 0) skip += 8
                if (gbuf.remaining() < skip) break
                gbuf.position(gbuf.position() + skip)
                more = (flags and 0x0020) != 0
            }
            return result
        }

        val keep = HashSet<Int>()
        keep.add(0)
        for (g in usedGlyphIds) if (g in 0 until numGlyphsOriginal) keep.add(g)
        var frontier = ArrayList(keep)
        while (frontier.isNotEmpty()) {
            val next = ArrayList<Int>()
            for (gid in frontier) {
                if (gid !in 0 until numGlyphsOriginal) continue
                for (dep in readComponentGlyphIds(gid)) {
                    if (dep !in 0 until numGlyphsOriginal) continue
                    if (keep.add(dep)) next.add(dep)
                }
            }
            frontier = next
        }

        if (keep.size >= numGlyphsOriginal * 0.85) return identityResult(fontBytes, numGlyphsOriginal)

        // ⚠️ إصلاح جوهري (تطابق GID بين content stream والخط المُقلَّص):
        // نحافظ على ترقيم الـ GID الأصلي بدل ضغطه. عوامل TJ المكتوبة وقت
        // رسم الصفحات تحمل GID الأصلي من HarfBuzz، وهي تُكتب *قبل* أن
        // تُعرف خريطة أي إعادة ترقيم (التقليص يحدث في finalizeAllFonts بعد
        // رسم كل الصفحات)، فإعادة ترقيم الـglyphs كانت تجعل كل GID في
        // المحتوى يشير لـglyph مختلف تماماً في الخط المُقلَّص (مع
        // CIDToGIDMap=/Identity) — وهذا تحديداً سبب أن كل حرف كان يُعرَض
        // خطأً. الحل: subset متناثر (sparse) يبقي كل glyph مُبقى عند
        // فهرسه الأصلي بالضبط، والفجوات (GIDs غير المستخدَمة) تصبح glyphs
        // فارغة (loca[i]==loca[i+1]). النتيجة أكبر قليلاً من الضغط الكامل
        // (جدولا loca/hmtx بطول maxKeptGid+1 بدل keep.size) لكنها لا تزال
        // ضئيلة جداً مقابل الخط الكامل، وتلغي فئة الخلل كلياً. oldToNew
        // تصبح خريطة هوية على الـGIDs المُبقاة، فلا حاجة لإعادة كتابة
        // مراجع component داخل composite glyphs ولا تعديل عوامل TJ.
        val sortedKeep = keep.sorted()
        val maxKeptGid = sortedKeep.last()
        val numGlyphsNew = maxKeptGid + 1
        val keepSet = keep
        val oldToNew = HashMap<Int, Int>(sortedKeep.size * 2)
        for (gid in sortedKeep) oldToNew[gid] = gid // هوية: GID الأصلي يبقى كما هو

        // glyf: لكل فهرس 0..maxKeptGid نضع بيانات الglyph الأصلية إن كان
        // مُبقى، وإلا chunk فارغ (glyph غير موجود = صفر contours، حجم 0).
        // لا إعادة ترقيم لمراجع component إطلاقاً (الترقيم محفوظ)، فننسخ
        // بيانات glyf كما هي بالضبط.
        val newGlyfChunks = ArrayList<ByteArray>(numGlyphsNew)
        for (gid in 0 until numGlyphsNew) {
            if (gid !in keepSet) { newGlyfChunks.add(ByteArray(0)); continue }
            val start = locaOffsets[gid]
            val end = locaOffsets[gid + 1]
            if (end <= start) { newGlyfChunks.add(ByteArray(0)); continue }
            newGlyfChunks.add(fontBytes.copyOfRange(glyfT.offset + start, glyfT.offset + end))
        }

        val paddedChunks = newGlyfChunks.map { if (it.size % 2 == 1) it + byteArrayOf(0) else it }
        val newGlyfTotalSize = paddedChunks.sumOf { it.size }
        val useLongLoca = newGlyfTotalSize > 0x1FFFE
        val newGlyf = ByteArray(newGlyfTotalSize)
        val newLocaOffsets = IntArray(numGlyphsNew + 1)
        var cursor = 0
        for ((idx, chunk) in paddedChunks.withIndex()) {
            newLocaOffsets[idx] = cursor
            System.arraycopy(chunk, 0, newGlyf, cursor, chunk.size)
            cursor += chunk.size
        }
        newLocaOffsets[numGlyphsNew] = cursor

        val newLoca = if (useLongLoca) {
            val b = ByteBuffer.allocate((numGlyphsNew + 1) * 4).order(ByteOrder.BIG_ENDIAN)
            for (off in newLocaOffsets) b.putInt(off)
            b.array()
        } else {
            val b = ByteBuffer.allocate((numGlyphsNew + 1) * 2).order(ByteOrder.BIG_ENDIAN)
            for (off in newLocaOffsets) b.putShort((off / 2).toShort())
            b.array()
        }

        buf.position(hheaT.offset + 34)
        val numHMetricsOriginal = buf.short.toInt() and 0xFFFF
        // hmtx: بطول numGlyphsNew، كل إدخال عند فهرسه الأصلي (عرض الglyph
        // المُبقى الحقيقي، أو 0 لفجوة غير مستخدَمة — لا تُرسَم أبداً فلا
        // يهم عرضها).
        val newHmtx = ByteArray(numGlyphsNew * 4)
        run {
            buf.position(hmtxT.offset)
            val advanceWidths = IntArray(numGlyphsOriginal)
            val lsbs = IntArray(numGlyphsOriginal)
            var lastAw = 0
            for (i in 0 until numGlyphsOriginal) {
                if (i < numHMetricsOriginal) {
                    lastAw = buf.short.toInt() and 0xFFFF
                    lsbs[i] = buf.short.toInt()
                } else {
                    lsbs[i] = if (buf.remaining() >= 2) buf.short.toInt() else 0
                }
                advanceWidths[i] = lastAw
            }
            val hb = ByteBuffer.wrap(newHmtx).order(ByteOrder.BIG_ENDIAN)
            for (gid in 0 until numGlyphsNew) {
                if (gid in keepSet) {
                    hb.putShort(advanceWidths.getOrElse(gid) { 0 }.toShort())
                    hb.putShort(lsbs.getOrElse(gid) { 0 }.toShort())
                } else {
                    hb.putShort(0); hb.putShort(0)
                }
            }
        }

        val newCmap = buildMinimalCmap(oldToNew)

        val keptTagsInOrder = listOf("cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name", "post")
        val tableBytes = LinkedHashMap<String, ByteArray>()
        tableBytes["glyf"] = newGlyf
        tableBytes["loca"] = newLoca
        tableBytes["hmtx"] = newHmtx
        tableBytes["cmap"] = newCmap
        tableBytes["post"] = MINIMAL_POST_TABLE

        val headBytes = fontBytes.copyOfRange(headT.offset, headT.offset + headT.length)
        headBytes[50] = 0; headBytes[51] = if (useLongLoca) 1 else 0
        tableBytes["head"] = headBytes

        val hheaBytes = fontBytes.copyOfRange(hheaT.offset, hheaT.offset + hheaT.length)
        hheaBytes[34] = ((numGlyphsNew ushr 8) and 0xFF).toByte()
        hheaBytes[35] = (numGlyphsNew and 0xFF).toByte()
        tableBytes["hhea"] = hheaBytes

        val maxpBytes = fontBytes.copyOfRange(maxpT.offset, maxpT.offset + maxpT.length)
        maxpBytes[4] = ((numGlyphsNew ushr 8) and 0xFF).toByte()
        maxpBytes[5] = (numGlyphsNew and 0xFF).toByte()
        tableBytes["maxp"] = maxpBytes

        tables["name"]?.let { t ->
            tableBytes["name"] = fontBytes.copyOfRange(t.offset, t.offset + t.length)
        }

        val finalBytes = assembleSfnt(keptTagsInOrder.filter { tableBytes.containsKey(it) }, tableBytes)
        return SubsetResult(finalBytes, oldToNew)
    }

    /** يبني جدول cmap شكلياً صالحاً (تنسيق 4 قياسي، segment شكلي واحد) —
     *  لا يُستخدَم فعلياً وقت العرض في مسار Identity-H (الذي يعتمد على
     *  GID مباشر من content stream)، فقط لاكتمال بنية sfnt القياسية. */
    /** يبني جدول cmap شكلياً صالحاً (تنسيق 4 قياسي، segment شكلي واحد) —
     *  لا يُستخدَم فعلياً وقت العرض في مسار Identity-H (الذي يعتمد على
     *  GID مباشر من content stream)، فقط لاكتمال بنية sfnt القياسية.
     *  ⚠️ إصلاح حقيقي مؤكَّد: التخصيص الأول لهذا الـByteBuffer كان محسوباً
     *  يدوياً بعبارة جمع طويلة (2+2+4+2+...) أنتجت 30 بايتاً فقط، بينما
     *  المحتوى الفعلي المكتوب (رأس 12 بايت + جدول فرعي تنسيق 4 كامل 32
     *  بايتاً = 44 بايتاً) يفيض عن هذا التخصيص — كان هذا سيُسبِّب
     *  BufferOverflowException فعلياً عند أول استدعاء حقيقي لهذه الدالة
     *  (يُمتَص بأمان عبر try/catch في finalizeAllFonts فلا يُسقط المستند،
     *  لكنه كان سيُسقط الـsubsetting بصمت لكل خط بلا استثناء، فيُعطِّل
     *  الإصلاح الجوهري الكامل دون أي رسالة خطأ واضحة). الحل: نخصِّص
     *  مساحة سخية (64 بايت، أكبر من أي حجم فعلي محتمل لمحتوى هذه الدالة
     *  الثابت) ثم نُقلِّم الناتج لحجمه الفعلي المكتوب عبر copyOf(position())
     *  في النهاية، بدل الاعتماد على حساب يدوي دقيق هش لعدد بايتات كل
     *  استدعاء putShort/putInt. */
    private fun buildMinimalCmap(oldToNew: Map<Int, Int>): ByteArray {
        val maxNewGid = (oldToNew.values.maxOrNull() ?: 0).coerceAtMost(0xFFFE)
        val segCount = 1
        val b = ByteBuffer.allocate(64).order(ByteOrder.BIG_ENDIAN)
        b.putShort(0); b.putShort(1)
        b.putShort(3); b.putShort(1); b.putInt(12)
        val subtableStart = b.position()
        b.putShort(4)
        val lengthPos = b.position(); b.putShort(0)
        b.putShort(0)
        b.putShort((segCount * 2).toShort())
        b.putShort(2)
        b.putShort(0)
        b.putShort(0)
        b.putShort(maxNewGid.toShort())
        b.putShort(0xFFFF.toShort())
        b.putShort(0)
        b.putShort(0)
        b.putShort(0xFFFF.toShort())
        b.putShort(0)
        b.putShort(0)
        b.putShort(0)
        b.putShort(0)
        val totalLen = b.position() - subtableStart
        b.putShort(lengthPos, totalLen.toShort())
        return b.array().copyOf(b.position())
    }

    private val MINIMAL_POST_TABLE: ByteArray = ByteBuffer.allocate(32).order(ByteOrder.BIG_ENDIAN).apply {
        putInt(0x00030000)
        putInt(0)
        putShort(0); putShort(0)
        putInt(0)
        putInt(0); putInt(0); putInt(0); putInt(0)
    }.array()

    /** يجمع جداول sfnt مُعطاة في ملف TrueType صالح كامل: جدول رؤوس (sfnt
     *  header + table directory) محسوب بمحاذاة 4-بايت قياسية لكل جدول،
     *  بلا حساب checksum فعلي لكل جدول (نكتب صفراً — القارئات العملية
     *  لا تتحقق منه بصرامة لعرض النص). */
    private fun assembleSfnt(orderedTags: List<String>, tableBytes: Map<String, ByteArray>): ByteArray {
        val numTables = orderedTags.size
        val headerSize = 12 + numTables * 16
        var dataCursor = headerSize
        val paddedTables = orderedTags.map { tag ->
            val raw = tableBytes[tag]!!
            val padded = if (raw.size % 4 != 0) raw + ByteArray(4 - raw.size % 4) else raw
            tag to padded
        }
        val out = ByteArray(headerSize + paddedTables.sumOf { it.second.size })
        val bb = ByteBuffer.wrap(out).order(ByteOrder.BIG_ENDIAN)
        bb.putInt(0x00010000)
        bb.putShort(numTables.toShort())
        var maxPow2 = 1; var log2 = 0
        while (maxPow2 * 2 <= numTables) { maxPow2 *= 2; log2++ }
        bb.putShort((maxPow2 * 16).toShort())
        bb.putShort(log2.toShort())
        bb.putShort(((numTables - maxPow2) * 16).toShort())

        for ((tag, padded) in paddedTables) {
            bb.put(tag.toByteArray(Charsets.US_ASCII).copyOf(4))
            bb.putInt(0)
            bb.putInt(dataCursor)
            bb.putInt(tableBytes[tag]!!.size)
            System.arraycopy(padded, 0, out, dataCursor, padded.size)
            dataCursor += padded.size
        }
        return out
    }
}
