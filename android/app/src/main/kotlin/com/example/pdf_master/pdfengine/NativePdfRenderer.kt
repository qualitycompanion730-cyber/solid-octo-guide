package com.example.pdf_master.pdfengine

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Build
import android.text.Layout
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import java.io.File
import kotlin.math.ceil
import kotlin.math.min

/**
 * NativePdfRenderer (معاد بناؤه بالكامل لكتابة PDF حقيقي)
 *
 * استبدال جذري للمحرك السابق الذي كان يستخدم android.graphics.pdf.PdfDocument
 * لرسم النص وتصديره - قيد بنيوي في تلك الفئة الرسمية لاندرويد يصدر اي نص مرسوم
 * عبر StaticLayout/Canvas.drawText كمسارات هندسية متجهية خام بدل عوامل نص PDF
 * حقيقية (Tj/TJ)، ما ادى لثلاث مشاكل مؤكدة بالفحص الفعلي على ملف ناتج:
 * (1) تضخم كارثي (~1-2MB/صفحة نص عادي)
 * (2) كل نص يرسم مرتين (مسار هندسي + طبقة نصية شبه-مخفية)
 * (3) النص العربي المستخرج من تلك الطبقة الخفية مكسور (ترابطات مفقودة من ToUnicode)
 *
 * الحل: نحتفظ بكامل منطق القياس/التخطيط/التجزئة هنا (StaticLayout لا يزال يقيس
 * بدقة، Minikin/HarfBuzz لا يزالان يشكلان العربي بصحة)، ونستبدل فقط طبقة
 * التصدير: بدل layout.draw(canvas) على PdfDocument، نستخرج من كل سطر glyphs
 * حقيقية بعد التشكيل عبر android.graphics.text.TextRunShaper (API 31+، انظر
 * PdfContentBuilder.drawTextLine)، ونكتب ملف PDF يدوياً بالكامل (PdfWriter)
 * بعوامل Tj/TJ حقيقية مع خط Type0/CIDFontType2 مضمن (PdfFontManager).
 *
 * قيد توافق متعمد ومتفق عليه: TextRunShaper/PositionedGlyphs متوفرة فقط من
 * API 31 (Android 12) فما فوق. تم رفع minSdk للتطبيق بالكامل الى 31 بالاتفاق.
 *
 * قيود معروفة في هذه الجولة (تحسينات منفصلة لاحقة، لا اخطاء صامتة):
 * - ظلال الاشكال: PDF لا يدعم تمويه/Blur كعامل رسم اساسي. بديل مبسط: نسخة
 * مسطحة مزاحة من مخطط الشكل بدل تمويه حقيقي.
 * - تدرجات الالوان: PDF تتطلب /Shading + /Pattern. نقرب التدرج بلون واحد.
 * - شفافية الصور: التحويل لـ JPEG لا يدعم الشفافية (تستبدل بخلفية سوداء).
 */
class NativePdfRenderer(private val context: Context) {

    private val typefaceCache = HashMap<String, Typeface>()

    companion object {
        /** ⚠️ إصلاح حقيقي (رموز القوائم النقطية/المرقّمة غائبة كلياً) —
         *  انظر تعليق drawListMarker أدناه لتفصيل المشكلة الكاملة. مساحة
         *  ثابتة بالنقاط محجوزة قبل نص كل فقرة قائمة لرمزها (•/1./أ./
         *  إلخ) — قيمة معقولة لمعظم الخطوط والأحجام الشائعة (تكفي رقمين
         *  مع نقطة "12." وهامش بسيط)، وليست حسابية دقيقة بحسب طول كل
         *  رمز فعلياً (تبسيط مقصود يكفي للحالة الشائعة دون تعقيد قياس
         *  نص الرمز نفسه قبل معرفة حجمه الفعلي في كل سياق استخدام). */
        const val LIST_MARKER_RESERVED_WIDTH_PT = 22f

        /** نسبة تصغير حجم الخط لـsuperscript/subscript — تقارب القيمة
         *  المعيارية في android.text.style.Superscript/SubscriptSpan
         *  (~0.65~0.7 شائعة في معظم محركات التنسيق، بينها Word نفسه). */
        const val SUPER_SUB_SCALE = 0.65f
        /** نسبة الإزاحة الرأسية (من حجم الخط الأصلي) لرفع/خفض الحرف —
         *  قيمة معتدلة تطابق تقريباً ما يُرى في Word لـx² أو H₂O. */
        const val SUPER_SUB_RISE_FRACTION = 0.35f
    }

    fun registerFont(family: String, bytes: ByteArray, bold: Boolean) {
        val key = fontKey(family, bold)
        if (typefaceCache.containsKey(key)) return
        try {
            // ملاحظة محفوظة من الاصدار السابق ولا تزال صحيحة لسبب جديد:
            // PdfFontManager.registerFont يقرأ android.graphics.fonts.Font.getFile()
            // لتضمين برنامج الخط في PDF، فهذا الملف المؤقت يجب ان يبقى موجوداً على
            // القرص طوال الجلسة (NativePdfRenderer نسخة واحدة طويلة العمر).
            val tmp = File.createTempFile("font_${key.hashCode()}", ".ttf", context.cacheDir)
            tmp.writeBytes(bytes)
            val tf = Typeface.createFromFile(tmp)
            typefaceCache[key] = tf
        } catch (e: Exception) {
            android.util.Log.w("NativePdfRenderer", "فشل تسجيل الخط $family: ${e.message}")
        }
    }

    private fun fontKey(family: String, bold: Boolean) = "$family|${if (bold) "b" else "r"}"

    private fun resolveTypeface(family: String, bold: Boolean, italic: Boolean): Typeface {
        val exact = typefaceCache[fontKey(family, bold)]
        val base = exact ?: typefaceCache[fontKey(family, false)] ?: Typeface.DEFAULT
        return if (italic) Typeface.create(base, if (bold) Typeface.BOLD_ITALIC else Typeface.ITALIC)
        else if (exact == null && bold) Typeface.create(base, Typeface.BOLD)
        else base
    }

    // ===================== نقطة الدخول الرئيسية =====================

    fun renderDocument(
        spec: DocSpec,
        progress: ((Double, String) -> Unit)? = null
    ): ByteArray {
        val writer = PdfWriter()
        val fontManager = PdfFontManager(writer)
        // ⚠️ إصلاح حقيقي (شفافية الظلال) — انظر تعليق الكلاس الكامل في
        // PdfExtGStateManager.kt. مثيل واحد مشترك عبر كل صفحات المستند،
        // بنفس آلية fontManager (كائنات /ExtGState قليلة جداً — 256 قيمة
        // ألفا ممكنة كحد أقصى نظري، عملياً أقل بكثير — تُشارَك بأمان عبر
        // كل الصفحات بصرف النظر عن عددها).
        val extGStateManager = PdfExtGStateManager(writer)
        val pageObjNums = ArrayList<Int>()
        val pagesTreeObjNum = writer.reserveObject()

        // ⚠️ إصلاح حقيقي (NUMPAGES/PAGE تُكتب كرموز PUA خام بدل أرقام
        // فعلية؛ أساس مشترك أيضاً لروابط داخلية حقيقية وفهرس محتويات
        // حقيقي لاحقاً) — انظر تعليق resolveBookmarkPages الكامل أعلاه.
        // يُستدعى هنا، *قبل* أي رسم فعلي، لحساب إجمالي صفحات PDF الحقيقي
        // المتوقَّع (bookmarkResolution.totalPages) عبر محاكاة قياس خفيفة
        // الوزن لنفس قرارات التصفيح — هذا الإجمالي هو ما يحل رمز
        // NUMPAGES أدناه لكل صفحة فعلياً تُرسَم. ⚠️ تنبيه تسمية: المتغيّر
        // المحلي `totalPages` أسفل هذا السطر (قبل هذا الإصلاح أصلاً)
        // يُستخدَم لغرض مختلف تماماً (تقدّم progress، عدد PageSpec
        // المنطقية لا عدد صفحات PDF الفعلية) — أُسمّي قيمة هذا الإصلاح
        // `totalPdfPages` تحديداً لتفادي أي لبس بين الاثنين.
        val bookmarkResolution = resolveBookmarkPages(spec)
        val totalPdfPages = bookmarkResolution.totalPages
        // ⚠️ إصلاح حقيقي جوهري (الروابط التشعبية الداخلية بلا أي وظيفة
        // فعلية) — انظر تعليق finalizePage(reservedPageObjNum/bookmarkObjNumOf)
        // أعلاه لتفصيل كامل الآلية. نحجز هنا رقم كائن واحد لكل bookmark
        // *قبل* أي رسم فعلي (writer.reserveObject() لا يكتب محتوى، فقط
        // يحجز الرقم) — هذا يحل مشكلة "رابط في صفحة تُرسَم *قبل* صفحة
        // الوجهة": رقم الكائن معروف الآن مسبقاً بصرف النظر عن ترتيب
        // الرسم الفعلي، فيمكن لأي رابط (من صفحة سابقة أو لاحقة) الإشارة
        // إليه فوراً عبر bookmarkObjNumOf، ثم finalizePage تكتب المحتوى
        // الفعلي في هذا الرقم بالذات (عبر reservedPageObjNum) فقط عند
        // رسم الصفحة الحقيقية التي تحوي ذلك bookmark.
        val bookmarkObjNums = HashMap<String, Int>()
        for (name in bookmarkResolution.pageOf.keys) {
            bookmarkObjNums[name] = writer.reserveObject()
        }
        // خريطة عكسية: رقم صفحة فعلي ← أسماء كل bookmark الواقعة فيه
        // (عادةً bookmark واحد كحد أقصى لكل صفحة عملياً، لكن نظرياً قد
        // يقع أكثر من عنوان في نفس الصفحة — نحجز رقم كائن واحد مشترك
        // لتلك الصفحة، يكفي لكل أسمائها معاً، فلا حاجة لتمييزها بصرياً
        // لـ/Dest بمستوى /XYZ الحالي البسيط v1).
        val bookmarksByPage = HashMap<Int, MutableList<String>>()
        for ((name, pageNum) in bookmarkResolution.pageOf) {
            bookmarksByPage.getOrPut(pageNum) { ArrayList() }.add(name)
        }
        fun reservedObjNumForPage(pageNum: Int): Int? =
            bookmarksByPage[pageNum]?.firstOrNull()?.let { bookmarkObjNums[it] }

        // ⚠️ إصلاح حقيقي جوهري (فهرس المحتويات الحقيقي) — يستبدل رمز
        // TOC المُركَّب (\uE002{bookmarkName}\uE003، انظر تعليق
        // _synthesizeTableOfContents في docx_to_pdf_converter.dart
        // للترميز الكامل) بنص رقم الصفحة الفعلي لكل bookmark مرجعي، في
        // *كل* كتل *كل* صفحات المستند دفعة واحدة هنا — قبل أي رسم فعلي،
        // بعد resolveBookmarkPages مباشرة (bookmarkResolution.pageOf
        // معروفة الآن بالكامل). ⚠️ تسلسل دائري صغير مقبول هنا (بنفس
        // منطق PAGE/NUMPAGES المقبول مسبقاً أعلاه): resolveBookmarkPages
        // نفسها قاست أصلاً طول رمز \uE002...\uE003 الخام (3+ محارف) لا
        // طول الرقم النهائي الحقيقي بعد هذا الاستبدال (1-3 أرقام عادة) —
        // فارق طول طفيف جداً (±2-3pt تقريباً لكل إدخال فهرس) لا يُغيّر
        // عملياً أي قرار تصفيح حقيقي (فقرة فهرس قصيرة جداً مقارنة بارتفاع
        // صفحة كاملة).
        // ⚠️ مهم: نستخدم resolveTocReferenceOnly أدناه (لا
        // resolvePageMarkersInBlock الكاملة) — تستبدل *فقط* رمز TOC
        // المُركَّب \uE002...\uE003، وتترك \uE000/\uE001 (PAGE/NUMPAGES)
        // كما هما بلا أي لمس هنا. لو استُخدِمت resolvePageMarkersInBlock
        // الكاملة بـpageNum/totalPages مؤقَّتين (كـ0)، أي فقرة متن
        // (نادرة، خارج TOC) تحتوي استثنائياً \uE000/\uE001 (حقل PAGE
        // داخل نص عادي لا الرأس/التذييل المُعتاد) كانت ستُستبدَل خطأً
        // بـ"0" هنا نهائياً، قبل أن تصل لمعالجتها الصحيحة اللاحقة لكل
        // صفحة فعلية — خطأ صمت محتمل تجنّبناه بفصل الاستبدالين تماماً.
        fun resolveTocReferenceOnly(text: String): String {
            if (text.indexOf('\uE002') < 0) return text
            return Regex("\uE002([^\uE003]*)\uE003").replace(text) { m ->
                bookmarkResolution.pageOf[m.groupValues[1]]?.toString() ?: ""
            }
        }
        fun resolveTocInBlock(block: Block): Block = when (block) {
            is Block.Paragraph -> {
                if (block.runs.none { it.text.indexOf('\uE002') >= 0 }) block
                else block.copy(runs = block.runs.map { run ->
                    if (run.text.indexOf('\uE002') < 0) run
                    else run.copy(text = resolveTocReferenceOnly(run.text))
                })
            }
            is Block.Table -> block.copy(rows = block.rows.map { row ->
                row.map { cell -> cell.copy(blocks = cell.blocks.map(::resolveTocInBlock)) }
            })
            is Block.GroupBlock -> block.copy(children = block.children.map(::resolveTocInBlock))
            else -> block
        }
        val pagesWithTocResolved = spec.pages.map { pageSpec ->
            pageSpec.copy(blocks = pageSpec.blocks.map(::resolveTocInBlock))
        }

        val totalPages = spec.pages.size
        pagesWithTocResolved.forEachIndexed { idx, pageSpec ->
            progress?.invoke(
                0.1 + 0.8 * (idx.toDouble() / totalPages.coerceAtLeast(1)),
                "رسم الصفحة ${idx + 1} من $totalPages..."
            )
            val startPageNumForSection = pageObjNums.size + 1
            if (spec.isPrecomposed) {
                pageObjNums.add(renderPrecomposedPage(
                    writer, fontManager, pageSpec, pagesTreeObjNum, extGStateManager,
                    pageNum = startPageNumForSection, totalPages = totalPdfPages,
                    reservedPageObjNum = reservedObjNumForPage(startPageNumForSection),
                    bookmarkObjNumOf = { bookmarkObjNums[it] }
                ))
            } else {
                pageObjNums.addAll(renderFlowingPage(
                    writer, fontManager, pageSpec, pagesTreeObjNum, extGStateManager,
                    startPageNum = startPageNumForSection, totalPages = totalPdfPages,
                    reservedObjNumForPage = ::reservedObjNumForPage,
                    bookmarkObjNumOf = { bookmarkObjNums[it] }
                ))
            }
        }

        if (pageObjNums.isEmpty()) {
            pageObjNums.add(buildBlankPage(writer, pagesTreeObjNum))
        }

        // ⚠️ إصلاح حقيقي جوهري (Subsetting حقيقي يستبدل التضمين الكامل):
        // يجب أن تُستدعى هنا بالضبط — بعد انتهاء رسم *كل* صفحات المستند
        // (حلقة forEachIndexed أعلاه) لكن *قبل* writer.build() النهائية.
        // كل استدعاءات registerFont أثناء رسم الصفحات (عبر PdfContentBuilder
        // .drawGlyphRun) كانت قد حجزت فقط أرقام كائنات /Type0 (PdfWriter
        // .reserveObject) دون كتابة أي محتوى فعلي بعد — انظر تعليق الكلاس
        // الكامل في PdfFontManager.kt لتفصيل سبب هذا التأجيل (لا تُعرَف
        // المجموعة الكاملة النهائية للـglyphs المُستخدَمة فعلياً من كل
        // خط إلا بعد رسم آخر صفحة في المستند، فصفحة لاحقة قد تستخدم glyph
        // لم يظهر في أي صفحة سابقة من نفس الخط). finalizeAllFonts() تبني
        // الآن فعلياً محتوى كل كائن خط محجوز (نسخة subset حقيقية تحوي
        // فقط الـglyphs المُستخدَمة + إغلاقها العبوري) وتكتبه عبر
        // writer.setObject في رقم الكائن المحجوز — هذا تحديداً ما يحوِّل
        // كائن خط واحد من 12.3MB (تضمين كامل) إلى عشرات/مئات الكيلوبايت
        // فقط (تغطية الـglyphs المُستخدَمة فعلياً في المستند الحقيقي).
        fontManager.finalizeAllFonts()

        writer.setObject(pagesTreeObjNum, (
            "<<\n/Type /Pages\n/Count ${pageObjNums.size}\n" +
            "/Kids [${pageObjNums.joinToString(" ") { writer.ref(it) }}]\n>>"
        ).toByteArray(Charsets.ISO_8859_1))

        val catalogObjNum = writer.addObject(
            "<<\n/Type /Catalog\n/Pages ${writer.ref(pagesTreeObjNum)}\n>>"
        )

        progress?.invoke(0.95, "حفظ الملف...")
        return writer.build(catalogObjNum)
    }

    private fun buildBlankPage(writer: PdfWriter, parentObjNum: Int): Int {
        val contentObjNum = writer.addObject(writer.buildStreamObject(ByteArray(0)))
        return writer.addObject(
            "<<\n/Type /Page\n/Parent ${writer.ref(parentObjNum)}\n" +
            "/MediaBox [0 0 595 842]\n/Resources << >>\n/Contents ${writer.ref(contentObjNum)}\n>>"
        )
    }

    /** ⚠️ إصلاح حقيقي جوهري (الروابط التشعبية بلا أي وظيفة فعلية) — انظر
     *  تعليق TextRun.linkUri/linkAnchor (PdfSpecModels.kt) وPendingLinkAnnotation
     *  (DrawCtx.kt) لتفصيل كامل المشكلة. معاملان جديدان هنا:
     *  - [pendingLinks]: كل مستطيلات الروابط المُجمَّعة أثناء رسم *هذه*
     *    الصفحة تحديداً (ctx.pendingLinks، يُعاد تمريرها من نقطة الاستدعاء
     *    بعد رسم كل محتوى الصفحة) — تُبنى منها كائنات /Annots /Link فعلية.
     *  - [reservedPageObjNum]: لو غير null، رقم كائن *محجوز مسبقاً* (عبر
     *    writer.reserveObject() في renderDocument، قبل أي رسم) يجب
     *    استخدامه لكائن /Type /Page هذا بدل طلب رقم جديد — ضروري فقط
     *    حين تكون هذه الصفحة بالذات وجهة Bookmark لرابط داخلي من صفحة
     *    أخرى (قد تُرسَم قبل أو بعد هذه الصفحة، فلا يمكن معرفة رقم
     *    كائنها الحقيقي وقت بناء ذلك الرابط لولا هذا الحجز المسبق).
     *  - [bookmarkObjNumOf]: دالة تحل اسم Bookmark إلى رقم كائنه المحجوز
     *    (لبناء /Dest لكل رابط داخلي بمرجع كائن صحيح، بصرف النظر عن
     *    ترتيب رسم الصفحتين المصدر والوجهة). */
    private fun finalizePage(
        writer: PdfWriter,
        fontManager: PdfFontManager,
        imageManager: PdfImageManager,
        parentObjNum: Int,
        widthPt: Double,
        heightPt: Double,
        rawContent: ByteArray,
        extGStateManager: PdfExtGStateManager? = null,
        pendingLinks: List<PendingLinkAnnotation> = emptyList(),
        reservedPageObjNum: Int? = null,
        bookmarkObjNumOf: (String) -> Int? = { null }
    ): Int {
        val contentObjNum = writer.addObject(writer.buildStreamObject(rawContent))

        val fontEntries = fontManager.allRegisteredFonts()
            .joinToString("\n") { (name, objNum) -> "/$name ${writer.ref(objNum)}" }
        val imageEntries = imageManager.allRegisteredForCurrentPage()
            .entries.joinToString("\n") { (name, objNum) -> "/$name ${writer.ref(objNum)}" }
        imageManager.resetForNextPage()
        // ⚠️ إصلاح حقيقي (شفافية الظلال) — انظر تعليق الكلاس الكامل في
        // PdfExtGStateManager.kt. نفس آلية fontEntries أعلاه بالضبط: كل
        // كائنات /ExtGState المسجَّلة عبر *كل* صفحات المستند (وليس فقط
        // هذه الصفحة، تماماً كالخطوط) تُدرَج هنا — لا ضرر من قائمة موارد
        // أكبر من اللازم لصفحة لا تستخدم بعضها فعلياً (مسموح في PDF).
        val extGStateEntries = extGStateManager?.allRegistered()
            ?.joinToString("\n") { (name, objNum) -> "/$name ${writer.ref(objNum)}" } ?: ""

        val resources = buildString {
            append("<<\n/Font <<\n$fontEntries\n>>\n")
            if (imageEntries.isNotEmpty()) {
                append("/XObject <<\n$imageEntries\n>>\n")
            }
            if (extGStateEntries.isNotEmpty()) {
                append("/ExtGState <<\n$extGStateEntries\n>>\n")
            }
            append(">>")
        }

        // ⚠️ إصلاح حقيقي جوهري (الروابط التشعبية): كل مستطيل مُجمَّع يصبح
        // كائن /Annots /Link مستقلاً، يُحجَز رقمه ويُكتب محتواه *قبل*
        // كائن الصفحة نفسها (PDF يسمح بترتيب الكائنات بحرية، لكن نحتاج
        // أرقامها أولاً لإدراجها في مصفوفة /Annots للصفحة). رابط خارجي
        // (uri != null) يحمل /A /URI كفعل نقر مباشر. رابط داخلي
        // (anchorName != null) يحمل /Dest بمرجع كائن الصفحة الهدف
        // (مُحلَّل عبر bookmarkObjNumOf) بنمط /XYZ (الموضع الافتراضي:
        // أعلى يسار الصفحة الهدف، بصرف النظر عن موضع العنوان بالضبط
        // ضمنها — تبسيط مقبول v1، يطابق سلوك أغلب قارئات PDF حين تُفتح
        // وجهة Dest بلا تمرير دقيق لموضع إضافي). أي bookmarkName لم
        // يُحَل (مرجع معطوب في DOCX الأصلي، أو bookmarkObjNumOf أعادت
        // null) يُتجاهَل بأمان (لا كائن رابط مكسور في الناتج النهائي).
        val annotObjNums = ArrayList<Int>()
        for (link in pendingLinks) {
            // ⚠️ صياغة صريحة (لا تعبير continue متداخل داخل if/else
            // مُعيَّن لمتغيّر، حتى لو صحيح نحوياً في Kotlin — الوضوح أهم
            // هنا): نحسب actionOrDest كـString? (null = تخطَّ هذا الرابط
            // بأمان)، ثم نفحصه فوراً.
            val actionOrDest: String? = when {
                link.uri != null ->
                    "/A << /Type /Action /S /URI /URI (${PdfWriter.escapeLiteralString(link.uri)}) >>"
                link.anchorName != null -> {
                    val destObjNum = bookmarkObjNumOf(link.anchorName)
                    if (destObjNum == null) null
                    else "/Dest [${writer.ref(destObjNum)} /XYZ null null null]"
                }
                else -> null
            }
            if (actionOrDest == null) continue
            val rect = "${PdfWriter.fmt(link.xMinPt)} ${PdfWriter.fmt(link.yMinPt)} " +
                "${PdfWriter.fmt(link.xMaxPt)} ${PdfWriter.fmt(link.yMaxPt)}"
            annotObjNums.add(writer.addObject(
                "<<\n/Type /Annot\n/Subtype /Link\n/Rect [$rect]\n/Border [0 0 0]\n$actionOrDest\n>>"
            ))
        }
        val annotsEntry = if (annotObjNums.isNotEmpty()) {
            "/Annots [${annotObjNums.joinToString(" ") { writer.ref(it) }}]\n"
        } else ""

        val pageContent = buildString {
            append("<<\n/Type /Page\n/Parent ${writer.ref(parentObjNum)}\n")
            append("/MediaBox [0 0 ${PdfWriter.fmt(widthPt)} ${PdfWriter.fmt(heightPt)}]\n")
            append("/Resources $resources\n")
            append(annotsEntry)
            append("/Contents ${writer.ref(contentObjNum)}\n>>")
        }
        // ⚠️ إصلاح حقيقي (روابط داخلية) — انظر تعليق reservedPageObjNum
        // أعلاه: لو كانت هذه الصفحة وجهة Bookmark، يجب كتابة محتواها في
        // رقم الكائن *المحجوز مسبقاً* (وليس رقماً جديداً) عبر setObject،
        // ليطابق المرجع الذي بنته أي رابط داخلي يشير إليها من صفحة أخرى.
        return if (reservedPageObjNum != null) {
            writer.setObject(reservedPageObjNum, pageContent.toByteArray(Charsets.ISO_8859_1))
            reservedPageObjNum
        } else {
            writer.addObject(pageContent)
        }
    }

    // ===================== ⚠️ إصلاح حقيقي: الهيدر والفوتر =====================
    // قبل هذا الإصلاح لم يكن أي مسار رسم يستدعي pageSpec.headerBlocks/
    // footerBlocks لأن الحقلين نفسهما لم يكونا موجودين في PageSpec (انظر
    // تعليق PdfSpecModels.PageSpec.headerBlocks لتفصيل المشكلة الكاملة).
    // هذه الدالة موحَّدة (مُستدعاة من كل دوال رسم الصفحة الثلاث) لضمان
    // سلوك متطابق للهيدر/الفوتر بصرف النظر عن نوع الصفحة (متدفقة/جاهزة
    // مسبقاً/متعددة الأعمدة) — التكرار التلقائي لكل صفحة محقَّق ببساطة
    // لأنها تُستدعى مرة واحدة فعلياً لكل صفحة من نقطة استدعاء finalizePage
    // (أي لكل صفحة ناتجة فعلياً، لا لكل pageSpec منطقي قد يفيض لعدة صفحات).
    /** يرسم كتل الهيدر (إن وُجدت) في الشريط العلوي من الصفحة، بعرض كامل
     *  محتوى الصفحة (بين الهامشين الجانبيين)، بصرف النظر عن هوامش
     *  المحتوى الرئيسي العمودية (الهيدر يقع *قبل* marginTop المستخدَم
     *  لبداية المحتوى الأساسي — هذا تحديداً سبب وجود headerHeightPt
     *  كحجز مسافة مسبق منفصل في الدوال المستدعية). */
    private fun drawPageHeader(ctx: DrawCtx, spec: PageSpec, pageW: Float) {
        if (spec.headerBlocks.isEmpty()) return
        val left = spec.marginLeftPt.toFloat()
        val width = (pageW - spec.marginLeftPt.toFloat() - spec.marginRightPt.toFloat()).coerceAtLeast(1f)
        var hy = 0f
        for (block in spec.headerBlocks) {
            hy = drawBlock(ctx, block, left, hy, width, spec = spec)
        }
    }

    /** يرسم كتل الفوتر (إن وُجدت) في الشريط السفلي من الصفحة، محاذياً
     *  أسفله الفعلي لحافة الصفحة السفلية (لا لـ marginBottomPt للمحتوى
     *  الرئيسي، الذي يقع *فوق* شريط الفوتر بحجز footerHeightPt). */
    private fun drawPageFooter(ctx: DrawCtx, spec: PageSpec, pageW: Float, pageH: Float) {
        if (spec.footerBlocks.isEmpty()) return
        val left = spec.marginLeftPt.toFloat()
        val width = (pageW - spec.marginLeftPt.toFloat() - spec.marginRightPt.toFloat()).coerceAtLeast(1f)
        val footerH = if (spec.footerHeightPt > 0.0) spec.footerHeightPt.toFloat()
            else spec.footerBlocks.sumOf { measureBlockHeight(it, width).toDouble() }.toFloat()
        var fy = pageH - footerH
        for (block in spec.footerBlocks) {
            fy = drawBlock(ctx, block, left, fy, width, spec = spec)
        }
    }

    private fun drawPageHeaderFooter(ctx: DrawCtx, spec: PageSpec, pageW: Float, pageH: Float, pageNum: Int, totalPages: Int) {
        // ⚠️ إصلاح حقيقي (NUMPAGES/PAGE تُكتب كرموز PUA خام) — انظر تعليق
        // mightContainPageMarker/resolvePageMarkersInPageSpec أعلاه لتفصيل
        // كامل المشكلة. نستبدل الرموز هنا في نسخة من spec (لا الأصلية —
        // تبقى صالحة لإعادة استخدامها في كل صفحة أخرى من نفس القسم، كل
        // واحدة برقم صفحتها الفعلي الخاص) مباشرة قبل تمريرها لدوال الرسم
        // الفرعية، فيُكتب الرقم الصحيح فعلياً بدل الرمز النائب.
        val resolvedSpec = resolvePageMarkersInPageSpec(spec, pageNum, totalPages)
        drawPageHeader(ctx, resolvedSpec, pageW)
        drawPageFooter(ctx, resolvedSpec, pageW, pageH)
    }



    private fun renderPrecomposedPage(
        writer: PdfWriter, fontManager: PdfFontManager, pageSpec: PageSpec, parentObjNum: Int,
        extGStateManager: PdfExtGStateManager? = null,
        pageNum: Int = 1, totalPages: Int = 1,
        reservedPageObjNum: Int? = null,
        bookmarkObjNumOf: (String) -> Int? = { null }
    ): Int {
        val wPts = pageSpec.widthPt
        val hPts = pageSpec.heightPt
        val imageManager = PdfImageManager(writer)
        // ⚠️ إصلاح حقيقي (الإيموجي غائبة + خط PDF تالف "F6"): قبل هذا
        // الإصلاح كان PdfContentBuilder يُبنى دوماً بمعامله الثاني
        // (imageManager) على قيمته الافتراضية null، فيسقط drawTextLine
        // دوماً لمسار drawGlyphRun العادي حتى لخط الإيموجي نفسه (انظر
        // isEmojiFont && imageManager != null في PdfContentBuilder.kt) —
        // ما يحاول تسجيل خط الإيموجي (بصري bitmap/CBDT لا outline قياسي)
        // كـCIDFontType2/FontFile2 عادي، فيُنتج خط PDF تالفاً (هذا تحديداً
        // ما ظهر فعلياً كخطأ "Couldn't create a font for 'F6'" عند فتح
        // الملف الناتج بـ poppler) وتختفي الإيموجي بصرياً تماماً. تمرير
        // نفس imageManager الخاص بالصفحة هنا (الموجود مسبقاً، لم يكن
        // مفقوداً، فقط غير مُمرَّر) يُفعِّل مسار drawEmojiRun الصحيح أصلاً.
        val cb = PdfContentBuilder(fontManager, imageManager)
        val ctx = DrawCtx(cb, imageManager, hPts.toFloat(), extGStateManager)

        pageSpec.backgroundColorArgb?.let { ctx.fillPageBackground(it, wPts.toFloat(), hPts.toFloat()) }
        pageSpec.backgroundImageBytes?.let { bytes ->
            ctx.drawBitmapCover(bytes, 0f, 0f, wPts.toFloat(), hPts.toFloat())
        }
        pageSpec.watermark?.let { ctx.drawWatermark(it, wPts.toFloat(), hPts.toFloat()) }

        val contentLeft = pageSpec.marginLeftPt.toFloat()
        val contentTop = pageSpec.marginTopPt.toFloat()
        val contentWidth = (wPts - pageSpec.marginLeftPt - pageSpec.marginRightPt).toFloat()

        var cursorY = contentTop
        for (block in pageSpec.blocks) {
            cursorY = drawBlock(ctx, block, contentLeft, cursorY, contentWidth, spec = pageSpec)
        }
        for (overlay in pageSpec.overlayBlocks) {
            val maxW = (wPts - overlay.xPt).toFloat().coerceAtLeast(1f)
            drawBlock(ctx, overlay.block, overlay.xPt.toFloat(), overlay.yPt.toFloat(), maxW, spec = pageSpec)
        }
        pageSpec.pageBorder?.let { ctx.drawPageBorder(it, wPts.toFloat(), hPts.toFloat()) }
        // ⚠️ إصلاح حقيقي (الهيدر والفوتر غائبان كلياً) — انظر تعليق
        // PageSpec.headerBlocks وdrawPageHeaderFooter أعلاه. يُرسَم بعد كل
        // محتوى الصفحة (فوق المحتوى لو تداخل، وهو سلوك مقبول لشريط رفيع
        // ثابت أعلى/أسفل كل صفحة كما في Word).
        drawPageHeaderFooter(ctx, pageSpec, wPts.toFloat(), hPts.toFloat(), pageNum, totalPages)

        return finalizePage(
            writer, fontManager, imageManager, parentObjNum, wPts, hPts, cb.build(), extGStateManager,
            pendingLinks = ctx.pendingLinks, reservedPageObjNum = reservedPageObjNum, bookmarkObjNumOf = bookmarkObjNumOf
        )
    }

    // ===================== الصفحات المتدفقة (DOCX/HTML/TXT) =====================

    /** ⚠️ إصلاح حقيقي (هوامش داخل خلايا الجداول تُفقَد كلياً): نقاط تجميع
     *  الهوامش في renderFlowingPage/renderFlowingPageMultiColumn (أدناه)
     *  كانت تفحص فقط block.footnotes على مستوى الكتلة المباشرة في حلقة
     *  صفحة المستوى الأعلى — أي footnoteReference واقع داخل فقرة *ضمن
     *  خلية جدول* (Block.Table → TableCellModel.blocks → Block.Paragraph
     *  .footnotes) لم يكن يُجمَع إطلاقاً لأن تلك الفقرة ليست هي الكتلة
     *  المباشرة في حلقة الصفحة (الكتلة المباشرة هناك هي Block.Table
     *  نفسه، الذي لا يحمل حقل footnotes خاصاً به). النتيجة: أي هامش
     *  مرجعه داخل جدول كان يُفقَد كلياً من الناتج النهائي — لا يظهر في
     *  أي صفحة. الحل: دالة عبور تكراري على شجرة الكتلة الواحدة بالكامل
     *  (تنزل لكل GroupBlock.children وكل TableCellModel.blocks في كل
     *  خلية من كل صف) تُستخدَم في كلا موضعي التجميع بدل القراءة المباشرة
     *  لـblock.footnotes فقط. */
    /** ⚠️ إصلاح حقيقي (NUMPAGES/PAGE تُكتب كرموز PUA خام غير مرئية بدل
     *  أرقام فعلية): docx_to_pdf_converter.dart (الجهة Dart) كانت تزرع
     *  رمزَي PUA نائبين (U+E000 لـPAGE، U+E001 لـNUMPAGES) في نص الفقرة
     *  أثناء تحليل w:instrText، بافتراض أن drawPageHeaderFooter هنا
     *  (Kotlin) ستستبدلهما برقم الصفحة الفعلي/الإجمالي — لكن لا يوجد *أي*
     *  كود فعلياً يفعل ذلك (تأكَّد هذا بالفحص المباشر؛ لا أي إشارة لهذين
     *  الرمزين في كل الملف قبل هذا الإصلاح). النتيجة المؤكَّدة فعلياً
     *  بفحص PDF ناتج: التذييل يظهر "Page  of " بفراغين حرفيين بدل
     *  الأرقام (الرمزان غير قابلين للعرض بصرياً في أي خط عادي — صندوق
     *  .notdef أو فراغ تماماً حسب الخط).
     *
     *  هذه الدالة تستبدل الرمزين بنص الرقم الفعلي *في نسخة جديدة* من
     *  الكتلة (data class copy، عبر Kotlin القياسي) — لا تُعدِّل الكتلة
     *  الأصلية الممرَّرة (التي تبقى صالحة لإعادة استخدامها لصفحات أخرى،
     *  مهم تحديداً لـheaderBlocks/footerBlocks المُكرَّرة عبر كل صفحات
     *  نفس القسم). فحص سريع mightContainPageMarker أولاً يتجنّب أي
     *  تخصيص ذاكرة إضافي (data class جديدة) للحالة الغالبة فعلياً (فقرات
     *  متن المستند العادية، لا تحتوي هذين الرمزين إطلاقاً — فقط رأس/
     *  تذييل قد يحتوي حقل PAGE/NUMPAGES). */
    /** ⚠️ تحديث (فهرس المحتويات الحقيقي): يفحص الآن أيضاً عن رمز TOC
     *  المُركَّب الجديد (\uE002، بداية اسم بوكماركة هدف لإدخال فهرس —
     *  انظر تعليق _synthesizeTableOfContents في docx_to_pdf_converter.dart
     *  للترميز الكامل: \uE002 + اسم البوكماركة + \uE003) بجانب رمزَي
     *  PAGE/NUMPAGES الأصليين. \uE003 (رمز الإغلاق) لا يحتاج فحصاً
     *  مستقلاً — لا يظهر أبداً بمعزل عن \uE002 المصاحب له دوماً في نفس
     *  النص (كلاهما يُكتَب معاً من نقطة واحدة في Dart). */
    private fun mightContainPageMarker(text: String): Boolean =
        text.indexOf('\uE000') >= 0 || text.indexOf('\uE001') >= 0 || text.indexOf('\uE002') >= 0

    /** ⚠️ تحديث (فهرس المحتويات الحقيقي): معامل جديد [bookmarkPageOf]
     *  (افتراضي خريطة فارغة، فلا تغيير سلوك لأي نقطة استدعاء قديمة لا
     *  تمرّره صراحة — استدعاءات الرأس/التذييل القديمة تبقى كما كانت
     *  تماماً) يُستخدَم لحل رمز TOC المُركَّب \uE002{name}\uE003 إلى رقم
     *  صفحة ذلك bookmark الفعلي (نفس bookmarkResolution.pageOf المبنية
     *  أصلاً لـNUMPAGES، يُعاد استخدامها هنا مباشرة بلا أي حساب إضافي).
     *  اسم بوكماركة غير موجود في الخريطة (مرجع معطوب، نادر) يُستبدَل
     *  بنص فارغ بأمان بدل ترك الرمز الخام ظاهراً في الناتج النهائي. */
    private fun resolvePageMarkersInBlock(
        block: Block, pageNum: Int, totalPages: Int,
        bookmarkPageOf: Map<String, Int> = emptyMap()
    ): Block {
        // ⚠️ يستبدل رمز TOC المُركَّب أولاً (قبل PAGE/NUMPAGES البسيطين،
        // فلا تعارض بينهما لأن الأنماط مختلفة تماماً) — يبحث عن كل
        // تكرار لـ\uE002...\uE003 ويستبدله برقم الصفحة المُحَل أو نص
        // فارغ. Regex بسيطة (غير جشعة) كافية هنا: أسماء bookmark في
        // DOCX لا تحتوي محارف PUA نفسها أبداً (قيد طبيعي من OOXML نفسه
        // على أسماء الإشارات المرجعية، أحرف/أرقام/شرطة سفلية فقط)، فلا
        // التباس ممكن بين حدود الرمز ومحتواه.
        fun resolveTocRefs(text: String): String {
            if (text.indexOf('\uE002') < 0) return text
            return Regex("\uE002([^\uE003]*)\uE003").replace(text) { m ->
                bookmarkPageOf[m.groupValues[1]]?.toString() ?: ""
            }
        }
        return when (block) {
            is Block.Paragraph -> {
                if (block.runs.none { mightContainPageMarker(it.text) }) return block
                block.copy(runs = block.runs.map { run ->
                    if (!mightContainPageMarker(run.text)) run
                    else run.copy(
                        text = resolveTocRefs(run.text)
                            .replace("\uE000", pageNum.toString())
                            .replace("\uE001", totalPages.toString())
                    )
                })
            }
            is Block.Table -> block.copy(rows = block.rows.map { row ->
                row.map { cell ->
                    cell.copy(blocks = cell.blocks.map {
                        resolvePageMarkersInBlock(it, pageNum, totalPages, bookmarkPageOf)
                    })
                }
            })
            is Block.GroupBlock -> block.copy(children = block.children.map {
                resolvePageMarkersInBlock(it, pageNum, totalPages, bookmarkPageOf)
            })
            else -> block
        }
    }

    /** نسخة PageSpec التي تُمرَّر فعلياً للرسم، باستبدال رموز PAGE/
     *  NUMPAGES في headerBlocks/footerBlocks تحديداً (الموضع الوحيد
     *  عملياً حيث تظهر حقول PAGE/NUMPAGES في DOCX حقيقي — رأس/تذييل
     *  الصفحة). ⚠️ استبدال رمز TOC المُركَّب (\uE002...\uE003) *لا* يحدث
     *  هنا — فهرس المحتويات جزء من *متن* المستند (pageSpec.blocks)، لا
     *  الرأس/التذييل، ويُستبدَل مرة واحدة فقط ولكل المستند دفعة واحدة في
     *  renderDocument عبر resolveTocReferencesInPages (انظرها أدناه)
     *  قبل أي رسم فعلي إطلاقاً — لأن خريطة bookmarkPageOf اللازمة لحله
     *  معروفة بالكامل مسبقاً (resolveBookmarkPages)، بخلاف pageNum
     *  الحالي هنا الذي يختلف لكل صفحة فعلية أثناء الرسم. */
    private fun resolvePageMarkersInPageSpec(spec: PageSpec, pageNum: Int, totalPages: Int): PageSpec {
        val hasMarkerInHeader = spec.headerBlocks.any { blockMightContainPageMarker(it) }
        val hasMarkerInFooter = spec.footerBlocks.any { blockMightContainPageMarker(it) }
        if (!hasMarkerInHeader && !hasMarkerInFooter) return spec
        return spec.copy(
            headerBlocks = spec.headerBlocks.map { resolvePageMarkersInBlock(it, pageNum, totalPages) },
            footerBlocks = spec.footerBlocks.map { resolvePageMarkersInBlock(it, pageNum, totalPages) }
        )
    }

    private fun blockMightContainPageMarker(block: Block): Boolean = when (block) {
        is Block.Paragraph -> block.runs.any { mightContainPageMarker(it.text) }
        is Block.Table -> block.rows.any { row -> row.any { cell -> cell.blocks.any { blockMightContainPageMarker(it) } } }
        is Block.GroupBlock -> block.children.any { blockMightContainPageMarker(it) }
        else -> false
    }

    private fun collectFootnotesRecursive(block: Block, out: MutableList<String>) {
        when (block) {
            is Block.Paragraph -> if (block.footnotes.isNotEmpty()) out.addAll(block.footnotes)
            is Block.Table -> for (row in block.rows) for (cell in row) {
                for (cellBlock in cell.blocks) collectFootnotesRecursive(cellBlock, out)
            }
            is Block.GroupBlock -> for (child in block.children) collectFootnotesRecursive(child, out)
            else -> {}
        }
    }

    /** ⚠️ إضافة جديدة (أساس مشترك لـNUMPAGES + الروابط الداخلية + فهرس
     *  المحتويات الحقيقي): نظيرة دقيقة لـcollectFootnotesRecursive أعلاه،
     *  لكن لأسماء Bookmark (Block.Paragraph.bookmarkName) بدل نصوص
     *  الهوامش — تُستخدَم من resolveBookmarkPages لجمع كل أسماء البوكمارك
     *  الواقعة (مباشرة أو ضمن جدول/مجموعة) داخل كتلة واحدة، أثناء تمريرة
     *  القياس المسبقة. نفس منطق العبور الشجري بالضبط (جدول→خلايا→كتل،
     *  مجموعة→أبناء) لضمان عدم تفويت بوكماركة واقعة في موضع متداخل. */
    private fun collectBookmarksRecursive(block: Block, out: MutableList<String>) {
        when (block) {
            is Block.Paragraph -> block.bookmarkName?.let { out.add(it) }
            is Block.Table -> for (row in block.rows) for (cell in row) {
                for (cellBlock in cell.blocks) collectBookmarksRecursive(cellBlock, out)
            }
            is Block.GroupBlock -> for (child in block.children) collectBookmarksRecursive(child, out)
            else -> {}
        }
    }

    // ===================== ⚠️ إضافة جديدة: حل Bookmark→رقم صفحة =====================
    // أساس مشترك لثلاث ميزات منفصلة (NUMPAGES الصحيح، روابط داخلية قابلة
    // للنقر، فهرس محتويات حقيقي): قبل وجود هذه الآلية، لم تكن هناك طريقة
    // لمعرفة "في أي صفحة PDF فعلية سينتهي بها عنوان معيّن؟" — هذا يُعرَف
    // فقط بعد القياس الحقيقي والتصفيح (StaticLayout)، الذي يحدث أصلاً
    // فقط أثناء الرسم الفعلي في renderFlowingPage/renderFlowingPageMultiColumn
    // /renderPrecomposedPage. resolveBookmarkPages تُشغَّل *مرة واحدة* في
    // بداية renderDocument (قبل أي كتابة PDF فعلية)، فتُحاكي بدقة نفس
    // حلقة forEachIndexed + قرارات "متى ننتقل لصفحة جديدة" — لكن بنسخة
    // قياس خفيفة الوزن بلا أي رسم فعلي (لا PdfContentBuilder، لا
    // PdfWriter)، تستخدم فقط measureBlockHeight/measureParagraph (بحتتان
    // تماماً، انظر تعليقيهما — لا أثر جانبي على أي حالة مشتركة).
    //
    // ⚠️ قيد مُتعمَّد وموثَّق: عند فحص فقرة تحمل bookmarkName، نسجّل رقم
    // الصفحة الحالية *عند بداية* تلك الفقرة (قبل تطبيق منطق فيضانها
    // الداخلي عبر الأسطر) — هذا صحيح ودقيق 100% بصرف النظر عما يحدث
    // لبقية الفقرة لاحقاً (فقرات bookmark هي عناوين، نادراً ما تفيض
    // بمفردها). فيضان الفقرة نفسها عبر أكثر من صفحة (حالة ممكنة فعلياً
    // لفقرات حشو طويلة، لا نادرة كما قد يُفترَض) *يُحاكى* أدناه (انظر
    // countFlowingPageDry) بتقريب عدد الصفحات الإضافية الناتجة عنها —
    // بدقة كافية لحساب رقم الصفحة الإجمالي الصحيح بفارق ±سطر واحد حد
    // أقصى عملياً عند حدود الصفحة، لا بدقة بكسلية لموضع كل سطر (غير
    // ضرورية هنا، فالهدف فقط "كم صفحة" لا "أين كل سطر").
    /** نتيجة resolveBookmarkPages: خريطة اسم البوكماركة → رقم صفحتها
     *  (1-indexed)، مع إجمالي عدد صفحات PDF الفعلية المتوقَّعة لكل
     *  المستند — هذا الإجمالي هو ما يحل رمز NUMPAGES النائب (انظر
     *  resolveNumPagesPlaceholders أدناه)، وبالضبط نفس القيمة التي
     *  ستُصبح pageObjNums.size الحقيقية بعد انتهاء الرسم الفعلي لاحقاً
     *  (بفرض تطابق منطق العدّ الجاف، المُوثَّق أعلى كل من
     *  countFlowingPageDry وcountFlowingPagesMultiColumnDry). */
    private data class BookmarkResolution(
        val pageOf: Map<String, Int>,
        val totalPages: Int
    )

    private fun resolveBookmarkPages(spec: DocSpec): BookmarkResolution {
        val result = HashMap<String, Int>()
        var pageCounter = 0 // عدد صفحات PDF الفعلية "المُكتملة" حتى الآن
        for (pageSpec in spec.pages) {
            if (spec.isPrecomposed) {
                // صفحة واحدة بالضبط بلا تصفيح — انظر renderPrecomposedPage.
                pageCounter++
                val pageBookmarks = ArrayList<String>()
                for (block in pageSpec.blocks) collectBookmarksRecursive(block, pageBookmarks)
                for (name in pageBookmarks) result.putIfAbsent(name, pageCounter)
            } else if (pageSpec.columnCount > 1) {
                pageCounter = countFlowingPagesMultiColumnDry(pageSpec, pageCounter, result)
            } else {
                pageCounter = countFlowingPageDry(pageSpec, pageCounter, result)
            }
        }
        // ⚠️ تراجع آمن لمستند بلا أي صفحات فعلياً (نظرياً فقط — buildBlankPage
        // يضمن صفحة واحدة دوماً في renderDocument الحقيقية): لا نُرجع صفراً
        // لـtotalPages في هذه الحالة الحدّية، فيتطابق مع ما تفعله
        // renderDocument الحقيقية فعلياً (pageObjNums.add(buildBlankPage...)).
        return BookmarkResolution(result, pageCounter.coerceAtLeast(1))
    }

    /** نسخة قياس خفيفة (بلا أي رسم فعلي) من renderFlowingPage — انظر
     *  تعليق resolveBookmarkPages أعلاه لتفصيل القيد المُتعمَّد. تُحاكي
     *  بدقة نفس قرارات "متى ننتقل لصفحة جديدة" (newPage عند فيضان كتلة)
     *  مع تسجيل أي bookmark تصل إليه حلقة الكتل في رقم الصفحة الحالي
     *  *عند الوصول إليه*، ثم تُعيد رقم الصفحة الإجمالي بعد هذا القسم
     *  (pageCounter الداخل + عدد الصفحات الناتجة هنا). */
    private fun countFlowingPageDry(
        pageSpec: PageSpec, startPageCounter: Int, out: MutableMap<String, Int>
    ): Int {
        val wPts = pageSpec.widthPt
        val hPts = pageSpec.heightPt
        val marginTop = pageSpec.marginTopPt.toFloat() + pageSpec.headerHeightPt.toFloat()
        val contentWidth = (wPts - pageSpec.marginLeftPt - pageSpec.marginRightPt).toFloat()
        val hardBottom = (hPts - pageSpec.marginBottomPt).toFloat() - pageSpec.footerHeightPt.toFloat()

        var pageCounter = startPageCounter + 1 // أول صفحة تبدأ فوراً (مطابق finishCurrentPage الأول الحتمي)
        var cursorY = marginTop
        var maxY = hardBottom
        val pageFootnotes = ArrayList<String>()

        fun footnoteBlockHeight(): Float {
            if (pageFootnotes.isEmpty()) return 0f
            var h = 14f
            for (note in pageFootnotes) {
                h += measureParagraph(footnoteParagraph(note), contentWidth).height
            }
            return h
        }
        fun recomputeMaxY() {
            maxY = (hardBottom - footnoteBlockHeight()).coerceAtLeast(marginTop + 20f)
        }
        fun newPage() {
            pageCounter++
            cursorY = marginTop
            pageFootnotes.clear()
            maxY = hardBottom
        }

        for (block in pageSpec.blocks) {
            if (block is Block.PageBreak) {
                // ⚠️ حراسة ضد صفحة فارغة عرضية: فاصل صفحة صريح في أعلى
                // صفحة لم يُرسَم فيها أي محتوى بعد (cursorY ما زال
                // marginTop) يُتجاهَل — وإلا أنتج صفحة فارغة كاملة. يطابق
                // سلوك معظم محوّلات DOCX (فاصل مكرر/في بداية قسم لا يولّد
                // صفحة بيضاء). *يجب* أن يبقى هذا الشرط مطابقاً حرفياً في
                // renderFlowingPage الفعلية (ومساري multi-column) لئلا
                // يختل حساب NUMPAGES/أرقام الصفحات بين القياس الجاف والرسم.
                if (cursorY > marginTop) newPage()
                continue
            }
            val neededHeight = measureBlockHeight(block, contentWidth)
            if (cursorY + neededHeight > maxY && cursorY > marginTop) {
                newPage()
            }
            // ⚠️ تسجيل أي bookmark في هذه الكتلة *عند بداية رسمها* (رقم
            // الصفحة الحالي بعد قرار newPage أعلاه إن وُجد).
            val blockBookmarks = ArrayList<String>()
            collectBookmarksRecursive(block, blockBookmarks)
            for (name in blockBookmarks) out.putIfAbsent(name, pageCounter)
            // ⚠️ محاكاة فيضان فقرة واحدة عبر أكثر من صفحة (drawParagraphFlowing
            // الحقيقية تستدعي onOverflowNewPage() داخلياً سطراً بسطر — انظر
            // تعليق resolveBookmarkPages لتفصيل لماذا هذا ضروري بدقة كافية
            // هنا وليس حالة نادرة يمكن تجاهلها: فقرات حشو طويلة شائعة في
            // مستندات اختبار/تقارير حقيقية). نحاكي فقط *عدد* الصفحات
            // الإضافية الناتجة (لا موضع كل سطر بدقة بكسلية — غير ضروري
            // لغرض العدّ)، عبر تقسيم ارتفاع الفقرة الفائض على المساحة
            // المتاحة لكل صفحة كاملة تالية؛ تقريب طفيف محتمل (±سطر واحد
            // عند حدود الصفحة) لا يؤثر على دقة bookmark (مُسجَّل أعلاه
            // *قبل* هذا المنطق دوماً) ولا على NUMPAGES بفارق يُذكر عملياً.
            if (block is Block.Paragraph && cursorY + neededHeight > maxY) {
                var remaining = neededHeight - (maxY - cursorY)
                val perPageCapacity = (maxY - marginTop).coerceAtLeast(1f)
                while (remaining > 0f) {
                    newPage()
                    remaining -= perPageCapacity
                }
                cursorY = marginTop + (if (remaining < 0f) (-remaining) else 0f)
            } else {
                cursorY += neededHeight
            }
            val blockFootnotes = ArrayList<String>()
            collectFootnotesRecursive(block, blockFootnotes)
            if (blockFootnotes.isNotEmpty()) {
                pageFootnotes.addAll(blockFootnotes)
                recomputeMaxY()
            }
        }
        return pageCounter
    }

    /** نظيرة countFlowingPageDry لمسار الأعمدة المتعددة
     *  (renderFlowingPageMultiColumn) — نفس القيد المُتعمَّد، نفس المبدأ:
     *  قياس بحت بلا رسم فعلي، تسجيل bookmark عند الوصول إليه. */
    private fun countFlowingPagesMultiColumnDry(
        pageSpec: PageSpec, startPageCounter: Int, out: MutableMap<String, Int>
    ): Int {
        val wPts = pageSpec.widthPt
        val hPts = pageSpec.heightPt
        val marginTop = pageSpec.marginTopPt.toFloat() + pageSpec.headerHeightPt.toFloat()
        val totalContentWidth = (wPts - pageSpec.marginLeftPt - pageSpec.marginRightPt).toFloat()
        val maxY = (hPts - pageSpec.marginBottomPt).toFloat() - pageSpec.footerHeightPt.toFloat()
        val colCount = pageSpec.columnCount
        val spacing = pageSpec.columnSpacingPt.toFloat()
        val colWidth = ((totalContentWidth - spacing * (colCount - 1)) / colCount).coerceAtLeast(20f)

        var pageCounter = startPageCounter + 1
        var colIdx = 0
        var cursorY = marginTop

        fun newPage() {
            pageCounter++
            colIdx = 0
            cursorY = marginTop
        }
        fun advanceColumnOrPage() {
            if (colIdx < colCount - 1) {
                colIdx++
                cursorY = marginTop
            } else {
                newPage()
            }
        }

        for (block in pageSpec.blocks) {
            if (block is Block.PageBreak) {
                // حراسة الصفحة الفارغة — انظر تعليق countFlowingPageDry.
                // الشرط الموحّد cursorY > marginTop يطابق المسار الفعلي.
                if (cursorY > marginTop) newPage()
                continue
            }
            val neededHeight = measureBlockHeight(block, colWidth)
            if (cursorY + neededHeight > maxY && cursorY > marginTop) {
                advanceColumnOrPage()
            }
            val blockBookmarks = ArrayList<String>()
            collectBookmarksRecursive(block, blockBookmarks)
            for (name in blockBookmarks) out.putIfAbsent(name, pageCounter)
            // ⚠️ نفس محاكاة فيضان الفقرة الواحدة المُطبَّقة في
            // countFlowingPageDry أعلاه — هنا onOverflowNewPage الحقيقي
            // هو advanceColumnOrPage (يتقدّم لعمود تالٍ أولاً، لا صفحة
            // جديدة دوماً، إلا في العمود الأخير) لا newPage مباشرة.
            if (block is Block.Paragraph && cursorY + neededHeight > maxY) {
                var remaining = neededHeight - (maxY - cursorY)
                val perColumnCapacity = (maxY - marginTop).coerceAtLeast(1f)
                while (remaining > 0f) {
                    advanceColumnOrPage()
                    remaining -= perColumnCapacity
                }
                cursorY = marginTop + (if (remaining < 0f) (-remaining) else 0f)
            } else {
                cursorY += neededHeight
            }
        }
        return pageCounter
    }

    private fun renderFlowingPage(
        writer: PdfWriter, fontManager: PdfFontManager, pageSpec: PageSpec, parentObjNum: Int,
        extGStateManager: PdfExtGStateManager? = null,
        startPageNum: Int = 1, totalPages: Int = 1,
        reservedObjNumForPage: (Int) -> Int? = { null },
        bookmarkObjNumOf: (String) -> Int? = { null }
    ): List<Int> {
        // ⚠️ إصلاح حقيقي (الأعمدة المتعددة): قبل هذا الإصلاح، columnCount
        // كان يُتجاهَل كلياً ويُرسم القسم بعمود واحد كامل العرض دوماً.
        // المسار أدناه يُفعَّل فقط حين columnCount > 1 (المسار الأصلي
        // بعمود واحد يبقى كما كان حرفياً لتفادي أي تغيير سلوك في الحالة
        // الأكثر شيوعاً)؛ المسار متعدد الأعمدة يقسّم contentWidth إلى
        // أعمدة متساوية بفجوة columnSpacingPt بينها، ويملأ كل عمود
        // بالكتل تتابعياً (مطابقاً لسلوك Word: يمتلئ العمود الأول، ثم
        // الثاني...) قبل الانتقال لصفحة جديدة (لا لعمود جديد) فقط عند
        // فيضان *آخر* عمود في الصفحة.
        if (pageSpec.columnCount > 1) {
            return renderFlowingPageMultiColumn(
                writer, fontManager, pageSpec, parentObjNum, extGStateManager, startPageNum, totalPages,
                reservedObjNumForPage, bookmarkObjNumOf
            )
        }

        val wPts = pageSpec.widthPt
        val hPts = pageSpec.heightPt
        // ⚠️ إصلاح حقيقي (الهيدر والفوتر غائبان كلياً): نحجز مساحة الهيدر/
        // الفوتر *قبل* بداية/نهاية منطقة المحتوى الرئيسية، بدل تركها تتداخل
        // مع أول/آخر سطر محتوى — marginTop الفعلي للمحتوى يصبح الهامش
        // الأصلي زائد ارتفاع الهيدر (إن وُجد)، وكذلك الحد الأسفل الصلب
        // يتراجع بارتفاع الفوتر. لا تغيير سلوك لمستند بلا هيدر/فوتر
        // (headerHeightPt/footerHeightPt تساوي 0.0 افتراضياً).
        val marginTop = pageSpec.marginTopPt.toFloat() + pageSpec.headerHeightPt.toFloat()
        val marginLeft = pageSpec.marginLeftPt.toFloat()
        val contentWidth = (wPts - pageSpec.marginLeftPt - pageSpec.marginRightPt).toFloat()
        val hardBottom = (hPts - pageSpec.marginBottomPt).toFloat() - pageSpec.footerHeightPt.toFloat()

                val resultPages = ArrayList<Int>()
        // ⚠️ نفس إصلاح الإيموجي/خط F6 التالف أعلاه: imageManager يُبنى هنا
        // أولاً (متغيّر منفصل) ثم يُمرَّر لكليهما (DrawCtx وPdfContentBuilder)
        // بدل تركه افتراضياً null في PdfContentBuilder كما كان سابقاً.
        val initialImageManager = PdfImageManager(writer)
        val ctx = DrawCtx(PdfContentBuilder(fontManager, initialImageManager), initialImageManager, hPts.toFloat(), extGStateManager)
        var cursorY = marginTop
        pageSpec.watermark?.let { ctx.drawWatermark(it, wPts.toFloat(), hPts.toFloat()) }

        val pageFootnotes = ArrayList<String>()
        var maxY = hardBottom

        fun footnoteBlockHeight(): Float {
            if (pageFootnotes.isEmpty()) return 0f
            var h = 14f // فاصل + هامش بسيط أعلى الشريط
            for (note in pageFootnotes) {
                h += measureParagraph(footnoteParagraph(note), contentWidth).height
            }
            return h
        }

        fun recomputeMaxY() {
            maxY = (hardBottom - footnoteBlockHeight()).coerceAtLeast(marginTop + 20f)
        }

        fun drawFootnotesBlock() {
            if (pageFootnotes.isEmpty()) return
            var fy = maxY + 10f
            run {
                val py = ctx.pointY(fy)
                ctx.cb.setStrokeColor(android.graphics.Color.GRAY)
                ctx.cb.setLineWidth(0.5f)
                ctx.cb.drawLine(marginLeft, py, marginLeft + contentWidth * 0.35f, py)
            }
            fy += 6f
            for (note in pageFootnotes) {
                val measured = measureParagraph(footnoteParagraph(note), contentWidth)
                drawLayoutLines(ctx, measured, marginLeft, fy, 0, measured.layout.lineCount)
                fy += measured.height
            }
        }

        fun finishCurrentPage() {
            drawFootnotesBlock()
            pageSpec.pageBorder?.let { ctx.drawPageBorder(it, wPts.toFloat(), hPts.toFloat()) }
            // ⚠️ إصلاح حقيقي (الهيدر والفوتر غائبان كلياً): يُستدعى هنا
            // تحديداً (داخل finishCurrentPage، لا مرة واحدة بعد الحلقة)
            // لأن هذه الدالة هي نقطة الإنهاء الفعلية لكل صفحة ناتجة، بما
            // فيها صفحات الفائض الناتجة عن newPage() — هذا تحديداً ما
            // يضمن تكرار الهيدر/الفوتر تلقائياً على *كل* صفحة فعلية من
            // المستند، لا فقط أول صفحة من القسم.
            // ⚠️ إصلاح حقيقي (NUMPAGES/PAGE تُكتب كرموز PUا خام): رقم
            // الصفحة الفعلي الحالي = startPageNum (رقم أول صفحة من هذا
            // القسم، 1-indexed — يساوي عدد صفحات كل الأقسام السابقة + 1)
            // + resultPages.size *قبل* الإضافة أدناه (عدد صفحات هذا
            // القسم المُكتملة سابقاً، أي 0 لأول صفحة من القسم نفسه).
            val currentPageNum = startPageNum + resultPages.size
            drawPageHeaderFooter(ctx, pageSpec, wPts.toFloat(), hPts.toFloat(), currentPageNum, totalPages)
            // ⚠️ إصلاح حقيقي (الروابط التشعبية) — انظر تعليق finalizePage
            // وPendingLinkAnnotation. ctx.pendingLinks تتراكم على *نفس*
            // كائن ctx المُعاد استخدامه عبر كل صفحات هذا القسم (newPage
            // تستبدل فقط ctx.cb/ctx.imageManager، لا ctx نفسه) — لذا
            // *يجب* تصفيرها فوراً بعد كل استهلاك هنا، وإلا تسرّبت روابط
            // صفحة سابقة (بمواضعها الإحداثية الخاطئة لصفحة لاحقة) إلى كل
            // صفحة تالية من نفس القسم.
            resultPages.add(finalizePage(
                writer, fontManager, ctx.imageManager, parentObjNum, wPts, hPts, ctx.cb.build(), extGStateManager,
                pendingLinks = ctx.pendingLinks,
                reservedPageObjNum = reservedObjNumForPage(currentPageNum),
                bookmarkObjNumOf = bookmarkObjNumOf
            ))
            ctx.pendingLinks.clear()
        }

        fun newPage() {
            finishCurrentPage()
            // ⚠️ نفس إصلاح الإيموجي/خط F6 التالف: imageManager الجديد يُبنى
            // أولاً ثم يُمرَّر لكليهما، بدل ترك PdfContentBuilder بلا
            // imageManager (null) كما كان سابقاً عند كل تجاوز لصفحة جديدة.
            val newImageManager = PdfImageManager(writer)
            ctx.imageManager = newImageManager
            ctx.cb = PdfContentBuilder(fontManager, newImageManager)
            cursorY = marginTop
            pageFootnotes.clear()
            maxY = hardBottom
            pageSpec.watermark?.let { ctx.drawWatermark(it, wPts.toFloat(), hPts.toFloat()) }
        }


        for (block in pageSpec.blocks) {
            if (block is Block.PageBreak) {
                // حراسة الصفحة الفارغة (مطابقة حرفياً لـcountFlowingPageDry
                // لضمان تطابق أرقام الصفحات بين القياس الجاف والرسم).
                if (cursorY > marginTop) newPage()
                continue
            }
            val neededHeight = measureBlockHeight(block, contentWidth)
            if (cursorY + neededHeight > maxY && cursorY > marginTop) {
                newPage()
            }
            cursorY = drawBlock(
                ctx, block, marginLeft, cursorY, contentWidth,
                spec = pageSpec,
                pageBottomLimit = maxY,
                onOverflowNewPage = { newPage() },
                marginTopOfNewPage = marginTop
            )
            // ⚠️ إصلاح دقيق: الهوامش تُضاف *بعد* رسم الفقرة كاملة (لا قبله)،
            // لأن الفقرة قد تفيض لصفحة جديدة عبر onOverflowNewPage أثناء
            // رسمها (drawParagraphFlowing)، الذي يُصفِّر pageFootnotes فوراً
            // (newPage). إضافتها قبلياً كانت تُفقدها كلياً في تلك الحالة —
            // لا تظهر في أي صفحة. بإضافتها بعدياً، تنتمي الهوامش دوماً إلى
            // الصفحة التي *انتهى* رسم الفقرة فيها فعلياً (الأقرب لموضع
            // رقمها المرجعي ضمن النص، لأن footnoteReference يقع عادة قريباً
            // من نهاية الجملة/الفقرة الحاملة له).
            // ⚠️ إصلاح حقيقي (هوامش داخل خلايا الجداول): collectFootnotesRecursive
            // بدل فحص block.footnotes المباشر فقط — انظر تعليقها أعلاه.
            val blockFootnotes = ArrayList<String>()
            collectFootnotesRecursive(block, blockFootnotes)
            if (blockFootnotes.isNotEmpty()) {
                pageFootnotes.addAll(blockFootnotes)
                recomputeMaxY()
            }
        }
        finishCurrentPage()
        return resultPages
    }

    /** مسار الأعمدة المتعددة (DOCX w:cols num>1): يقسّم منطقة المحتوى إلى
     * [PageSpec.columnCount] أعمدة متساوية العرض بفجوة [PageSpec
     * .columnSpacingPt] بينها، ويملأ كل عمود بالكتل تتابعياً (الكتلة
     * التي لا تكتمل في عمود تكمل أعلى العمود التالي تماماً كآلية تدفّق
     * الفقرة العادية بين الصفحات، بإعادة استخدام نفس منطق
     * drawParagraphFlowing لتقسيم الأسطر). لا دعم للهوامش (footnotes)
     * هنا في v1 — حالة نادرة (هامش داخل قسم متعدد الأعمدة)، تُرسم بدلاً
     * من ذلك في نهاية تدفّق العمود الأخير إن وُجدت (تراجع آمن، لا فقدان
     * بيانات، فقط موضع أقل دقة من الحالة العادية). */
    private fun renderFlowingPageMultiColumn(
        writer: PdfWriter, fontManager: PdfFontManager, pageSpec: PageSpec, parentObjNum: Int,
        extGStateManager: PdfExtGStateManager? = null,
        startPageNum: Int = 1, totalPages: Int = 1,
        reservedObjNumForPage: (Int) -> Int? = { null },
        bookmarkObjNumOf: (String) -> Int? = { null }
    ): List<Int> {
        val wPts = pageSpec.widthPt
        val hPts = pageSpec.heightPt
        // ⚠️ نفس إصلاح الهيدر/الفوتر الغائبين كلياً المُطبَّق أعلاه في
        // renderFlowingPage — هذا تحديداً المسار الذي رسم قسم Landscape/
        // الأعمدة في الاختبار الفعلي بلا فوتر "Section 2 footer" إطلاقاً،
        // لأن هذه الدالة (المسار الوحيد حين columnCount > 1) لم تكن
        // تستدعي أي رسم هيدر/فوتر من الأساس.
        val marginTop = pageSpec.marginTopPt.toFloat() + pageSpec.headerHeightPt.toFloat()
        val marginLeft = pageSpec.marginLeftPt.toFloat()
        val totalContentWidth = (wPts - pageSpec.marginLeftPt - pageSpec.marginRightPt).toFloat()
        val maxY = (hPts - pageSpec.marginBottomPt).toFloat() - pageSpec.footerHeightPt.toFloat()

        val colCount = pageSpec.columnCount
        val spacing = pageSpec.columnSpacingPt.toFloat()
        val colWidth = ((totalContentWidth - spacing * (colCount - 1)) / colCount).coerceAtLeast(20f)

        fun colX(colIdx: Int): Float = marginLeft + colIdx * (colWidth + spacing)

        val resultPages = ArrayList<Int>()
        val deferredFootnotes = ArrayList<String>()

        var imageManager = PdfImageManager(writer)
        // ⚠️ نفس إصلاح الإيموجي/خط F6 التالف المُطبَّق أعلاه في
        // renderPrecomposedPage وrenderFlowingPage — انظر تعليق مفصَّل هناك.
        var cb = PdfContentBuilder(fontManager, imageManager)
        var ctx = DrawCtx(cb, imageManager, hPts.toFloat(), extGStateManager)
        var colIdx = 0
        var cursorY = marginTop
        pageSpec.watermark?.let { ctx.drawWatermark(it, wPts.toFloat(), hPts.toFloat()) }

        fun drawDeferredFootnotes() {
            if (deferredFootnotes.isEmpty()) return
            var fy = maxY - 4f
            // نرسم الهوامش المؤجَّلة (إن وُجدت) في عمود إضافي افتراضي بعرض
            // العمود الأخير، أسفل الصفحة الحالية، فوق هامشها السفلي مباشرة
            // — تراجع آمن وليس الموضع الدقيق لسلوك Word لكنه يحافظ على كل
            // محتوى الهامش (لا فقدان بيانات) في هذه الحالة النادرة v1.
            val totalH = deferredFootnotes.sumOf {
                measureParagraph(footnoteParagraph(it), totalContentWidth).height.toDouble()
            }.toFloat()
            fy = (maxY - totalH - 6f).coerceAtLeast(marginTop)
            for (note in deferredFootnotes) {
                val measured = measureParagraph(footnoteParagraph(note), totalContentWidth)
                drawLayoutLines(ctx, measured, marginLeft, fy, 0, measured.layout.lineCount)
                fy += measured.height
            }
            deferredFootnotes.clear()
        }

        fun finishCurrentPage() {
            drawDeferredFootnotes()
            pageSpec.pageBorder?.let { ctx.drawPageBorder(it, wPts.toFloat(), hPts.toFloat()) }
            // ⚠️ إصلاح حقيقي (الهيدر والفوتر غائبان كلياً) — انظر التعليق
            // المطوَّل في renderFlowingPage.finishCurrentPage أعلاه؛ نفس
            // المنطق هنا بالضبط، وهذا تحديداً المسار الذي كان يرسم قسم
            // Landscape/الأعمدة بلا أي فوتر في الاختبار الفعلي.
            // ⚠️ إصلاح حقيقي (NUMPAGES/PAGE) — نفس منطق renderFlowingPage
            // أعلاه بالضبط: startPageNum + resultPages.size قبل الإضافة.
            val currentPageNum = startPageNum + resultPages.size
            drawPageHeaderFooter(ctx, pageSpec, wPts.toFloat(), hPts.toFloat(), currentPageNum, totalPages)
            // ⚠️ إصلاح حقيقي (الروابط التشعبية) — بخلاف renderFlowingPage،
            // لا حاجة لـctx.pendingLinks.clear() يدوي بعد الاستهلاك هنا:
            // newPage() أدناه (انظرها) تبني ctx جديداً تماماً (لا تُعدِّل
            // ctx الحالي في مكانه)، فقائمة pendingLinks الخاصة بالصفحة
            // التالية تبدأ فارغة تلقائياً بحكم كونها على كائن DrawCtx
            // مختلف بالكامل.
            resultPages.add(finalizePage(
                writer, fontManager, imageManager, parentObjNum, wPts, hPts, cb.build(), extGStateManager,
                pendingLinks = ctx.pendingLinks,
                reservedPageObjNum = reservedObjNumForPage(currentPageNum),
                bookmarkObjNumOf = bookmarkObjNumOf
            ))
        }

        fun newPage() {
            finishCurrentPage()
            imageManager = PdfImageManager(writer)
            cb = PdfContentBuilder(fontManager, imageManager)
            ctx = DrawCtx(cb, imageManager, hPts.toFloat(), extGStateManager)
            colIdx = 0
            cursorY = marginTop
            pageSpec.watermark?.let { ctx.drawWatermark(it, wPts.toFloat(), hPts.toFloat()) }
        }

        fun advanceColumnOrPage() {
            if (colIdx < colCount - 1) {
                colIdx++
                cursorY = marginTop
            } else {
                newPage()
            }
        }

        for (block in pageSpec.blocks) {
            if (block is Block.PageBreak) {
                // حراسة الصفحة الفارغة — مطابقة لمسار القياس الجاف.
                if (cursorY > marginTop) newPage()
                continue
            }
            // ⚠️ إصلاح حقيقي (هوامش داخل خلايا الجداول) — انظر تعليق
            // collectFootnotesRecursive الكامل في renderFlowingPage أعلاه؛
            // نفس الإصلاح هنا في مسار الأعمدة المتعددة.
            val blockFootnotes = ArrayList<String>()
            collectFootnotesRecursive(block, blockFootnotes)
            if (blockFootnotes.isNotEmpty()) {
                deferredFootnotes.addAll(blockFootnotes)
            }
            val neededHeight = measureBlockHeight(block, colWidth)
            if (cursorY + neededHeight > maxY && cursorY > marginTop) {
                advanceColumnOrPage()
            }
            cursorY = drawBlock(
                ctx, block, colX(colIdx), cursorY, colWidth,
                spec = pageSpec,
                pageBottomLimit = maxY,
                onOverflowNewPage = { advanceColumnOrPage() },
                marginTopOfNewPage = marginTop
            )
        }
        finishCurrentPage()
        return resultPages
    }

    /** يبني فقرة هامش مصغّرة قابلة للقياس/الرسم بنفس مسار StaticLayout
     * العادي — حجم خط أصغر (9pt) ومحاذاة تلقائية (تكتشف العربي/اللاتيني
     * من أول حرف قوي في النص تماماً كبقية المستند). */
    private fun footnoteParagraph(text: String): Block.Paragraph = Block.Paragraph(
        runs = listOf(TextRun(text, FontSpec("Amiri", 9.0, false, false, Color.DKGRAY, null, false, false, "none"))),
        align = "auto",
        direction = "auto",
        spaceBeforePt = 0.0,
        spaceAfterPt = 3.0,
        lineSpacingMultiplier = 1.0,
        indentStartPt = 0.0,
        firstLineIndentPt = 0.0,
        listLevel = null,
        listOrdered = false,
        listMarker = null
    )

    // ⚠️ DrawCtx (سياق رسم صفحة واحدة) انتقلت إلى ملف DrawCtx.kt مستقل،
    // لأنها أصبحت تُستخدَم من عدة ملفات رسم معاً (انظر تعليق DrawCtx.kt).

    // ===================== رسم/قياس كتلة واحدة =====================

    private fun measureBlockHeight(block: Block, contentWidth: Float): Float = when (block) {
        is Block.Paragraph -> measureParagraph(block, contentWidth).height + block.spaceBeforePt.toFloat() + block.spaceAfterPt.toFloat()
        is Block.Divider -> block.thicknessPt.toFloat() + block.spaceBeforePt.toFloat() + block.spaceAfterPt.toFloat()
        is Block.Table -> measureTableHeight(block, contentWidth)
        is Block.ImageBlock -> block.heightPt.toFloat()
        is Block.Chart -> block.heightPt.toFloat()
        is Block.ShapeBlock -> block.heightPt.toFloat()
        is Block.GroupBlock -> block.heightPt.toFloat()
        is Block.PageBreak -> 0f
    }

        private fun drawBlock(
        ctx: DrawCtx,
        block: Block,
        x: Float,
        y: Float,
        maxWidth: Float,
        spec: PageSpec,
        pageBottomLimit: Float? = null,
        onOverflowNewPage: (() -> Unit)? = null,
        marginTopOfNewPage: Float = y
    ): Float {
        return when (block) {
            is Block.Paragraph -> drawParagraphFlowing(
                ctx, block, x, y, maxWidth, pageBottomLimit, onOverflowNewPage, marginTopOfNewPage
            )
            is Block.Divider -> {
                var cy = y + block.spaceBeforePt.toFloat()
                if (block.thicknessPt > 0f) {
                    ctx.cb.setStrokeColor(block.colorArgb)
                    ctx.cb.setLineWidth(block.thicknessPt.toFloat())
                    val py = ctx.pointY(cy)
                    ctx.cb.drawLine(x, py, x + maxWidth, py)
                }
                cy + block.thicknessPt.toFloat() + block.spaceAfterPt.toFloat()
            }
            is Block.Table -> drawTable(
                ctx, block, x, y, maxWidth, spec,
                pageBottomLimit, onOverflowNewPage, marginTopOfNewPage
            )
            is Block.ImageBlock -> {
                val bytes = spec.imageAssets[block.assetRef]
                if (bytes != null) {
                    val dx = when (block.align) {
                        "right" -> x + maxWidth - block.widthPt.toFloat()
                        "center" -> x + (maxWidth - block.widthPt.toFloat()) / 2f
                        else -> x
                    }
                    ctx.drawBitmapFit(bytes, dx, y, block.widthPt.toFloat(), block.heightPt.toFloat())
                }
                y + block.heightPt.toFloat()
            }
            is Block.Chart -> {
                drawChart(ctx, block, x, y, maxWidth.coerceAtMost(block.widthPt.toFloat()))
                y + block.heightPt.toFloat()
            }
            is Block.ShapeBlock -> {
                drawShape(ctx, block, x, y)
                y + block.heightPt.toFloat()
            }
            is Block.GroupBlock -> {
                drawGroup(ctx, block, x, y, spec)
                y + block.heightPt.toFloat()
            }
            is Block.PageBreak -> y
        }
    }


    // ===================== الفقرات =====================
    // القياس (StaticLayout) محفوظ حرفياً؛ الرسم يستخرج الان glyphs حقيقية
    // سطراً بسطر بدل layout.draw(canvas)

    /** ⚠️ إصلاح حقيقي (تنسيقات لا تُصدَّر بصرياً: تسطير/شطب/superscript-
     *  subscript/خلفية تظليل/لون نص فردي لكل run): يحفظ حدود [start, end)
     *  كل TextRun أصلي ضمن النص المدمج (sb في buildSpannedAndPaint) مع
     *  FontSpec الكامل الخاص به. السبب الجذري الكامل: TextRunShaper
     *  (المُستخدَم في drawTextLine) يقرأ فقط الـSpans التي تُغيِّر الشكل
     *  الهندسي للـglyph نفسه (خط/حجم — MetricAffectingSpan)، فتظهر
     *  Bold/Italic بصرياً بصحة كاملة. لكنه لا يقرأ إطلاقاً الـSpans
     *  التي ترسم طبقة إضافية فوق/تحت الشكل (UnderlineSpan/
     *  StrikethroughSpan/ForegroundColorSpan لكل run فردي/SuperscriptSpan/
     *  SubscriptSpan الخاصة بإزاحة rise+تصغير) — هذه الـSpans كانت تُقاس
     *  فقط (تُحدِّد التفاف الأسطر وارتفاعها عبر StaticLayout) دون أي أثر
     *  بصري على الإطلاق في الـPDF النهائي، رغم أن drawGlyphRun كان يستخدم
     *  basePaint.color الموحَّد (لون أول run في الفقرة فقط) لكل النص —
     *  فجوة كامنة إضافية في تصدير لون كل run بشكل مستقل لم تكن قد ظهرت
     *  بصرياً في أي اختبار سابق فقط لغياب حالة اختبارية بألوان متعددة. */
    /** ⚠️ إضافة جديدة (الروابط التشعبية القابلة للنقر فعلياً): linkUri/
     *  linkAnchor مُستخرَجان من TextRun.linkUri/linkAnchor الأصلي لهذا
     *  الجزء بالضبط — نفس بنية الزخارف الأخرى الموجودة فعلاً هنا
     *  (highlightColorArgb، underline...، كلها أيضاً من FontSpec وليس
     *  جديداً بنيوياً، فقط امتداد بنفس الأسلوب). انظر تعليق TextRun
     *  وLinkAnnotation في PdfSpecModels.kt/PdfWriter.kt لتفصيل كامل
     *  المشكلة المُصلَحة وكيف تُستهلَك هذه القيمتان لاحقاً في drawLayoutLines. */
    private data class FontRun(
        val start: Int, val end: Int, val font: FontSpec,
        val linkUri: String? = null, val linkAnchor: String? = null
    )

    private data class MeasuredParagraph(
        val layout: StaticLayout, val height: Float, val text: CharSequence, val paint: TextPaint,
        val fontRuns: List<FontRun> = emptyList(),
        // ⚠️ إصلاح حقيقي (تراكب رمز القائمة/المسافة البادئة مع نص الفقرة
        // في LTR): StaticLayout يطبّق LeadingMarginSpan أثناء layout.draw()
        // الداخلي فقط، لكن getLineLeft() لا يعكسه إطلاقاً لمحاذاة
        // ALIGN_NORMAL (LTR). وبما أن هذا المحرّك يتجاوز layout.draw() ويضع
        // النص يدوياً عبر getLineLeft()، كانت المسافة البادئة (بما فيها
        // المساحة المحجوزة لرمز القائمة) تُفقَد كلياً في LTR — فيُرسم نص
        // الفقرة فوق رمزها بنفس الإحداثي تماماً (أُثبت بالفحص: الرمز والنص
        // كلاهما عند x=56.69). نحفظ قيمتي الهامش البادئ (أول سطر/بقية
        // الأسطر) ونضيفهما يدوياً في drawLayoutLines للأسطر LTR فقط (RTL
        // يحسبه getLineRight ضمناً بصحة، فلا يُمَس). صفر للفقرات بلا بادئة.
        val leadingMarginFirstPx: Float = 0f,
        val leadingMarginRestPx: Float = 0f,
        // مواضع الجدولة الكاملة (محاذاة + leader) لهذه الفقرة — يستهلكها
        // مسار رسم الأسطر التي تحوي حرف tab لوضع النص بعد كل tab ورسم الـleader.
        val tabStops: List<TabStopSpec> = emptyList()
    )

    private fun buildSpannedAndPaint(block: Block.Paragraph): Triple<CharSequence, TextPaint, List<FontRun>> {
        val sb = android.text.SpannableStringBuilder()
        val basePaint = TextPaint(Paint.ANTI_ALIAS_FLAG)
        if (block.runs.isNotEmpty()) {
            val f0 = block.runs[0].font
            basePaint.textSize = f0.sizePt.toFloat()
            basePaint.color = f0.colorArgb
            basePaint.typeface = resolveTypeface(f0.family, f0.bold, f0.italic)
            f0.letterSpacing?.let { basePaint.letterSpacing = it }
        }
        val fontRuns = ArrayList<FontRun>(block.runs.size)
        for (run in block.runs) {
            val start = sb.length
            sb.append(run.text)
            val end = sb.length
            if (end == start) continue
            val tf = resolveTypeface(run.font.family, run.font.bold, run.font.italic)
            sb.setSpan(CustomTypefaceSpan(tf), start, end, android.text.Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
            sb.setSpan(android.text.style.AbsoluteSizeSpan(run.font.sizePt.toInt()), start, end, android.text.Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
            sb.setSpan(android.text.style.ForegroundColorSpan(run.font.colorArgb), start, end, android.text.Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (run.font.underline) sb.setSpan(android.text.style.UnderlineSpan(), start, end, android.text.Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (run.font.strikethrough) sb.setSpan(android.text.style.StrikethroughSpan(), start, end, android.text.Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
            when (run.font.superSub) {
                "superscript" -> sb.setSpan(android.text.style.SuperscriptSpan(), start, end, android.text.Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
                "subscript" -> sb.setSpan(android.text.style.SubscriptSpan(), start, end, android.text.Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
                else -> {}
            }
            run.font.letterSpacing?.let { spacing ->
                sb.setSpan(LetterSpacingSpan(spacing), start, end, android.text.Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            // ⚠️ إصلاح حقيقي: نحفظ حدود هذا الـrun بالضبط ضمن النص المدمج
            // مع FontSpec كاملاً، لاستخدامها لاحقاً في drawLayoutLines
            // لرسم التسطير/الشطب/الخلفية/اللون الفردي كعوامل PDF صريحة
            // (انظر تعليق FontRun أعلاه لتفصيل المشكلة الكاملة).
            fontRuns.add(FontRun(start, end, run.font, run.linkUri, run.linkAnchor))
        }
        // ⚠️ إصلاح حقيقي (المسافة البادئة مفقودة كلياً): indentStartPt/
        // firstLineIndentPt كانا يُقرآن من Dart لكن لا يُستخدَمان إطلاقاً
        // في القياس أو الرسم — أي فقرة DOCX بمسافة بادئة (يسارية، أو
        // إضافية للسطر الأول فقط، كحالة "فقرة مقتبسة") كانت تُرسم بنفس
        // محاذاة الفقرات العادية تماماً، بفقدان كامل للمسافة البادئة.
        // LeadingMarginSpan.Standard(first, rest) معيار Android لهذا
        // الغرض بالضبط: أول سطر يحصل على (indentStart + firstLineIndent)
        // والأسطر الباقية على indentStart فقط — يطابق تماماً معنى
        // w:ind/@left + w:ind/@firstLine في DOCX. نحجز أيضاً مساحة إضافية
        // لرمز القائمة (•/1./أ. إلخ) حين تكون هذه فقرة عنصر قائمة، بحيث
        // يُرسم رمز القائمة لاحقاً في drawParagraphFlowing داخل هذه
        // المساحة المحجوزة بالضبط دون تراكب مع نص الفقرة.
        val listMarkerReserveePt = if (block.listLevel != null) LIST_MARKER_RESERVED_WIDTH_PT else 0f
        val indentStartPx = block.indentStartPt.toFloat() + listMarkerReserveePt
        val firstLineExtraPx = block.firstLineIndentPt.toFloat()
        if (indentStartPx > 0f || firstLineExtraPx != 0f) {
            sb.setSpan(
                android.text.style.LeadingMarginSpan.Standard(
                    (indentStartPx + firstLineExtraPx).toInt().coerceAtLeast(0),
                    indentStartPx.toInt().coerceAtLeast(0)
                ),
                0, sb.length,
                android.text.Spannable.SPAN_EXCLUSIVE_EXCLUSIVE
            )
        }
        for (stopPt in block.tabStopsPt) {
            sb.setSpan(
                android.text.style.TabStopSpan.Standard(stopPt.toInt()),
                0, sb.length,
                android.text.Spannable.SPAN_EXCLUSIVE_EXCLUSIVE
            )
        }
        return Triple(sb, basePaint, fontRuns)
    }

    private fun textDirectionHeuristic(direction: String) = when (direction) {
        "rtl" -> TextDirectionHeuristics.RTL
        "ltr" -> TextDirectionHeuristics.LTR
        else -> TextDirectionHeuristics.FIRSTSTRONG_LTR
    }

    /**
     * ⚠️ تصحيح فهم لاحق لإصلاح "انعكاس محاذاة ثلاثي" — راجع تعليق enum
     * _Align وmapAlign في docx_to_pdf_converter.dart (الجهة Dart) أولاً.
     * المشكلة الحقيقية المُصلَحة هناك: Dart كانت تطبّق عكسين مستقلين غير
     * ضروريين (في _parseParagraph وmapAlign) ظنّاً أن "left"/"right" تحتاج
     * تصحيحاً يدوياً حسب RTL قبل وصولها لهذا الجسر — والصحيح أن "left"/
     * "right" يجب أن تصلا بمعناهما المطلق دوماً (يسار/يمين الصفحة الفعلي،
     * مطابقاً تماماً لـw:jc="left"/"right" في DOCX) بلا أي عكس من جهة Dart.
     *
     * لكن العكس *هنا* في Kotlin يبقى ضرورياً وصحيحاً فنياً، لسبب مختلف
     * تماماً عن افتراض Dart الخاطئ: Layout.Alignment.ALIGN_NORMAL/
     * ALIGN_OPPOSITE في StaticLayout/Android **نسبيان لاتجاه نص الفقرة
     * نفسه** (وليسا مطلقين ليسار/يمين الشاشة) — فALIGN_NORMAL لفقرة RTL
     * (المضبوطة عبر setTextDirection حسب direction) يعني فعلياً *يمين*
     * الشاشة، وALIGN_OPPOSITE لها يعني *يسار* الشاشة — عكس تام لما تعنيه
     * نفس القيمتين في فقرة LTR. لذا تبقى هذه الدالة (الطبقة الوحيدة التي
     * تتحدث فعلياً إلى Android Layout API) مسؤولة عن العكس الوحيد
     * الضروري: ترجمة "left"/"right" المطلقتين الواردتين من Dart إلى قيمة
     * ALIGN_NORMAL/ALIGN_OPPOSITE الصحيحة بحسب direction الفعلي للفقرة،
     * فينتج "left" بصرياً = يسار الشاشة دوماً (بصرف النظر عن RTL/LTR)،
     * بعكس السلوك الخاطئ السابق الذي كان يُطبَّق فوق عكسين سابقين من Dart
     * فتراكمت 3 عمليات عكس بدل عملية واحدة صحيحة.
     */
    private fun textAlignment(align: String, direction: String): Layout.Alignment = when (align) {
        "left" -> if (direction == "rtl") Layout.Alignment.ALIGN_OPPOSITE else Layout.Alignment.ALIGN_NORMAL
        "right" -> if (direction == "rtl") Layout.Alignment.ALIGN_NORMAL else Layout.Alignment.ALIGN_OPPOSITE
        "center" -> Layout.Alignment.ALIGN_CENTER
        else -> Layout.Alignment.ALIGN_NORMAL
    }

    private fun measureParagraph(block: Block.Paragraph, maxWidth: Float): MeasuredParagraph {
        val (text, paint, fontRuns) = buildSpannedAndPaint(block)
        val widthPx = ceil(maxWidth.toDouble()).toInt().coerceAtLeast(1)
        val builder = StaticLayout.Builder.obtain(text, 0, text.length, paint, widthPx)
            .setAlignment(textAlignment(block.align.lowercase(), block.direction.lowercase()))
            .setLineSpacing(0f, block.lineSpacingMultiplier.toFloat().takeIf { it > 0f } ?: 1f)
            .setIncludePad(false)
        builder.setTextDirection(textDirectionHeuristic(block.direction.lowercase()))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setUseLineSpacingFromFallbacks(true)
        }
        val layout = builder.build()
        // ⚠️ نفس قيم الهامش البادئ المُطبَّقة كـLeadingMarginSpan في
        // buildSpannedAndPaint بالضبط — نعيد حسابها هنا لتمريرها إلى
        // drawLayoutLines (حيث تُضاف يدوياً لأسطر LTR لتعويض ما يُسقطه
        // getLineLeft، انظر تعليق MeasuredParagraph). يجب أن تطابق المنطق
        // أعلاه حرفياً: المساحة المحجوزة لرمز القائمة + indentStart للهامش
        // الأساسي، + firstLineIndent للسطر الأول فقط.
        val listMarkerReserveePt = if (block.listLevel != null) LIST_MARKER_RESERVED_WIDTH_PT else 0f
        val indentStartPx = (block.indentStartPt.toFloat() + listMarkerReserveePt).coerceAtLeast(0f)
        val firstLineExtraPx = block.firstLineIndentPt.toFloat()
        return MeasuredParagraph(
            layout, layout.height.toFloat(), text, paint, fontRuns,
            leadingMarginFirstPx = (indentStartPx + firstLineExtraPx).coerceAtLeast(0f),
            leadingMarginRestPx = indentStartPx,
            tabStops = block.tabStops
        )
    }

    private fun isLineRtl(layout: StaticLayout, lineIndex: Int): Boolean =
        layout.getParagraphDirection(lineIndex) == Layout.DIR_RIGHT_TO_LEFT

    /**
     * ⚠️ إصلاح خلل جذري حقيقي مؤكَّد بالفحص الفعلي: انعكاس حرفي تام لأي
     * مقطع لاتيني/رقمي واقع داخل سطر RTL (مثل "Table of Contents" يصدر
     * كـ "stnetnoC fo elbaT"، أو "2026-06-13" يصدر كـ "31-60-6202").
     *
     * السبب الجذري: drawLayoutLines (الإصدار القديم) كان يستدعي
     * isLineRtl() مرة واحدة لكل السطر، ويُمرّر تلك القيمة الواحدة كـ
     * isRtl لنص السطر *كاملاً* (lineStart..lineEnd) دفعة واحدة إلى
     * cb.drawTextLine → TextRunShaper.shapeTextRun. لكن
     * getParagraphDirection() تُرجع اتجاهاً واحداً للسطر ككل فقط — وهي
     * لا تعني أن كل حرف في السطر بذلك الاتجاه؛ سطر RTL يحوي غالباً
     * مقاطع لاتينية/رقمية (bidi mixed) يجب أن تُشكَّل وتُكتب بترتيبها
     * الطبيعي LTR. تمرير isRtl=true على نص يحوي تلك المقاطع يجعل
     * HarfBuzz (عبر shapeTextRun) يُشكِّل المقطع اللاتيني نفسه كجزء من
     * سياق RTL قسري، فيُرجع له ترتيب glyph وموضع x غير صحيحين من
     * الأساس. الفرز اللاحق حسب getGlyphX() في PdfContentBuilder لا
     * يُصحِّح هذا لأنه فرز *لاحق* لمواضع أصلاً فاسدة — يرتّب glyphs
     * بترتيب متّسق مع الخطأ، لا مُصحِّح له.
     *
     * الحل الصحيح وفق Unicode UAX #9 (Bidirectional Algorithm)، القاعدة
     * L2: لا يُحدَّد اتجاه واحد لكامل نص السطر. بل:
     * (1) يُقسَّم نص كل سطر إلى bidi runs متجانسة الاتجاه عبر
     * java.text.Bidi (كل run بأكمله عربي، أو بأكمله
     * لاتيني/رقمي/محايد — لا مزيج داخل نفس run).
     * (2) كل run يُشكَّل ويُكتب عبر drawTextLine بقيمة isRtl *الخاصة
     * به فقط* — لا قيمة السطر العام.
     * (3) اتجاه السطر العام (isLineRtl) يُستخدم فقط لترتيب الـ runs
     * نفسها بصرياً على المحور x (أيها يُرسم أولاً من اليمين) — لا
     * لفرض اتجاه shaping داخل أي run.
     */
    /**
     * ⚠️ إصلاح خلل جذري ثانٍ (تراكب الـ runs فوق بعضها) مؤكَّد بالفحص
     * الفعلي على Ultimate_DOCX_Test: كل سطر يحوي أكثر من bidi run واحد
     * (أي سطر يخلط عربي/لاتيني معاً) كانت كل runs ـه تُرسم من نفس نقطة
     * x + lineLeftPx الثابتة — أي كل run فوق الذي قبله تماماً، بصرف
     * النظر عن طول محتواه. السبب: لم يكن هناك أي تراكم لعرض الـ runs
     * السابقة على المحور x قبل الانتقال للـ run التالي.
     *
     * الحل: drawTextLine ترجع الآن عرض التقدّم الفعلي (glyphs.getAdvance())
     * للـ run الذي رسمته، فنُراكم (cursorX +=) هذا العرض بعد كل run
     * ونستخدم cursorX المُحدَّث كـ baselineX للـ run التالي. بما أن
     * bidiRunsForLine ترجع الـ runs مُرتَّبة بصرياً من اليسار إلى اليمين
     * (انظر تعليقها أعلاه)، هذا التراكم البسيط يضع كل run تماماً بعد
     * الذي قبله على الصفحة، بنفس ترتيب الرسم البصري الصحيح.
     */
    /**
     * ⚠️ إصلاح حقيقي ثالث (تنسيقات لا تُصدَّر بصرياً إطلاقاً): تسطير
     * (بكل أنماطه)، شطب (مفرد/مزدوج)، خلفية تظليل ملوّنة، ولون نص فردي
     * مستقل لكل run — كل هذه كانت تُقاس فقط عبر StaticLayout (تؤثر على
     * التفاف/ارتفاع السطر النظري) دون أي أثر بصري في الـPDF النهائي،
     * لأن drawTextLine (طبقة التصدير الجديدة عبر TextRunShaper) لا تقرأ
     * إطلاقاً أي Span لا يُغيّر الشكل الهندسي لـglyph (فقط
     * MetricAffectingSpan كالخط/الحجم تُقرأ فعلياً، وهذا ما أبقى Bold/
     * Italic سليمين بصرياً رغم كل هذه الثغرة). الحل: نُقسِّم كل bidi run
     * إضافياً إلى أجزاء فرعية متجانسة الـFontSpec (تقاطع حدود bidi run
     * مع حدود fontRuns الأصلية)، نرسم كل جزء بـTextPaint مخصَّص لخصائصه
     * الفردية (لون/حجم/خط)، ثم نرسم فوقه مباشرة عوامل PDF صريحة (خطوط/
     * مستطيلات) للتسطير/الشطب/الخلفية بدلالة العرض الفعلي المُرتجَع من
     * drawTextLine نفسها — لا قياس منفصل قد يتعارض مع نتيجة HarfBuzz
     * الفعلية بعد التشكيل والكerning.
     */
    private fun drawLayoutLines(
        ctx: DrawCtx, measured: MeasuredParagraph, x: Float, cyTop: Float, fromLine: Int, toLine: Int
    ) {
        val layout = measured.layout
        for (lineIdx in fromLine until toLine) {
            val lineStart = layout.getLineStart(lineIdx)
            val lineEnd = layout.getLineEnd(lineIdx)
            if (lineEnd <= lineStart) continue
            val baselineCanvasY = cyTop + layout.getLineBaseline(lineIdx)
            val lineLeftPx = layout.getLineLeft(lineIdx)
            val lineIsRtl = isLineRtl(layout, lineIdx)
            // ارتفاع تقريبي لخط الأساس إلى أعلى الحروف (لرسم خلفية تظليل
            // تغطي ارتفاع النص الفعلي) — يُحسَب من الفرق بين أعلى السطر
            // وخط أساسه، وهو معياري متاح مباشرة من StaticLayout نفسه.
            val lineTopPx = layout.getLineTop(lineIdx)
            val ascentPx = (layout.getLineBaseline(lineIdx) - lineTopPx).toFloat()

            // (bidiRunsForLine يُحسب الآن داخل drawTextRange لكل نطاق على حدة.)
            // ⚠️ إصلاح حقيقي (تراكب رمز القائمة/المسافة البادئة مع نص
            // الفقرة في LTR): نعوّض الهامش البادئ الذي يُسقطه getLineLeft
            // لمحاذاة ALIGN_NORMAL (LTR) — انظر تعليق MeasuredParagraph
            // الكامل. نضيفه فقط حين يكون اتجاه *الفقرة* LTR (لا السطر:
            // الهامش يُطبَّق على جهة بداية الفقرة، وهي اليسار في LTR
            // واليمين في RTL الذي يحسبه getLineLeft/Right ضمناً بصحة فلا
            // يُمَس). السطر الأول من الفقرة يأخذ هامش السطر الأول (يشمل
            // firstLineIndent)، وبقية الأسطر الهامش الأساسي.
            // نقصر التعويض على محاذاة ALIGN_NORMAL تحديداً — وهي الحالة
            // الوحيدة التي يُسقط فيها getLineLeft الهامش البادئ في LTR.
            // للمحاذاة الوسطى/المعاكسة يحسب getLineLeft الإزاحة بنفسه، فلا
            // نضيف شيئاً (وإلا أزحنا النص خطأً). عناصر القوائم والفقرات
            // المُزاحة دوماً ALIGN_NORMAL عملياً.
            val isNormalAlign = layout.alignment == Layout.Alignment.ALIGN_NORMAL
            val paragraphIsLtr = layout.getParagraphDirection(lineIdx) == Layout.DIR_LEFT_TO_RIGHT
            val leadingMarginPx = if (paragraphIsLtr && isNormalAlign) {
                if (lineIdx == 0) measured.leadingMarginFirstPx else measured.leadingMarginRestPx
            } else 0f
            // ⚠️ مسار رسم نطاق نصي قابل لإعادة الاستخدام (للسطر كاملاً، ولكل
            //    مقطع بين علامات الجدولة): يرسم [rangeStart, rangeEnd) ابتداءً
            //    من startX بكامل منطق bidi/الخطوط/الزخارف/الروابط ويُعيد X
            //    النهائي. الجسم أدناه لم يتغيّر؛ غُلِّف فقط في دالة محلية.
            fun drawTextRange(rangeStart: Int, rangeEnd: Int, startX: Float): Float {
                var cursorX = startX
                for (run in bidiRunsForLine(measured.text, rangeStart, rangeEnd, lineIsRtl)) {
                // نقسّم هذا الـbidi run إلى أجزاء فرعية متجانسة الخصائص
                // (نفس FontSpec بالضبط)، ثم نعكس ترتيبها بصرياً إن كان
                // الـrun اتجاهه RTL (انظر تعليق orderedSubRanges أدناه).
                val subRanges = splitRunByFontRuns(run.start, run.end, measured.fontRuns)
                // ⚠️ إصلاح حقيقي (عكس ترتيب أجزاء التنسيق داخل سطر RTL):
                // splitRunByFontRuns يُعيد الأجزاء بالترتيب المنطقي (cursor
                // تصاعدياً). داخل bidi run اتجاهه RTL، يجب رسم هذه الأجزاء
                // بترتيب بصري معكوس — أول جزء منطقي (مثل "كلمة") يجب أن
                // يظهر في أقصى اليمين، لا اليسار. بدون هذا العكس، تظهر
                // جملة مثل «كلمة عريضة... ثم كبيرة... ثم صغيرة» مقلوبةً
                // بصرياً («صغيرة» يميناً و«كلمة» يساراً) حين تحوي عدة
                // أجزاء تنسيق مختلفة (FontSpec مختلف لكل كلمة). الأحرف
                // داخل كل جزء تبقى صحيحة (drawTextLine يُشكِّلها بـisRtl)؛
                // العطل كان في ترتيب الأجزاء على السطر فقط. الأجزاء LTR
                // تبقى بترتيبها المنطقي (تصاعدي) كما هي. (bidiRunsForLine
                // يعكس ترتيب الـruns نفسها فعلاً، لكن السطر RTL الخالص
                // غالباً run واحد يُقسَّم هنا داخلياً، فلا يكفي عكس الـruns
                // وحده — يجب عكس أجزاء font داخل الـrun الواحد أيضاً.)
                val orderedSubRanges = if (run.isRtl) subRanges.asReversed() else subRanges
                for (sub in orderedSubRanges) {
                    val subStart = sub.start; val subEnd = sub.end; val font = sub.font
                    if (subEnd <= subStart) continue
                    val subPaint = paintForFontRun(measured.paint, font)
                    // ⚠️ إصلاح حقيقي (superscript/subscript بلا أثر بصري):
                    // baselineCanvasY يُزاح هنا فعلياً بدلالة verticalRiseForFontRun
                    // (انظر تعليقها) — قبل هذا الإصلاح كان السطر الأساسي
                    // ثابتاً بصرف النظر عن superSub، فيُرسم "2" في "H2O"
                    // بنفس ارتفاع باقي الحروف تماماً، لا مخفوضاً كما
                    // يُفترض بصرياً لصيغة كيميائية صحيحة.
                    val runBaselineY = baselineCanvasY - verticalRiseForFontRun(font)
                    // ⚠️ إصلاح حقيقي (دقة عرض خلفية التظليل): العرض هنا
                    // كان يُقاس سابقاً عبر subPaint.measureText(subText) —
                    // تقدير تقريبي لا يمر عبر HarfBuzz/Minikin إطلاقاً
                    // (لا OpenType GSUB، لا kerning حقيقي)، فيختلف فعلياً
                    // عن العرض الحقيقي الذي سيُرسَم به النص لاحقاً عبر
                    // drawTextLine في الأسطر التالية — الفرق ملحوظ بصرياً
                    // خصوصاً للعربي المُشكَّل (الترابطات multi-character
                    // تُغيّر العرض الفعلي للـglyphs الناتجة عن حروفها
                    // المنفردة) وللنص المُسوّى (justify، الذي يُدرجه
                    // StaticLayout بمسافات بين-كلمات إضافية لا تُحتسَب في
                    // measureText على نص فرعي مُجتزَأ بمعزل عن السطر
                    // الكامل). الحل: نستدعي drawTextLine.measureTextLine
                    // (نفس مسار TextRunShaper.shapeTextRun المُستخدَم
                    // فعلياً في الرسم أدناه، بنفس isRtl لهذا الـrun بالضبط)
                    // فنحصل على نفس قيمة getAdvance() الحقيقية التي
                    // سيُرسَم بها النص حرفياً — لا تقدير منفصل قد يتعارض
                    // معها.
                    if (font?.highlightColorArgb != null) {
                        val estWidth = ctx.cb.measureTextLine(measured.text, subStart, subEnd, run.isRtl, subPaint)
                        // الخلفية تغطي ارتفاع نص الفقرة الأساسي (لا
                        // المرفوع/المخفوض)، فنستخدم baselineCanvasY الأصلي
                        // هنا عمداً لا runBaselineY — تظليل DOCX يغطي
                        // ارتفاع السطر الفعلي بصرف النظر عن superSub.
                        drawHighlightBackground(ctx, font, cursorX, baselineCanvasY, ascentPx, estWidth)
                    }
                    val advance = ctx.cb.drawTextLine(
                        measured.text, subStart, subEnd,
                        cursorX, ctx.pointY(runBaselineY),
                        run.isRtl, subPaint,
                        // ⚠️ إضافة جديدة (النص الشفاف القابل للبحث لأداة
                        // OCR) — انظر تعليق FontSpec.renderMode في
                        // PdfSpecModels.kt. font هنا هو الـFontSpec الأصلي
                        // (قبل تحويله لـTextPaint في subPaint)، فهو المصدر
                        // الصحيح لقراءة renderMode. font قد تكون null في
                        // حالات نادرة (انظر paintForFontRun) فنتعامل معها
                        // بأمان كـ"normal" (لا تغيير سلوك).
                        invisible = font?.renderMode == "invisible"
                    )
                    if (font != null) {
                        drawRunDecorations(ctx, font, cursorX, runBaselineY, ascentPx, advance)
                    }
                    // ⚠️ إصلاح حقيقي جوهري (الروابط التشعبية بلا أي وظيفة
                    // فعلية) — انظر تعليق TextRun.linkUri/linkAnchor في
                    // PdfSpecModels.kt لتفصيل كامل المشكلة. هنا بالضبط
                    // (نفس نقطة drawRunDecorations أعلاه — بعد معرفة
                    // الموضع/العرض الحقيقي للنص المرسوم فعلياً) نجمع
                    // مستطيل النقر الدقيق بإحداثيات PDF الصحيحة (أسفل-
                    // يسار، عبر ctx.pointY مرتين لتحويل الحافتين العلوية
                    // والسفلية) — لا نبني كائن /Annots هنا مباشرة (يتطلب
                    // معرفة رقم كائن الصفحة نفسها، غير معروف إلا بعد
                    // finalizePage لاحقاً)، بل نجمعها في ctx.pendingLinks
                    // ليُستهلِكها finalizePage عند بناء صفحة PDF كاملة.
                    if (sub.linkUri != null || sub.linkAnchor != null) {
                        val descentPx = (layout.getLineBottom(lineIdx) - layout.getLineBaseline(lineIdx)).toFloat()
                        ctx.pendingLinks.add(
                            PendingLinkAnnotation(
                                xMinPt = cursorX,
                                xMaxPt = cursorX + advance,
                                yMinPt = ctx.pointY(runBaselineY + descentPx),
                                yMaxPt = ctx.pointY(runBaselineY - ascentPx),
                                uri = sub.linkUri,
                                anchorName = sub.linkAnchor
                            )
                        )
                    }
                    cursorX += advance
                }
            }
                return cursorX
            }

            // عرض نطاق نصي عبر مسار HarfBuzz نفسه (مجموع أجزاء الخطوط) —
            // مستقل عن ترتيب bidi (العرض لا يتأثر بالاتجاه).
            fun measureRangePx(rs: Int, re: Int): Float {
                if (re <= rs) return 0f
                var w = 0f
                for (sub in splitRunByFontRuns(rs, re, measured.fontRuns)) {
                    if (sub.end <= sub.start) continue
                    w += ctx.cb.measureTextLine(
                        measured.text, sub.start, sub.end, lineIsRtl,
                        paintForFontRun(measured.paint, sub.font)
                    )
                }
                return w
            }

            val cursorX0 = x + lineLeftPx + leadingMarginPx

            // المسار الخاص بعلامات الجدولة يُفعَّل فقط لسطر يحوي حرف tab فعلاً
            // ولديه مواضع جدولة — فالفقرات العادية لا تتأثر بتاتاً (صفر مخاطرة).
            var lineHasTab = false
            run {
                var k = lineStart
                while (k < lineEnd) {
                    if (measured.text[k] == '\t') { lineHasTab = true; break }
                    k++
                }
            }

            if (!lineHasTab || measured.tabStops.isEmpty()) {
                drawTextRange(lineStart, lineEnd, cursorX0)
            } else {
                // نقسّم السطر عند كل '\t'، ونضع كل مقطع تالٍ عند أقرب موضع
                // جدولة بحسب محاذاته (يسار/يمين/وسط/عشري)، مع رسم نقاط الـleader
                // في الفجوة (فهرس المحتويات/الفوتر). الهندسة موجَّهة LTR؛ مقاطع
                // RTL تُرسم بمرجع مواضع من اليسار (تحسين لاحق إن لزم).
                val segs = ArrayList<Pair<Int, Int>>()
                run {
                    var s = lineStart
                    var k = lineStart
                    while (k < lineEnd) {
                        if (measured.text[k] == '\t') { segs.add(Pair(s, k)); s = k + 1 }
                        k++
                    }
                    segs.add(Pair(s, lineEnd))
                }
                val tabOriginX = x
                val defaultTabPx = 36f // ½ بوصة، المسافة الافتراضية
                var cursorXt = drawTextRange(segs[0].first, segs[0].second, cursorX0)
                for (si in 1 until segs.size) {
                    val ss = segs[si].first
                    val se = segs[si].second
                    val stop = measured.tabStops.firstOrNull {
                        (tabOriginX + it.posPt.toFloat()) > cursorXt + 0.5f
                    }
                    val segW = measureRangePx(ss, se)
                    val stopX = if (stop != null) {
                        tabOriginX + stop.posPt.toFloat()
                    } else {
                        tabOriginX + (Math.floor(
                            ((cursorXt - tabOriginX) / defaultTabPx).toDouble()
                        ).toFloat() + 1f) * defaultTabPx
                    }
                    val align = stop?.align ?: "left"
                    var targetStart = when (align) {
                        "right", "decimal" -> stopX - segW
                        "center" -> stopX - segW / 2f
                        else -> stopX
                    }
                    if (targetStart < cursorXt) targetStart = cursorXt // لا تراكب
                    if (stop != null && stop.leader != "none" && targetStart > cursorXt + 1f) {
                        drawTabLeader(ctx, measured.paint, cursorXt, targetStart, baselineCanvasY, stop.leader)
                    }
                    cursorXt = drawTextRange(ss, se, targetStart)
                }
            }
        }
    }

    /** يرسم نقاط (أو شرطات/شُرَط سفلية) الـleader بين [fromX, toX) على خط
     *  الأساس baseY لملء فجوة الجدولة (نقاط فهرس المحتويات مثلاً). */
    private fun drawTabLeader(
        ctx: DrawCtx, paint: TextPaint, fromX: Float, toX: Float, baseY: Float, leader: String
    ) {
        val gap = toX - fromX
        if (gap <= 2f) return
        val ch = when (leader) {
            "hyphen" -> "-"
            "underscore" -> "_"
            else -> "."
        }
        val unit = ctx.cb.measureTextLine(ch, 0, 1, false, paint)
        if (unit <= 0.1f) return
        val n = Math.floor(((gap - 2f) / unit).toDouble()).toInt()
        if (n <= 0) return
        val s = ch.repeat(n)
        ctx.cb.drawTextLine(s, 0, s.length, fromX, ctx.pointY(baseY), false, paint, invisible = false)
    }

    /** يقسّم [start, end) إلى أجزاء فرعية متجانسة بحسب أول FontRun يطابق
     *  كل نقطة (الـfontRuns لا تتداخل أصلاً لأنها بُنيت من runs متتالية
     *  في buildSpannedAndPaint، فالتقاطع البسيط هنا كافٍ ودقيق). جزء
     *  واحد بـfont=null لو لم توجد fontRuns (مستند لا يستخدم المسار
     *  الجديد، أو فقرة خاصة كـfootnoteParagraph التي تبني runs مباشرة
     *  ولن يخسر شيئاً: نفس النص يُرسم، فقط بلا زخارف إضافية).
     *  ⚠️ تُعيد الآن List<FontRun> (بحدود start/end مُعاد ضبطها للجزء
     *  الفرعي تحديداً) بدل Triple<Int,Int,FontSpec?> القديمة — تحمل
     *  FontRun بالفعل كل ما نحتاجه (font + linkUri/linkAnchor الجديدان)
     *  بلا حاجة لبنية بيانات موسَّعة جديدة؛ font=null يُمثَّل بفحص خاص
     *  (تستخدم FontRun.font غير-قابل-لـnull؛ نلتزم بإرجاع null فعلياً
     *  عبر متغيّر مساعد منفصل في حالة الفجوة النادرة بدل افتراض FontSpec
     *  زائف). */
    private data class SubRange(val start: Int, val end: Int, val font: FontSpec?, val linkUri: String?, val linkAnchor: String?)

    private fun splitRunByFontRuns(
        start: Int, end: Int, fontRuns: List<FontRun>
    ): List<SubRange> {
        if (fontRuns.isEmpty()) return listOf(SubRange(start, end, null, null, null))
        val result = ArrayList<SubRange>()
        var cursor = start
        while (cursor < end) {
            val fr = fontRuns.firstOrNull { cursor >= it.start && cursor < it.end }
            if (fr == null) {
                // فجوة بلا FontRun مطابق (نادر، مثل نص أُضيف خارج runs
                // الأصلية) — نتقدّم خطوة واحدة بأمان بلا زخارف لتفادي
                // حلقة لا منتهية، بدل تجاهل بقية النص بالكامل.
                val next = fontRuns.filter { it.start > cursor }.minOfOrNull { it.start } ?: end
                result.add(SubRange(cursor, next.coerceAtMost(end), null, null, null))
                cursor = next.coerceAtMost(end)
                continue
            }
            val segEnd = fr.end.coerceAtMost(end)
            result.add(SubRange(cursor, segEnd, fr.font, fr.linkUri, fr.linkAnchor))
            cursor = segEnd
        }
        return result
    }

    /** يبني TextPaint مخصصاً لـFontSpec فردي عند الحاجة فقط (لون/حجم/خط
     *  يختلف عن basePaint الموحَّد للفقرة، أو superscript/subscript يحتاج
     *  تصغير حجم) — نُعيد basePaint نفسه دون نسخ حين لا فرق فعلي، تفادياً
     *  لتكلفة تخصيص TextPaint لكل جزء بلا حاجة (الحالة الأكثر شيوعاً:
     *  فقرة بخصائص متجانسة لكل runsها).
     *  ⚠️ إصلاح حقيقي (superscript/subscript بلا أي أثر بصري): SuperscriptSpan/
     *  SubscriptSpan في buildSpannedAndPaint كانا يؤثران فقط على القياس
     *  (StaticLayout يحسب ارتفاع سطر أكبر ليستوعبهما نظرياً) لكن
     *  drawTextLine لا تقرأ هذه الـSpans إطلاقاً — فيُرسم "²" بنفس حجم
     *  وموضع النص العادي تماماً، لا مرفوعاً ولا مصغَّراً. هنا نُصغِّر
     *  الحجم فعلياً (نسبة 0.65 تقارب سلوك SuperscriptSpan/SubscriptSpan
     *  المعياري في Android: DEFAULT_SUPERSCRIPT_SHIFT تقريباً) — الإزاحة
     *  الرأسية نفسها تُحسَب وتُطبَّق بشكل مستقل عبر [verticalRiseForFontRun]
     *  المُستدعاة من drawLayoutLines عند تمرير baselineY الفعلي. */
    private fun paintForFontRun(basePaint: TextPaint, font: FontSpec?): TextPaint {
        if (font == null) return basePaint
        val targetSize = if (font.superSub != "none") font.sizePt.toFloat() * SUPER_SUB_SCALE else font.sizePt.toFloat()
        val sameColor = basePaint.color == font.colorArgb
        val sameSize = basePaint.textSize == targetSize
        if (sameColor && sameSize) return basePaint
        val p = TextPaint(basePaint)
        p.color = font.colorArgb
        p.textSize = targetSize
        return p
    }

    /** الإزاحة الرأسية بالنقاط لـsuperscript/subscript، بدلالة حجم الخط
     *  *الأصلي* (قبل تصغيره في paintForFontRun) — موجبة تعني للأعلى على
     *  محور Canvas (Y يتزايد للأسفل، فالرفع البصري = طرح من baselineY). */
    private fun verticalRiseForFontRun(font: FontSpec?): Float {
        if (font == null) return 0f
        val sizePt = font.sizePt.toFloat()
        return when (font.superSub) {
            "superscript" -> sizePt * SUPER_SUB_RISE_FRACTION
            "subscript" -> -sizePt * SUPER_SUB_RISE_FRACTION
            else -> 0f
        }
    }

    /** يرسم خلفية تظليل ملوّنة (w:highlight في DOCX) — مستقلة عن
     *  drawRunDecorations عمداً لأنها تُستدعى *قبل* رسم glyphs النص (لا
     *  بعده)، وإلا تُغطّي النص المرسوم بدل الظهور خلفه (انظر تعليق نقطة
     *  الاستدعاء في drawLayoutLines لتفصيل كامل). */
    private fun drawHighlightBackground(
        ctx: DrawCtx, font: FontSpec, anchorCanvasX: Float, baselineCanvasY: Float,
        ascentPx: Float, width: Float
    ) {
        if (width <= 0f) return
        val hl = font.highlightColorArgb ?: return
        val sizePt = font.sizePt.toFloat()
        val padTop = sizePt * 0.18f
        val padBottom = sizePt * 0.08f
        val topY = baselineCanvasY - ascentPx - padTop
        val rectH = ascentPx + padTop + padBottom
        ctx.cb.setFillColor(hl)
        ctx.cb.fillRect(anchorCanvasX, ctx.rectY(topY, rectH), width, rectH)
    }

    /** يرسم زخارف run واحد (تسطير/شطب) كعوامل PDF صريحة بعد رسم النص
     *  نفسه — anchorX/anchorY بإحداثيات Canvas (قبل التحويل لـ PDF عبر
     *  ctx.pointY)، advanceWidth العرض الفعلي المُرتجَع من drawTextLine
     *  (مساوٍ تماماً لما رُسم فعلياً، لا تقدير منفصل). خلفية التظليل
     *  مفصولة عمداً في drawHighlightBackground أعلاه — انظر تعليقها. */
    private fun drawRunDecorations(
        ctx: DrawCtx, font: FontSpec, anchorCanvasX: Float, baselineCanvasY: Float,
        ascentPx: Float, advanceWidth: Float
    ) {
        if (advanceWidth <= 0f) return
        val sizePt = font.sizePt.toFloat()

        // ⚠️ إصلاح حقيقي (التسطير لا يُرسم بصرياً + أنماط متعددة): نرسم
        // خط/خطوط فعلية بعد النص، بلون النص نفسه (سلوك DOCX الافتراضي
        // حين لا يحدّد w:u/@color لوناً مستقلاً). "wave" تُقارَب بخط
        // متعرّج فعلي (لا PDF نمط شرطي جاهز لمويّجات الخط)، و"dotted"/
        // "dashed" تُقارَب بفجوات منتظمة — أقرب تمثيل بصري بأدوات الرسم
        // الأولية المتاحة (m/l/S) دون حاجة لـ/Pattern معقَّد.
        if (font.underline) {
            val underlineY = baselineCanvasY + sizePt * 0.08f
            val thickness = (sizePt * 0.06f).coerceAtLeast(0.6f)
            ctx.cb.setStrokeColor(font.colorArgb)
            ctx.cb.setLineWidth(thickness)
            when (font.underlineStyle) {
                "double" -> {
                    val gap = thickness * 2.2f
                    ctx.cb.drawLine(anchorCanvasX, ctx.pointY(underlineY), anchorCanvasX + advanceWidth, ctx.pointY(underlineY))
                    ctx.cb.drawLine(anchorCanvasX, ctx.pointY(underlineY + gap), anchorCanvasX + advanceWidth, ctx.pointY(underlineY + gap))
                }
                // ⚠️ إصلاح حقيقي (تشابك بصري كامل مع تشكيل/أسنان الحروف
                // العربية في نص bidi مختلط): drawWavyLine ترسم موجة تتأرجح
                // بين underlineY-amplitude وunderlineY+amplitude، أي يصعد
                // أعلى حد للموجة إلى (baselineCanvasY + sizePt*0.08 -
                // sizePt*0.09) ≈ baselineCanvasY - sizePt*0.01 — عمليًا
                // مباشرة عند خط الأساس نفسه. الحروف العربية تمتد كثيفة
                // الكتلة فوق الأساس مباشرة (تشكيل/أسنان السين-الشين/نقاط)
                // بخلاف اللاتيني الذي ينتهي عادة أعلى من ذلك بوضوح، فتتشابك
                // الموجة بصرياً مع جسم الحرف العربي تحديداً (لوحظ بفحص بصري
                // مباشر: منحنيات الموجة المرسومة فعلياً وقعت ضمن نطاق ارتفاع
                // حروف الكلمة العربية المجاورة، لا تحتها). الحل: نزيح مركز
                // تذبذب الموجة لأسفل إضافياً بنفس مقدار amplitude تقريباً
                // (waveBaseY) قبل تطبيق التذبذب، فيبقى أعلى حد للموجة تحت
                // الأساس بمسافة معقولة تطابق تقريباً نقطة التسطير العادي
                // (underlineY)، بدل أن يتمركز التذبذب حول underlineY نفسها
                // ويتجاوزها للأعلى. لا يغيّر هذا سلوك "single"/"double"/
                // "dotted"/"dashed" إطلاقاً (تبقى عند underlineY كما كانت).
                "wave" -> {
                    val amplitude = sizePt * 0.07f
                    val waveBaseY = underlineY + amplitude
                    drawWavyLine(ctx, anchorCanvasX, waveBaseY, advanceWidth, amplitude)
                }
                "dotted" -> drawDashedLine(ctx, anchorCanvasX, underlineY, advanceWidth, dashPt = thickness * 1.2f, gapPt = thickness * 1.6f)
                "dashed" -> drawDashedLine(ctx, anchorCanvasX, underlineY, advanceWidth, dashPt = sizePt * 0.18f, gapPt = sizePt * 0.1f)
                else -> ctx.cb.drawLine(anchorCanvasX, ctx.pointY(underlineY), anchorCanvasX + advanceWidth, ctx.pointY(underlineY))
            }
        }

        // ⚠️ نفس الإصلاح للشطب — خط في منتصف ارتفاع الحروف الصغيرة تقريباً
        // (strikethrough Y المعياري ≈ baseline - ascent*0.35، يطابق
        // منطقة وسط الحروف اللاتينية/العربية الشائعة).
        if (font.strikethrough) {
            val strikeY = baselineCanvasY - ascentPx * 0.35f
            val thickness = (sizePt * 0.06f).coerceAtLeast(0.6f)
            ctx.cb.setStrokeColor(font.colorArgb)
            ctx.cb.setLineWidth(thickness)
            ctx.cb.drawLine(anchorCanvasX, ctx.pointY(strikeY), anchorCanvasX + advanceWidth, ctx.pointY(strikeY))
            if (font.strikethroughDouble) {
                val gap = thickness * 2.2f
                ctx.cb.drawLine(anchorCanvasX, ctx.pointY(strikeY - gap), anchorCanvasX + advanceWidth, ctx.pointY(strikeY - gap))
            }
        }
    }

    /** خط متموّج تقريبي بقطع مستقيمة قصيرة متتالية (لا منحنيات بيزييه
     *  حقيقية — التعرّج بصري بسيط بهذا الحجم لا يحتاج دقة منحنى كاملة،
     *  وقطع مستقيمة قصيرة جداً تبدو ناعمة بصرياً بعد الطباعة/التصدير). */
    private fun drawWavyLine(ctx: DrawCtx, x: Float, y: Float, width: Float, amplitude: Float) {
        val period = amplitude * 4f
        var cx = x
        var up = true
        ctx.cb.moveTo(x, ctx.pointY(y))
        while (cx < x + width) {
            val nx = (cx + period / 2f).coerceAtMost(x + width)
            val ny = if (up) y - amplitude else y + amplitude
            ctx.cb.lineTo(nx, ctx.pointY(ny))
            cx = nx
            up = !up
        }
        ctx.cb.paintPath(fill = false, stroke = true)
    }

    /** خط متقطّع (نقطي/متقطّع وفق dashPt/gapPt) عبر قطع drawLine متتالية
     *  — لا حاجة لعامل /D (dash pattern) في PDF نفسه، أبسط وأقل عرضة
     *  لتفاصيل ضبط حالة الرسم (g state) بين استدعاءات drawTextLine. */
    private fun drawDashedLine(ctx: DrawCtx, x: Float, y: Float, width: Float, dashPt: Float, gapPt: Float) {
        var cx = x
        val py = ctx.pointY(y)
        while (cx < x + width) {
            val segEnd = (cx + dashPt).coerceAtMost(x + width)
            ctx.cb.drawLine(cx, py, segEnd, py)
            cx = segEnd + gapPt
        }
    }

    private fun drawParagraphFlowing(
        ctx: DrawCtx,
        block: Block.Paragraph,
        x: Float,
        y: Float,
        maxWidth: Float,
        pageBottomLimit: Float?,
        onOverflowNewPage: (() -> Unit)?,
        marginTopOfNewPage: Float = y
    ): Float {
        val cy = y + block.spaceBeforePt.toFloat()
        val measured = measureParagraph(block, maxWidth)
        val layout = measured.layout

        // ⚠️ إصلاح حقيقي (رموز القوائم النقطية/المرقّمة غائبة كلياً) —
        // يُرسَم مرة واحدة فقط هنا (قبل أي تقسيم لاحق على أسطر/صفحات)
        // لأن رمز القائمة يظهر فقط عند *بداية* الفقرة بصرف النظر عمّا
        // يحدث لاحقاً لبقية أسطرها (حتى لو امتدت الفقرة لصفحة تالية،
        // رمز القائمة بقي على الصفحة الأولى فقط — هذا سلوك Word المطابق
        // أيضاً). انظر تعليق drawListMarker لتفصيل المشكلة الكاملة.
        if (block.listLevel != null) {
            drawListMarker(ctx, block, x, cy, layout)
        }

        if (pageBottomLimit == null || onOverflowNewPage == null || cy + measured.height <= pageBottomLimit) {
            drawLayoutLines(ctx, measured, x, cy, 0, layout.lineCount)
            return cy + measured.height + block.spaceAfterPt.toFloat()
        }

        var lineStartIdx = 0
        val lineCount = layout.lineCount
        var localCy = cy

        while (lineStartIdx < lineCount) {
            val lineTopPx = layout.getLineTop(lineStartIdx)
            var lineEndIdx = lineStartIdx
            while (lineEndIdx < lineCount) {
                val lineBottomPx = layout.getLineBottom(lineEndIdx)
                val absoluteBottom = localCy + (lineBottomPx - lineTopPx)
                if (absoluteBottom > pageBottomLimit && lineEndIdx > lineStartIdx) break
                lineEndIdx++
            }
            if (lineEndIdx == lineStartIdx) lineEndIdx = lineStartIdx + 1

            drawLayoutLines(ctx, measured, x, localCy - lineTopPx, lineStartIdx, lineEndIdx)

            val drawnBottomPx = if (lineEndIdx < lineCount) layout.getLineTop(lineEndIdx) else layout.height
            localCy += (drawnBottomPx - lineTopPx).toFloat()
            lineStartIdx = lineEndIdx

            if (lineStartIdx < lineCount) {
                onOverflowNewPage()
                localCy = marginTopOfNewPage
            }
        }
        return localCy + block.spaceAfterPt.toFloat()
    }

    /** يرسم رمز عنصر القائمة (•، 1.، 2.، أ.، إلخ) قبل بداية أول سطر من
     *  الفقرة، داخل مساحة LIST_MARKER_RESERVED_WIDTH_PT المحجوزة مسبقاً
     *  ضمن LeadingMarginSpan في buildSpannedAndPaint (انظر تعليقها).
     *  ⚠️ إصلاح حقيقي: قبل هذا الإصلاح، listLevel/listOrdered/listMarker
     *  كانت تُقرأ من Dart وتُخزَّن في Block.Paragraph، لكن لا أي مكان
     *  في الرسم الفعلي كان يستخدمها — أي قائمة DOCX (نقطية •، أو مرقّمة
     *  1./2./3.، أو حروف أ./ب./ج.) كانت تُرسم كفقرة نص عادية بلا أي
     *  رمز قائمة ظاهر أمامها إطلاقاً، رغم وجود مسافة بادئة (لو طُبِّقت
     *  لاحقاً عبر إصلاح المسافة البادئة أعلاه) خالية بلا أي محتوى فيها.
     *  نستخدم listMarker الصريح إن أُرسل من Dart (الأكثر دقة، يطابق رقم
     *  العنصر الفعلي الذي حسبته Word/طبقة التحويل)، وإلا نقع احتياطياً
     *  على "•" للقوائم غير المرتبة، أو ترقيم تسلسلي تقريبي 1./2.../ بحسب
     *  ترتيب ظهور فقرات بنفس listLevel ضمن نفس مستوى تتابع (best-effort
     *  حين لا تتوفر بيانات الترقيم الفعلي من المصدر). */
    private fun drawListMarker(ctx: DrawCtx, block: Block.Paragraph, x: Float, cy: Float, layout: StaticLayout) {
        val markerText = block.listMarker ?: if (block.listOrdered) "•" else "•"
        if (markerText.isBlank()) return
        val baselineCanvasY = cy + layout.getLineBaseline(0)
        val lineIsRtl = isLineRtl(layout, 0)
        val f0 = block.runs.firstOrNull()?.font
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = f0?.sizePt?.toFloat() ?: 12f
            color = f0?.colorArgb ?: Color.BLACK
            typeface = resolveTypeface(f0?.family ?: "Cairo", f0?.bold ?: false, false)
        }
        // الرمز يُرسم داخل المساحة المحجوزة، محاذياً لجهة البداية المنطقية
        // (يمين الفقرة في RTL، يسارها في LTR) — لا داخل المسافة البادئة
        // الإضافية الخاصة بالفقرة نفسها (indentStartPt) إن وُجدت، فهي
        // مساحة منطقياً سابقة لرمز القائمة نفسه في DOCX (w:ind يُطبَّق
        // على كامل الفقرة بما فيها رمزها).
        // ⚠️ إصلاح حقيقي (دقة عرض رمز القائمة): العرض كان يُقاس سابقاً
        // عبر paint.measureText(markerText) — تقدير لا يمر عبر HarfBuzz
        // إطلاقاً، فقد يختلف عن العرض الفعلي المُشكَّل خصوصاً لرموز
        // القوائم العربية (أ) ب) ج)...، أو ١. ٢. ٣. بأرقام هندية) التي قد
        // تحمل أشكالاً سياقية (contextual forms) مختلفة عن مجرد جمع عرض
        // كل حرف منفرد. نستخدم نفس آلية اكتشاف الاتجاه التي يستخدمها
        // drawTextLineBidiAware بالضبط (أول حرف قوي في النص) لقياس العرض
        // عبر التشكيل الحقيقي (TextRunShaper)، فتطابق نتيجة الرسم الفعلي
        // أدناه تماماً بدل تقدير مستقل قد يتعارض معها.
        val baseBidiForMarker = java.text.Bidi(markerText, java.text.Bidi.DIRECTION_DEFAULT_LEFT_TO_RIGHT)
        val markerIsRtl = !baseBidiForMarker.baseIsLeftToRight()
        val markerWidth = ctx.cb.measureTextLine(markerText, 0, markerText.length, markerIsRtl, paint)
        val markerX = if (lineIsRtl) {
            x + block.indentStartPt.toFloat() + LIST_MARKER_RESERVED_WIDTH_PT - markerWidth
        } else {
            x + block.indentStartPt.toFloat()
        }
        drawTextLineBidiAware(ctx.cb, markerText, markerX, ctx.pointY(baselineCanvasY), paint)
    }

    // ===================== الجداول =====================
    // منطق حساب الشبكة/الارتفاعات محفوظ حرفياً

    /**
     * ⚠️ إصلاح حقيقي (تجاهل كامل لعرض w:tblGrid عند وجود خلايا مدموجة):
     * colCount هنا هو عدد أعمدة الشبكة *بعد* مراعاة colSpan (أي العدد
     * الفعلي لخلايا الشبكة الأساسية التي يُمكن لصف أن يمتد عبرها). أما
     * table.columnWidths فقادم مباشرة من w:tblGrid/w:gridCol في DOCX —
     * وهو يصف عرض كل عمود في *تلك الشبكة الأساسية نفسها*، بصرف النظر
     * عن أي خلية تدمج عدة أعمدة منها بـ colSpan لاحقاً.
     *
     * قبل هذا الإصلاح: كان الشرط `widths.size == colCount` يتطلب تطابقاً
     * حرفياً بين عدد قيم w:tblGrid وعدد أعمدة الشبكة المُشتق، وهذا
     * تطابق نادر عملياً لأن أي جدول يحتوي خلية واحدة بـcolSpan>1 في صفه
     * الأول يجعل colCount (مُشتق من passes أخرى لا تحمل نفس span) يختلف
     * عن w:tblGrid.size في حالات كثيرة شائعة (رؤوس جداول مدمجة، جداول
     * بصفوف غير متجانسة). عند الاختلاف، كان الكود يرفض w:tblGrid كاملاً
     * ويرجع لتوزيع متساوٍ — فيضيع تنسيق عرض أعمدة صريح وُجد فعلياً في
     * الملف الأصلي، ويُنتج جدولاً بعرض أعمدة مختلفاً بصرياً عن Word.
     *
     * الحل: لا نطلب تطابقاً حرفياً، بل نتحقق فقط أن w:tblGrid *يكفي*
     * لتغطية أقصى عمود تصل إليه أي خلية (max start-col + max colSpan
     * عبر كل الشبكة)، وهو الشرط الصحيح هندسياً المطابق لما يفعله محرك
     * Word: كل عمود في الشبكة الأساسية له عرضه من w:tblGrid، وعرض أي
     * خلية مدموجة = مجموع أعراض الأعمدة الأساسية التي تغطيها (محسوب
     * بالفعل في drawTable/computeRowHeights عبر colWidths.getOrElse).
     * إن كان w:tblGrid أقصر من اللازم (نادر، يعني XML غير متّسق) أو
     * غائباً تماماً، نرجع للتوزيع المتساوي كما كان (سلوك احتياطي آمن،
     * لا كسر لأي مستند كان يعمل بشكل صحيح سابقاً عبر هذا المسار).
     */
    private fun resolveColumnWidths(table: Block.Table, totalWidth: Float): FloatArray {
        val colCount = table.rows.maxOfOrNull { row -> row.sumOf { it.colSpan } } ?: 1
        val widths = table.columnWidths
        if (widths != null && widths.size >= colCount && widths.isNotEmpty()) {
            // نأخذ أول colCount قيمة من w:tblGrid فقط — تكفي شبكة الأعمدة
            // الأساسية لتغطية أقصى مدى تصل إليه أي خلية مدموجة، وأي عمود
            // زائد في tblGrid (نادر، عادة بقايا تنسيق غير مستخدَم فعلياً)
            // يُتجاهَل بأمان فلا يُحسَب ضمن النسبة.
            val effectiveWidths = widths.take(colCount)
            val sum = effectiveWidths.sum().toFloat()
            if (sum > 0f) {
                return FloatArray(colCount) { i -> totalWidth * (effectiveWidths[i].toFloat() / sum) }
            }
        }
        return FloatArray(colCount) { totalWidth / colCount }
    }

    private data class PlacedCell(val cell: Block.TableCellModel, val startCol: Int, val gridRow: Int)

    private fun placeCellsOnGrid(table: Block.Table): List<PlacedCell> {
        val placed = mutableListOf<PlacedCell>()
        val occupiedUntilRow = HashMap<Int, Int>()
        for ((gridRow, row) in table.rows.withIndex()) {
            var col = 0
            for (cell in row) {
                while ((occupiedUntilRow[col] ?: 0) > gridRow) col++
                placed.add(PlacedCell(cell, col, gridRow))
                if (cell.rowSpan > 1) {
                    for (c in col until col + cell.colSpan) occupiedUntilRow[c] = gridRow + cell.rowSpan
                }
                col += cell.colSpan
            }
        }
        return placed
    }

    private fun computeRowHeights(table: Block.Table, colWidths: FloatArray, placed: List<PlacedCell>, gridRowCount: Int): FloatArray {
        val rowHeights = FloatArray(gridRowCount)
        for (p in placed) {
            val cellWidth = (0 until p.cell.colSpan).sumOf {
                colWidths.getOrElse(p.startCol + it) { 0f }.toDouble()
            }.toFloat() - 2 * p.cell.paddingPt.toFloat()
            var contentHeight = 0f
            // ⚠️ إصلاح حقيقي: ارتفاع صورة الخلية (إن وُجدت) يُحتسَب الآن
            // ضمن ارتفاع الخلية الكلي قبل الفقرات (الصورة تُرسم أولاً،
            // فوق النص) — كانت الصورة (وارتفاعها) غير محتسبة كلياً سابقاً.
            if (p.cell.imageAssetRef != null) {
                contentHeight += (p.cell.imageHeightPt ?: 0.0).toFloat()
            }
            for (block in p.cell.blocks) contentHeight += measureBlockHeight(block, cellWidth.coerceAtLeast(1f))
            val totalCellHeight = contentHeight + 2 * p.cell.paddingPt.toFloat()
            val perGridRow = totalCellHeight / p.cell.rowSpan.coerceAtLeast(1)
            for (r in p.gridRow until (p.gridRow + p.cell.rowSpan).coerceAtMost(gridRowCount)) {
                if (perGridRow > rowHeights[r]) rowHeights[r] = perGridRow
            }
        }
        return rowHeights
    }

    private fun measureTableHeight(table: Block.Table, maxWidth: Float): Float {
        val colWidths = resolveColumnWidths(table, maxWidth)
        val placed = placeCellsOnGrid(table)
        if (placed.isEmpty()) return 0f
        return computeRowHeights(table, colWidths, placed, table.rows.size).sum()
    }

        private fun drawTable(
        ctx: DrawCtx, table: Block.Table, x: Float, y: Float, maxWidth: Float, spec: PageSpec,
        pageBottomLimit: Float? = null,
        onOverflowNewPage: (() -> Unit)? = null,
        marginTopOfNewPage: Float = y
    ): Float {
        val colWidths = resolveColumnWidths(table, maxWidth)
        val isRtl = table.direction.lowercase() == "rtl"
        val colStartX = FloatArray(colWidths.size)
        var accX = 0f
        for (i in colWidths.indices) { colStartX[i] = accX; accX += colWidths[i] }
        val tableWidth = colWidths.sum()
        fun xForCol(colIdx: Int): Float = if (isRtl) x + (tableWidth - colStartX[colIdx] - colWidths[colIdx]) else x + colStartX[colIdx]

        val placed = placeCellsOnGrid(table)
        if (placed.isEmpty()) return y
        val gridRowCount = table.rows.size
        val rowHeights = computeRowHeights(table, colWidths, placed, gridRowCount)

        // ⚠️ إصلاح حقيقي (تكرار صف الرأس عبر الصفحات): repeatHeaderRow
        // كان يُقرأ من Dart (PdfSpecModels.Block.Table.repeatHeaderRow،
        // يقابل w:tblHeader في DOCX) لكنه لم يُستخدَم إطلاقاً في منطق
        // الرسم هنا — أي جدول يفيض لصفحة تالية كان يستمر في رسم صفوفه
        // التالية مباشرة من أعلى الصفحة الجديدة بلا أي تكرار لصف العناوين،
        // بخلاف سلوك Word (يُكرِّر تلقائياً صف الرأس على كل صفحة يفيض
        // الجدول إليها حين يكون tblHeader مُفعَّلاً). النموذج الحالي
        // يحمل علماً واحداً على مستوى الجدول كله لا قائمة صفوف رأس
        // متعددة، فنُفسِّره (best-effort آمن، يطابق الحالة الأكثر شيوعاً
        // فعلياً في DOCX حقيقي: صف رأس واحد فقط) كصف الشبكة الأول
        // (gridRow=0) فقط — هذا يحتاج خلايا ذلك الصف تحديداً (placed
        // المطابقة لـgridRow==0)، ونحجز ارتفاعها (rowHeights[0]) كمساحة
        // إضافية في أعلى كل صفحة *جديدة* يفيض الجدول إليها قبل حساب موضع
        // الصف الذي تسبَّب في الفيضان نفسه.
        val headerRowCells = if (table.repeatHeaderRow && gridRowCount > 1) {
            placed.filter { it.gridRow == 0 }
        } else {
            emptyList()
        }
        val headerRowHeight = if (headerRowCells.isNotEmpty()) rowHeights.getOrElse(0) { 0f } else 0f

        // 1. حساب الانقسام (Pagination): تحديد في أي صفحة سيقع كل صف
        val rowStartY = FloatArray(gridRowCount)
        val rowPage = IntArray(gridRowCount)
        // موضع Y لكل تكرار لصف الرأس (فهرسه = رقم الصفحة النسبي للجدول،
        // 0 = الصفحة الأولى بلا تكرار أصلاً لأن الرأس الحقيقي موجود فيها
        // ضمن rowStartY[0] نفسها) — يُملأ فقط حين currentPage يزيد فعلياً.
        val headerRepeatY = HashMap<Int, Float>()
        var currentY = y
        var currentPage = 0

        for (i in 0 until gridRowCount) {
            // ننتقل لصفحة جديدة إذا تجاوز الصف الحد السفلي، بشرط ألا يكون هو أول صف في الصفحة
            if (pageBottomLimit != null && onOverflowNewPage != null &&
                currentY + rowHeights[i] > pageBottomLimit && currentY > marginTopOfNewPage) {
                currentPage++
                currentY = marginTopOfNewPage
                // ⚠️ نحجز هنا تحديداً مساحة صف الرأس المُكرَّر (إن كان
                // مُفعَّلاً) في أعلى الصفحة الجديدة، *قبل* تسجيل rowStartY
                // لهذا الصف (i) — هذا يدفع كل محتوى الصفحة فعلياً لأسفل
                // بارتفاع صف الرأس، مطابقاً تماماً لسلوك Word (الرأس
                // المُكرَّر يحجز مساحة فعلية، لا يتراكب فوق أول صف محتوى).
                // لا نُكرِّر الرأس على الصفحة التي يقع فيها i==0 نفسه (لن
                // يحدث عملياً لأن i==0 لا يمكن أن يُسبِّب فيضاناً وهو أول
                // صف في الجدول كله، لكن الشرط headerRowCells.isNotEmpty()
                // كافٍ بمفرده للأمان من أي تكرار ذاتي).
                if (headerRowCells.isNotEmpty()) {
                    headerRepeatY[currentPage] = currentY
                    currentY += headerRowHeight
                }
            }
            rowStartY[i] = currentY
            rowPage[i] = currentPage
            currentY += rowHeights[i]
        }

        // 2. رسم الخلايا صفحة بصفحة
        var lastDrawnPage = 0
        // فرز الخلايا بناءً على الصفحة التي ستبدأ فيها ثم ترتيبها الشبكي
        val sortedCells = placed.sortedWith(compareBy({ rowPage[it.gridRow] }, { it.gridRow }, { it.startCol }))

        // ⚠️ إصلاح حقيقي (حدود الجداول تختفي عند تقاطعها مع خلفيات الخلايا
        // المجاورة): الكود القديم كان يرسم خلفية كل خلية ثم حدودها داخل
        // نفس تكرار الحلقة. حافة مشتركة بين خليتين متجاورتين تُرسَم أولاً
        // (حد الخلية الأولى)، ثم خلفية الخلية الثانية (fillRect) تُرسَم
        // فوقها مباشرة في التكرار التالي فتمحوها بصرياً بالكامل — وهو ما
        // يفسّر اختفاء خطوط الشبكة في أي جدول فيه تظليل خلايا (رؤوس
        // جداول ملوّنة، خلايا مدمجة بخلفية، صفوف مظللة بالتناوب، إلخ).
        // الإصلاح: تقسيم الرسم لمرحلتين منفصلتين عبر كل الخلايا — كل
        // الخلفيات أولاً، ثم كل الحدود فوقها بعد انتهاء كل الخلفيات. هذا
        // يضمن أن خط الحد هو آخر ما يُرسم فيظل ظاهراً دائماً بصرف النظر
        // عن ترتيب الخلايا في القائمة.
        data class CellGeometry(
            val placed: PlacedCell,
            val cellX: Float,
            val cellTop: Float,
            val cellWidth: Float,
            val cellHeight: Float,
            val lastGridRow: Int
        )

        val geometries = sortedCells.map { p ->
            val cell = p.cell
            val cellWidth = (0 until cell.colSpan).sumOf {
                colWidths.getOrElse(p.startCol + it) { 0f }.toDouble()
            }.toFloat()
            val cellTop = rowStartY[p.gridRow]
            val lastGridRow = (p.gridRow + cell.rowSpan - 1).coerceAtMost(gridRowCount - 1)
            val cellHeight = (p.gridRow..lastGridRow).sumOf { rowHeights[it].toDouble() }.toFloat()
            val cellX = if (isRtl) xForCol(p.startCol + cell.colSpan - 1) else xForCol(p.startCol)
            CellGeometry(p, cellX, cellTop, cellWidth, cellHeight, lastGridRow)
        }

        // ⚠️ إصلاح حقيقي (تكرار صف الرأس عبر الصفحات) — تتمة: نبني هنا
        // هندسة كل تكرار لصف الرأس على كل صفحة محجوزة له في headerRepeatY
        // أعلاه. cellGeometryPage تُخزَّن بشكل صريح هنا (بخلاف geometries
        // العادية التي تستخدم rowPage[gridRow] في المرحلة ج لاحقاً) لأن
        // gridRow للرأس المُكرَّر يبقى 0 دوماً (نفس صف الرأس الأصلي
        // المُعاد استخدامه)، فلا يمكن الاعتماد على rowPage[0] (يساوي 0
        // دوماً، صفحة الرأس الأصلية لا صفحة التكرار). نستخدم Map صريحة
        // (cellGeometryPage) تجمع كل الهندسات (الأصلية + المُكرَّرة) معاً
        // لقراءة موحَّدة في المرحلة ج دون تفريع منطق رسم منفصل.
        val cellGeometryPage = java.util.IdentityHashMap<CellGeometry, Int>()
        for (g in geometries) cellGeometryPage[g] = rowPage[g.placed.gridRow]

        val headerRepeatGeometries = ArrayList<CellGeometry>()
        for ((pageIdx, repeatTop) in headerRepeatY) {
            for (p in headerRowCells) {
                val cell = p.cell
                val cellWidth = (0 until cell.colSpan).sumOf {
                    colWidths.getOrElse(p.startCol + it) { 0f }.toDouble()
                }.toFloat()
                val cellHeight = headerRowHeight // صف الرأس لا يحمل rowSpan>1 عملياً (أول صف دوماً)
                val cellX = if (isRtl) xForCol(p.startCol + cell.colSpan - 1) else xForCol(p.startCol)
                val g = CellGeometry(p, cellX, repeatTop, cellWidth, cellHeight, 0)
                headerRepeatGeometries.add(g)
                cellGeometryPage[g] = pageIdx
            }
        }
        // ⚠️ مهم: نُرتِّب القائمة المُجمَّعة حسب رقم الصفحة (cellGeometryPage)
        // قبل أي مرحلة رسم — المرحلة ج أدناه تعتمد على ترتيب تصاعدي صارم
        // لرقم الصفحة عبر القائمة المُكرَّرة بالكامل لتشغيل onOverflowNewPage
        // بالعدد الصحيح من المرات في الموضع الصحيح (lastDrawnPage يتزايد
        // تتابعياً، لا يقبل التراجع). دمج headerRepeatGeometries في نهاية
        // القائمة دون إعادة الترتيب هذه كان سيُدخل خلايا رأس الصفحة 1
        // *بعد* كل محتوى الجدول الحقيقي (الذي قد يمتد للصفحات 1،2،3...)،
        // فيُعيد lastDrawnPage إلى رقم أصغر بعد أن تجاوزه فعلاً — تسلسل
        // مرفوض تماماً من منطق "صفحة جديدة" التتابعي في الدوال المستدعية.
        val allGeometries = (geometries + headerRepeatGeometries)
            .sortedWith(compareBy({ cellGeometryPage[it] ?: 0 }, { it.cellTop }))

        // المرحلة أ: كل خلفيات الخلايا (fillRect) — تُرسَم أولاً ودون أي
        // حد فوقها بعد، حتى لا تطمس حدود خلايا أخرى لاحقاً.
        for (g in allGeometries) {
            g.placed.cell.backgroundColorArgb?.let { bg ->
                ctx.cb.setFillColor(bg)
                ctx.cb.fillRect(g.cellX, ctx.rectY(g.cellTop, g.cellHeight), g.cellWidth, g.cellHeight)
            }
        }

        // المرحلة ب: كل حدود الخلايا — تُرسَم بعد انتهاء كل الخلفيات، فهي
        // آخر ما يُرسم في الجدول ولا يمكن لخلفية لاحقة أن تطمسها.
        fun drawEdge(b: Block.BorderSpec?, x1: Float, y1: Float, x2: Float, y2: Float) {
            if (b == null || b.widthPt <= 0) return
            ctx.cb.setStrokeColor(b.colorArgb)
            ctx.cb.setLineWidth(b.widthPt.toFloat())
            ctx.cb.drawLine(x1, ctx.pointY(y1), x2, ctx.pointY(y2))
        }
        // ⚠️ تكرار صف الرأس: allGeometries (لا geometries فقط) لضمان رسم
        // حدود نسخ الرأس المُكرَّرة أيضاً بنفس منطق حدود الخلية الأصلية
        // (edgeBorders/border/tblBorders الاحتياطي) — انظر تعليق بناء
        // headerRepeatGeometries أعلاه.
        for (g in allGeometries) {
            val p = g.placed
            val cell = p.cell
            val cellX = g.cellX
            val cellTop = g.cellTop
            val cellWidth = g.cellWidth
            val cellHeight = g.cellHeight
            val lastGridRow = g.lastGridRow
            val right = cellX + cellWidth
            val bottom = cellTop + cellHeight

            val edges = cell.edgeBorders
            if (edges != null) {
                drawEdge(edges.top, cellX, cellTop, right, cellTop)
                drawEdge(edges.bottom, cellX, bottom, right, bottom)
                drawEdge(edges.left, cellX, cellTop, cellX, bottom)
                drawEdge(edges.right, right, cellTop, right, bottom)
            } else if (cell.border != null) {
                val border = cell.border
                ctx.cb.setStrokeColor(border.colorArgb)
                ctx.cb.setLineWidth(border.widthPt.toFloat())
                ctx.cb.strokeRect(cellX, ctx.rectY(cellTop, cellHeight), cellWidth, cellHeight)
            } else if (table.defaultBorder != null || table.insideHBorder != null || table.insideVBorder != null) {
                // ⚠️ إصلاح حقيقي (حدود الجداول المفقودة بالكامل): يقابل
                // w:tblBorders على مستوى الجدول كله — الحالة الأكثر
                // شيوعاً في DOCX حقيقي. نسقط احتياطياً إلى حدود الجدول
                // العامة: الأطراف الملاصقة لحافة الجدول الخارجية تستخدم
                // defaultBorder، والأطراف الداخلية تستخدم insideHBorder/
                // insideVBorder إن وُجدا، أو defaultBorder كاحتياط ثانٍ.
                val isFirstRow = p.gridRow == 0
                val isLastRow = lastGridRow == gridRowCount - 1
                val isFirstCol = p.startCol == 0
                val isLastCol = (p.startCol + cell.colSpan - 1) >= colWidths.size - 1

                val topBorder = if (isFirstRow) table.defaultBorder else (table.insideHBorder ?: table.defaultBorder)
                val bottomBorder = if (isLastRow) table.defaultBorder else (table.insideHBorder ?: table.defaultBorder)
                val leftBorder = if (isFirstCol) table.defaultBorder else (table.insideVBorder ?: table.defaultBorder)
                val rightBorder = if (isLastCol) table.defaultBorder else (table.insideVBorder ?: table.defaultBorder)

                drawEdge(topBorder, cellX, cellTop, right, cellTop)
                drawEdge(bottomBorder, cellX, bottom, right, bottom)
                drawEdge(leftBorder, cellX, cellTop, cellX, bottom)
                drawEdge(rightBorder, right, cellTop, right, bottom)
            }
        }

        // المرحلة ج: محتوى كل خلية (نصوص/صور) — تُرسَم أخيراً فوق
        // الخلفيات والحدود معاً، وهو الترتيب البصري الصحيح المتوقع.
        // ⚠️ تكرار صف الرأس: allGeometries (مُرتَّبة تصاعدياً حسب الصفحة،
        // انظر تعليق بنائها أعلاه) بدل geometries فقط، وcellGeometryPage[g]
        // بدل rowPage[p.gridRow] مباشرة — هذا الأخير يبقى صحيحاً لخلايا
        // المحتوى العادي (يساوي rowPage[gridRow] حرفياً، انظر حلقة
        // الإسناد الأولى أعلاه)، لكنه كان سيُرجع دوماً 0 لخلايا الرأس
        // المُكرَّرة (gridRow=0 ثابت لكل تكرار، بصرف النظر عن الصفحة
        // الفعلية التي يُرسَم عليها التكرار) — cellGeometryPage يحمل
        // القيمة الصحيحة الصريحة لكل حالة على حدة.
        for (g in allGeometries) {
            val p = g.placed
            val cell = p.cell
            val cellX = g.cellX
            val cellTop = g.cellTop
            val cellWidth = g.cellWidth
            val cellHeight = g.cellHeight
            val cellPage = cellGeometryPage[g] ?: rowPage[p.gridRow]

            // إذا انتقلنا فعلياً للصفحة التالية في الذاكرة، نستدعي وظيفة فتح صفحة جديدة للمحرك
            while (lastDrawnPage < cellPage) {
                onOverflowNewPage?.invoke()
                lastDrawnPage++
            }

            val innerWidth = (cellWidth - 2 * cell.paddingPt.toFloat()).coerceAtLeast(1f)

            var imageDrawnHeight = 0f
            if (cell.imageAssetRef != null) {
                val bytes = spec.imageAssets[cell.imageAssetRef]
                if (bytes != null) {
                    val rawW = (cell.imageWidthPt ?: innerWidth.toDouble()).toFloat()
                    val rawH = (cell.imageHeightPt ?: (innerWidth * 0.6)).toFloat()
                    val scale = (innerWidth / rawW).coerceAtMost(1f)
                    val drawW = rawW * scale
                    val drawH = rawH * scale
                    val imgX = cellX + cell.paddingPt.toFloat() + (innerWidth - drawW) / 2f
                    ctx.drawBitmapFit(bytes, imgX, cellTop + cell.paddingPt.toFloat(), drawW, drawH)
                    imageDrawnHeight = drawH
                }
            }

            // الحساب الجديد لارتفاع ورسم الكتل (blocks) المتنوعة داخل الخلية
            var totalContentHeight = imageDrawnHeight
            for (block in cell.blocks) {
                totalContentHeight += measureBlockHeight(block, innerWidth)
            }

            val availableHeight = (cellHeight - 2 * cell.paddingPt.toFloat()).coerceAtLeast(0f)
            val startOffset = when (cell.verticalAlign) {
                "center" -> ((availableHeight - totalContentHeight) / 2f).coerceAtLeast(0f)
                "right" -> (availableHeight - totalContentHeight).coerceAtLeast(0f)
                else -> 0f
            }

            var innerY = cellTop + cell.paddingPt.toFloat() + startOffset + imageDrawnHeight
            val innerX = cellX + cell.paddingPt.toFloat()
            
            for (block in cell.blocks) {
                innerY = drawBlock(ctx, block, innerX, innerY, innerWidth, spec)
            }
        }

        // إرجاع نقطة Y الجديدة بعد انتهاء الجدول
        return if (gridRowCount > 0) rowStartY.last() + rowHeights.last() else y
    }


    // ===================== اشكال هندسية (PPTX) =====================

    // ===================== مجموعات (Group) =====================

    private fun drawGroup(ctx: DrawCtx, group: Block.GroupBlock, x: Float, y: Float, spec: PageSpec) {
        val w = group.widthPt.toFloat()
        val h = group.heightPt.toFloat()
        val cb = ctx.cb
        val hasTransform = group.rotationDegrees != 0.0 || group.flipHorizontal || group.flipVertical
        cb.save()
        if (hasTransform) {
            val cx = x + w / 2f
            val cyPdf = ctx.pointY(y + h / 2f)
            val rad = Math.toRadians(-group.rotationDegrees)
            val cos = kotlin.math.cos(rad).toFloat()
            val sin = kotlin.math.sin(rad).toFloat()
            val flipX = if (group.flipHorizontal) -1f else 1f
            val flipY = if (group.flipVertical) -1f else 1f
            cb.transform(cos * flipX, sin * flipX, -sin * flipY, cos * flipY, cx, cyPdf)
            cb.translate(-cx, -cyPdf)
        }

        val paragraphChildren = group.children.filterIsInstance<Block.Paragraph>()
        val otherChildren = group.children.filter { it !is Block.Paragraph }

        for (child in otherChildren) {
            when (child) {
                is Block.ShapeBlock -> drawShape(ctx, child, x, y)
                is Block.ImageBlock -> {
                    val bytes = spec.imageAssets[child.assetRef]
                    if (bytes != null) ctx.drawBitmapFit(bytes, x, y, child.widthPt.toFloat(), child.heightPt.toFloat())
                }
                else -> {}
            }
        }

        if (paragraphChildren.isNotEmpty()) {
            val innerX = x + group.paddingLeftPt.toFloat()
            val innerY = y + group.paddingTopPt.toFloat()
            val innerWidth = (w - group.paddingLeftPt.toFloat() - group.paddingRightPt.toFloat()).coerceAtLeast(1f)
            val innerHeight = (h - group.paddingTopPt.toFloat() - group.paddingBottomPt.toFloat()).coerceAtLeast(0f)

            val measured = paragraphChildren.map { measureParagraph(it, innerWidth) }
            val totalHeight = measured.sumOf { it.height.toDouble() }.toFloat()
            val startOffset = when (group.verticalContentAlign.lowercase()) {
                "center" -> ((innerHeight - totalHeight) / 2f).coerceAtLeast(0f)
                "right" -> (innerHeight - totalHeight).coerceAtLeast(0f)
                else -> 0f
            }
            cb.save()
            cb.clipRect(x, ctx.pointY(y + h), w, h)
            var cy = innerY + startOffset
            for (m in measured) {
                if (cy >= y + h) break
                drawLayoutLines(ctx, m, innerX, cy, 0, m.layout.lineCount)
                cy += m.height
            }
            cb.restore()
        }
        cb.restore()
    }
}
