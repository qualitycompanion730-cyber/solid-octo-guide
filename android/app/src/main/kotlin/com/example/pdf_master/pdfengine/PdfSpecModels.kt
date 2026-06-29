package com.example.pdf_master.pdfengine

/**
 * ═══════════════════════════════════════════════════════════════════════
 *  PdfSpecModels.kt
 *  ───────────────────────────────────────────────────────────────────────
 *  المرايا الكوتلينية (Kotlin mirrors) لنموذج التخطيط الموجود في
 *  lib/pdf_engine/pdf_layout_model.dart على الجهة Dart. تُبنى هذه الكلاسات
 *  من Map<String, Any?> القادمة عبر MethodChannel (StandardMethodCodec
 *  يحوّل JSON من Dart تلقائياً إلى HashMap/ArrayList/الأنواع الأساسية).
 * ═══════════════════════════════════════════════════════════════════════
 */

data class FontSpec(
    val family: String,
    val sizePt: Double,
    val bold: Boolean,
    val italic: Boolean,
    val colorArgb: Int,
    val letterSpacing: Float?,
    val underline: Boolean,
    val strikethrough: Boolean,
    val superSub: String, // "none" | "superscript" | "subscript"
    /** ⚠️ إصلاح حقيقي (خلفية تظليل النص الملوّنة غائبة كلياً): يقابل
     *  w:highlight أو w:shd على مستوى w:rPr في DOCX (الهايلايت الأصفر/
     *  الأخضر/السماوي/الوردي... إلخ). كان هذا الحقل غائباً تماماً من
     *  FontSpec من الأساس — لا مجرد خلل تنفيذ بل غياب بنيوي للنموذج، فلا
     *  توجد طريقة حتى لتمرير لون التظليل من Dart. null = بلا تظليل (لا
     *  تغيير سلوك لمستند لا يرسل هذا الحقل). */
    val highlightColorArgb: Int? = null,
    /** ⚠️ إصلاح حقيقي (أنماط التسطير/الشطب المتعددة): underline أعلاه
     *  Boolean بسيط يدعم فقط خطاً واحداً؛ DOCX يدعم single/double/wave/
     *  dotted/dashed... (w:u/@val). هذا الحقل يحدّد الطراز الفعلي حين
     *  underline=true. "single" افتراضياً (يطابق سلوك underline=true
     *  وحده قبل هذا الإصلاح، فلا كسر لأي بيانات قديمة لا ترسل هذا الحقل). */
    val underlineStyle: String = "single", // "single" | "double" | "wave" | "dotted" | "dashed"
    /** نفس فكرة underlineStyle لكن للشطب (w:strike مقابل w:dstrike في
     *  DOCX: شطب مفرد أو مزدوج). */
    val strikethroughDouble: Boolean = false,
    /** ⚠️ إضافة جديدة (ميزة "النص القابل للبحث" لأداة OCR): يقابل عامل
     *  PDF الرسمي `Tr` (Text Rendering Mode) على مستوى كل تشغيلة نصية.
     *  "normal" (القيمة الافتراضية، Tr=0) يحافظ على السلوك الحالي تماماً
     *  لكل المحوّلات الموجودة (DOCX/XLSX/PPTX/HTML/TXT) — لا تغيير سلوك
     *  لأي منها. "invisible" (Tr=3 — "Neither fill nor stroke the
     *  glyphs, but still treat them as a clipping boundary"، وفق
     *  مواصفات PDF القياسية) يجعل النص غير مرئي بصرياً مع بقائه عنصر
     *  نص PDF حقيقي قابلاً للبحث/التحديد/النسخ. هذا يُستخدم في أداة OCR
     *  (text_recognition) لرسم طبقة نص شفافة تماماً فوق صورة الصفحة
     *  الممسوحة بنفس موضع كل كلمة (انظر searchable_pdf_builder_service.dart
     *  من جهة Dart)، فيحصل القارئ على بحث/نسخ حقيقي مع الحفاظ على
     *  المظهر البصري الأصلي 100% للمستند الممسوح. */
    val renderMode: String = "normal" // "normal" | "invisible"
)

/** ⚠️ إصلاح حقيقي جوهري (الروابط التشعبية بلا أي وظيفة فعلية): انظر
 *  التعليق الكامل لـPdfTextRun.linkUri/linkAnchor في pdf_layout_model.dart
 *  (جهة Dart) — كان كل من الحقلين يُستخرَج بدقة من XML ويُمرَّر حتى
 *  toJson() الخاص بـPdfTextRun فعلاً، لكن TextRun هنا (الجسر الأصلي
 *  المُستهلِك لتلك الـJSON) لم يكن يحمل هذين الحقلين إطلاقاً من الأساس
 *  — لا خلل تنفيذ بل غياب بنيوي تام للنموذج على هذا الطرف، فيُفقَد كل
 *  معلومة عن الرابط بصرف النظر عن دقة استخراج Dart. النتيجة المؤكَّدة
 *  فعلياً بفحص الكود قبل هذا الإصلاح: لا يوجد أي بناء لكائنات /Annots
 *  /Link في كل محرك الرسم — كل "رابط" في أي PDF ناتج كان نصاً منسَّقاً
 *  بصرياً فقط (أزرق+تسطير عبر FontSpec العادي) بلا أي وظيفة نقر فعلية،
 *  لا خارجياً (URI) ولا داخلياً (Bookmark). null لكليهما = نص عادي بلا
 *  رابط (لا تغيير سلوك لأي بيانات قديمة لا ترسل هذين الحقلين). */
data class TextRun(
    val text: String,
    val font: FontSpec,
    val linkUri: String? = null,
    val linkAnchor: String? = null
)

sealed class Block {
    data class Paragraph(
        val runs: List<TextRun>,
        val align: String,      // "auto"|"left"|"right"|"center"|"justify"
        val direction: String,  // "auto"|"ltr"|"rtl"
        val spaceBeforePt: Double,
        val spaceAfterPt: Double,
        val lineSpacingMultiplier: Double,
        val indentStartPt: Double,
        val firstLineIndentPt: Double,
        val listLevel: Int?,
        val listOrdered: Boolean,
        val listMarker: String?,
        /** مواضع جدولة بمحاذاة يسار فقط بالنقاط — انظر تعليق tabStopsPt في
         *  pdf_layout_model.dart على الجهة Dart لتفصيل القيد. */
        val tabStopsPt: List<Double> = emptyList(),
        /** ⚠️ إصلاح حقيقي (موضع الهوامش): نصوص هوامش (footnotes) مرتبطة
         *  بهذه الفقرة تحديداً (الفقرة التي تحمل مرجع w:footnoteReference
         *  واحداً أو أكثر). كانت كل الهوامش تُجمَّع سابقاً في قسم منفصل
         *  بنهاية المستند بصرف النظر عن الصفحة الفعلية لمرجعها، بخلاف
         *  سلوك Word (هامش أسفل نفس صفحة مرجعه). بربط نص الهامش بالفقرة
         *  نفسها، يستطيع renderFlowingPage تجميع هوامش كل صفحة فعلياً
         *  (مهما كانت الفقرات التي وقعت فيها بعد القياس الحقيقي) ورسمها
         *  أسفل تلك الصفحة بالذات. */
        val footnotes: List<String> = emptyList(),
        /** ⚠️ إضافة جديدة (أساس مشترك لـ NUMPAGES الصحيح + الروابط الداخلية
         *  + فهرس المحتويات الحقيقي): اسم Bookmark (يقابل w:bookmarkStart
         *  في DOCX) إن كانت هذه الفقرة وجهة رابط داخلي (عادة عنوان قسم).
         *  null لفقرة عادية بلا وجهة. يُجمَع موضع/رقم صفحة كل بوكماركة
         *  أثناء renderDocument عبر تمريرة قياس مسبقة (انظر
         *  resolveBookmarkPages في NativePdfRenderer.kt) — القاموش الناتج
         *  (اسم→رقم صفحة) هو الأساس المشترك الذي يُستخدَم لاحقاً لحل ثلاث
         *  مشاكل منفصلة: استبدال رمز NUMPAGES الفعلي، بناء كائنات /Annots
         *  /Link حقيقية لربط نص بوجهته، وتوليد فهرس محتويات حقيقي (عنوان +
         *  رقم صفحة صحيح) من جهة Dart. */
        val bookmarkName: String? = null
    ) : Block()

         data class TableCellModel(
        val blocks: List<Block>,
        val colSpan: Int,
        val rowSpan: Int,
        val backgroundColorArgb: Int?,
        val paddingPt: Double,
        val verticalAlign: String,
        val border: BorderSpec?,
        val edgeBorders: EdgeBordersSpec? = null,
        val imageAssetRef: String? = null,
        val imageWidthPt: Double? = null,
        val imageHeightPt: Double? = null
    )



    data class BorderSpec(val widthPt: Double, val colorArgb: Int)

    /** حدود مستقلة لكل طرف — انظر PdfCellEdgeBorders في pdf_layout_model.dart. */
    data class EdgeBordersSpec(
        val top: BorderSpec?,
        val bottom: BorderSpec?,
        val left: BorderSpec?,
        val right: BorderSpec?
    )

    data class Table(
        val rows: List<List<TableCellModel>>,
        val columnWidths: List<Double>?,
        val direction: String,
        val repeatHeaderRow: Boolean,
        /** ⚠️ إصلاح حقيقي (حدود الجداول المفقودة بالكامل): يقابل
         *  w:tblBorders على مستوى الجدول كله في DOCX (top/bottom/left/
         *  right/insideH/insideV). قبل هذا الإصلاح، الرسم الفعلي
         *  (drawTable في NativePdfRenderer) لم يكن يعتمد إلا على
         *  TableCellModel.border/edgeBorders على مستوى كل خلية فردياً؛
         *  أي جدول DOCX يُعرِّف حدوده فقط على مستوى الجدول (tblBorders)
         *  دون تكرارها بكل خلية (tcBorders) — وهي الحالة الأكثر شيوعاً
         *  فعلياً في DOCX الحقيقي — كان يُرسَم بلا أي خط حد إطلاقاً،
         *  رغم أن DOCX يطلب حدوداً صريحة. يُستخدَم هذا الحقل كقيمة
         *  احتياطية (fallback) في drawTable حين تكون حدود الخلية نفسها
         *  فارغة (null)، فيُحافَظ على نفس سلوك "حدود الخلية الفردية لها
         *  الأولوية دوماً لو حُدِّدت" دون كسر أي مستند يعتمد عليها. */
        val defaultBorder: BorderSpec? = null,
        /** نفس فكرة defaultBorder لكن مقابل insideH/insideV (الحدود
         *  الداخلية الفاصلة بين الصفوف/الأعمدة) حين تختلف فعلياً عن
         *  الحدود الخارجية في DOCX — حالة شائعة (حد خارجي أثخن من
         *  الحدود الداخلية، أو حد خارجي فقط بلا حدود داخلية إطلاقاً). */
        val insideHBorder: BorderSpec? = null,
        val insideVBorder: BorderSpec? = null
    ) : Block()

    data class ImageBlock(
        val assetRef: String,
        val widthPt: Double,
        val heightPt: Double,
        val align: String
    ) : Block()

    data class Divider(
        val thicknessPt: Double,
        val colorArgb: Int,
        val spaceBeforePt: Double,
        val spaceAfterPt: Double
    ) : Block()

    data class Chart(
        val kind: String, // "bar"|"line"|"pie"
        val title: String,
        val categories: List<String>,
        val series: List<ChartSeriesModel>,
        val widthPt: Double,
        val heightPt: Double
    ) : Block()

    data class ShapeBlock(
        val kind: String, // "rectangle"|"roundedRectangle"|"oval"|"line"|"triangle"|"diamond"|"rightArrow"|"pentagon"|"hexagon"|"star"|"chevron"
        val widthPt: Double,
        val heightPt: Double,
        val fillColorArgb: Int?,
        val lineColorArgb: Int?,
        val lineWidthPt: Double,
        val rotationDegrees: Double,
        val flipHorizontal: Boolean,
        val flipVertical: Boolean,
        val gradientFill: GradientFillSpec? = null,
        val shadow: ShadowSpec? = null
    ) : Block()

    data class GradientFillSpec(
        val positions: List<Float>,
        val colorsArgb: List<Int>,
        val vertical: Boolean
    )

    data class ShadowSpec(
        val blurRadiusPt: Double,
        val offsetXPt: Double,
        val offsetYPt: Double,
        val colorArgb: Int
    )

    data class GroupBlock(
        val children: List<Block>,
        val widthPt: Double,
        val heightPt: Double,
        val rotationDegrees: Double,
        val flipHorizontal: Boolean,
        val flipVertical: Boolean,
        val paddingTopPt: Double,
        val paddingBottomPt: Double,
        val paddingLeftPt: Double,
        val paddingRightPt: Double,
        val verticalContentAlign: String
    ) : Block()

    object PageBreak : Block()
}

data class ChartSeriesModel(
    val name: String,
    val values: List<Double>,
    val colorArgb: Int,
    /** ألوان فردية اختيارية لكل قيمة (مثل شرائح دائرة DOCX، حيث كل قيمة
     *  لها لونها الخاص بدل لون واحد للمتسلسلة كلها). إن وُجدت وكان طولها
     *  مطابقاً لـ values، تُستخدم بالأولوية على colorArgb لكل عنصر. */
    val perValueColors: List<Int>? = null
)

data class PageBorderSpec(val widthPt: Double, val colorArgb: Int, val shadow: Boolean)
data class WatermarkSpec(val text: String, val colorArgb: Int, val rotationDegrees: Double)

data class AbsoluteOverlay(val xPt: Double, val yPt: Double, val block: Block)

data class PageSpec(
    val widthPt: Double,
    val heightPt: Double,
    val marginTopPt: Double,
    val marginBottomPt: Double,
    val marginLeftPt: Double,
    val marginRightPt: Double,
    val backgroundColorArgb: Int?,
    val backgroundImageBytes: ByteArray?,
    val pageBorder: PageBorderSpec?,
    val watermark: WatermarkSpec?,
    val blocks: List<Block>,
    val overlayBlocks: List<AbsoluteOverlay> = emptyList(),
    /** خريطة معرّف الصورة → بايتاتها، تُملأ من _imageAssets في args (انظر
     *  PdfSpecParser) لتُستخدم مباشرة من Block.ImageBlock.assetRef. */
    val imageAssets: Map<String, ByteArray>,
    /** ⚠️ إصلاح حقيقي (الأعمدة المتعددة): عدد أعمدة تخطيط النص لهذا القسم
     *  (DOCX: w:cols num="N"). كان يُحلَّل من جهة Dart لكنه لم يكن يصل
     *  أبداً إلى الجسر الأصلي، فيُرسم القسم بعمود واحد كامل العرض دوماً
     *  حتى مع w:cols num="2" صريحة. 1 = تخطيط عادي (لا تغيير سلوك). */
    val columnCount: Int = 1,
    val columnSpacingPt: Double = 20.0,
    /** ⚠️ إصلاح حقيقي (الهيدر والفوتر غائبان كلياً): قبل هذا الإصلاح لم
     *  يكن أي حقل لهيدر/فوتر موجوداً في PageSpec أصلاً — ليس خللاً في
     *  منطق الرسم بل غياب بنيوي تام للنموذج (لا توجد طريقة حتى لتمرير
     *  محتوى w:header/w:footer من DOCX إلى محرك الرسم Kotlin). يقابل كل
     *  من الحقلين أدناه محتوى هيدر/فوتر القسم الحالي (DOCX يربط كل
     *  Section Break بهيدر/فوتر قد يختلفان عن أقسام أخرى — مثل فوتر
     *  مخصص لقسم Landscape فقط — لذا الحقل هنا على مستوى PageSpec نفسه
     *  لا على مستوى DocSpec، فيُعاد بناؤه بدقة لكل قسم بصرف النظر عن
     *  هيدر/فوتر الأقسام الأخرى). فارغة افتراضياً (emptyList) فلا يتغيّر
     *  سلوك أي مستند لا يرسل هذه الحقول بعد من جهة Dart. */
    val headerBlocks: List<Block> = emptyList(),
    val footerBlocks: List<Block> = emptyList(),
    /** ارتفاع منطقة الهيدر/الفوتر بالنقاط (DOCX: w:headerReference +
     *  sectPr/headerReference يحدّد المسافة عبر pgMar/header وpgMar/footer
     *  لا ارتفاع المحتوى نفسه، فنترك القياس الفعلي يحدّده محتوى الكتل،
     *  لكن نحتاج رقماً معلوماً مسبقاً لحجز المساحة بين حدود الصفحة وبداية
     *  منطقة المحتوى الرئيسية قبل قياس الكتل فعلياً). 0.0 = لا حجز (لا
     *  تغيير سلوك لو لم تُرسَل هذه القيمة من Dart). */
    val headerHeightPt: Double = 0.0,
    val footerHeightPt: Double = 0.0
)

data class DocSpec(
    val pages: List<PageSpec>,
    val isPrecomposed: Boolean
)

/**
 * يحوّل Map الخام القادمة من Dart (عبر MethodChannel.invokeMethod مع
 * Map<String, Object?> args) إلى DocSpec مُهيكَل. كل القراءة دفاعية
 * (Elvis/safe cast) لأن أي حقل قد يكون غائباً من نسخة Dart قديمة أثناء
 * التطوير التدريجي — فشل قراءة حقل واحد لا يجب أن يُسقط كل التحويل.
 */
object PdfSpecParser {

    @Suppress("UNCHECKED_CAST")
    fun parse(args: Map<*, *>): DocSpec {
        val imageAssetsRaw = args["_imageAssets"] as? Map<*, *> ?: emptyMap<Any, Any>()
        val imageAssets: Map<String, ByteArray> = imageAssetsRaw.entries.mapNotNull { (k, v) ->
            val key = k as? String ?: return@mapNotNull null
            val bytes = v as? ByteArray ?: return@mapNotNull null
            key to bytes
        }.toMap()

        val isPrecomposed = args["isPrecomposed"] as? Boolean ?: false
        val pagesRaw = args["pages"] as? List<*> ?: emptyList<Any>()
        val pages = pagesRaw.mapNotNull { it as? Map<*, *> }.map { parsePage(it, imageAssets) }

        return DocSpec(pages = pages, isPrecomposed = isPrecomposed)
    }

    private fun parsePage(map: Map<*, *>, imageAssets: Map<String, ByteArray>): PageSpec {
        val blocksRaw = map["blocks"] as? List<*> ?: emptyList<Any>()
        val blocks = blocksRaw.mapNotNull { it as? Map<*, *> }.mapNotNull { parseBlock(it) }
        val borderMap = map["pageBorder"] as? Map<*, *>
        val watermarkMap = map["watermark"] as? Map<*, *>
        val overlaysRaw = map["overlays"] as? List<*> ?: emptyList<Any>()
        val overlays = overlaysRaw.mapNotNull { it as? Map<*, *> }.mapNotNull { o ->
            val blockMap = o["block"] as? Map<*, *> ?: return@mapNotNull null
            val block = parseBlock(blockMap) ?: return@mapNotNull null
            AbsoluteOverlay(
                xPt = (o["x"] as? Number)?.toDouble() ?: 0.0,
                yPt = (o["y"] as? Number)?.toDouble() ?: 0.0,
                block = block
            )
        }
        // ⚠️ إصلاح حقيقي (خلفية الصفحة بصورة كانت معطّلة كلياً): الحقل
        // backgroundImageBytes في PageSpec كان يُضبط دوماً على null هنا
        // بصرف النظر عن أي بيانات تُرسلها Dart — رغم أن renderPrecomposedPage
        // في NativePdfRenderer.kt يستدعي بالفعل ctx.drawBitmapCover() عند
        // توفّر هذا الحقل (الرسم جاهز، فقط القراءة من القناة كانت مفقودة).
        // يُستخدم هذا تحديداً في أداة استخراج النص (OCR): كل صفحة "PDF
        // قابل للبحث" هي في جوهرها صورة المستند الممسوح الأصلية كخلفية +
        // طبقة نص شفافة فوقها (انظر renderMode="invisible" في FontSpec).
        // يُقرأ بنفس آلية assetRef المستخدمة في Block.ImageBlock (مفتاح
        // "backgroundImageAssetRef" يُضبط من جهة Dart في
        // searchable_pdf_builder_service.dart، والبايتات الفعلية تصل ضمن
        // نفس خريطة imageAssets المُرسلة مع كل صور المستند).
        val backgroundImageAssetRef = map["backgroundImageAssetRef"] as? String
        val backgroundImageBytes = backgroundImageAssetRef?.let { imageAssets[it] }
        return PageSpec(
            widthPt = (map["width"] as? Number)?.toDouble() ?: 595.28,
            heightPt = (map["height"] as? Number)?.toDouble() ?: 841.89,
            marginTopPt = (map["marginTop"] as? Number)?.toDouble() ?: 0.0,
            marginBottomPt = (map["marginBottom"] as? Number)?.toDouble() ?: 0.0,
            marginLeftPt = (map["marginLeft"] as? Number)?.toDouble() ?: 0.0,
            marginRightPt = (map["marginRight"] as? Number)?.toDouble() ?: 0.0,
            backgroundColorArgb = (map["bgColor"] as? Number)?.toInt(),
            backgroundImageBytes = backgroundImageBytes,
            pageBorder = borderMap?.let {
                PageBorderSpec(
                    widthPt = (it["width"] as? Number)?.toDouble() ?: 1.0,
                    colorArgb = (it["color"] as? Number)?.toInt() ?: 0xFF000000.toInt(),
                    shadow = it["shadow"] as? Boolean ?: false
                )
            },
            watermark = watermarkMap?.let {
                WatermarkSpec(
                    text = it["text"] as? String ?: "",
                    colorArgb = (it["color"] as? Number)?.toInt() ?: 0x80C0C0C0.toInt(),
                    rotationDegrees = (it["rotation"] as? Number)?.toDouble() ?: -45.0
                )
            },
            blocks = blocks,
            overlayBlocks = overlays,
            imageAssets = imageAssets,
            columnCount = (map["columnCount"] as? Number)?.toInt()?.coerceAtLeast(1) ?: 1,
            columnSpacingPt = (map["columnSpacing"] as? Number)?.toDouble() ?: 20.0,
            // ⚠️ إصلاح حقيقي (الهيدر والفوتر غائبان كلياً) — انظر تعليق
            // PageSpec.headerBlocks أعلاه. القراءة دفاعية بالكامل (Elvis
            // إلى emptyList/0.0) فلا ينكسر أي مستند قديم لا يرسل هذه
            // المفاتيح بعد من جهة Dart.
            headerBlocks = (map["header"] as? List<*>)
                ?.mapNotNull { it as? Map<*, *> }?.mapNotNull { parseBlock(it) } ?: emptyList(),
            footerBlocks = (map["footer"] as? List<*>)
                ?.mapNotNull { it as? Map<*, *> }?.mapNotNull { parseBlock(it) } ?: emptyList(),
            headerHeightPt = (map["headerHeight"] as? Number)?.toDouble() ?: 0.0,
            footerHeightPt = (map["footerHeight"] as? Number)?.toDouble() ?: 0.0
        )
    }

    private fun parseFont(map: Map<*, *>?): FontSpec {
        if (map == null) {
            return FontSpec("Cairo", 12.0, false, false, 0xFF000000.toInt(), null, false, false, "none", renderMode = "normal")
        }
        return FontSpec(
            family = map["family"] as? String ?: "Cairo",
            sizePt = (map["size"] as? Number)?.toDouble() ?: 12.0,
            bold = map["bold"] as? Boolean ?: false,
            italic = map["italic"] as? Boolean ?: false,
            colorArgb = (map["color"] as? Number)?.toInt() ?: 0xFF000000.toInt(),
            letterSpacing = (map["letterSpacing"] as? Number)?.toFloat(),
            underline = map["underline"] as? Boolean ?: false,
            strikethrough = map["strike"] as? Boolean ?: false,
            superSub = map["superSub"] as? String ?: "none",
            // ⚠️ إصلاح حقيقي (خلفية تظليل النص + أنماط تسطير/شطب متعددة)
            // — انظر تعليق هذه الحقول في FontSpec أعلاه لتفصيل المشكلة.
            highlightColorArgb = (map["highlightColor"] as? Number)?.toInt(),
            underlineStyle = map["underlineStyle"] as? String ?: "single",
            strikethroughDouble = map["strikeDouble"] as? Boolean ?: false,
            // ⚠️ إضافة جديدة (النص الشفاف القابل للبحث لأداة OCR) — انظر
            // تعليق FontSpec.renderMode أعلاه لتفصيل الغرض الكامل.
            renderMode = map["renderMode"] as? String ?: "normal"
        )
    }

    private fun parseParagraph(map: Map<*, *>): Block.Paragraph {
        val runsRaw = map["runs"] as? List<*> ?: emptyList<Any>()
        val runs = runsRaw.mapNotNull { it as? Map<*, *> }.map { r ->
            TextRun(
                text = r["text"] as? String ?: "",
                font = parseFont(r["font"] as? Map<*, *>),
                // ⚠️ إضافة جديدة: انظر تعليق TextRun.linkUri/linkAnchor أعلاه.
                linkUri = r["linkUri"] as? String,
                linkAnchor = r["linkAnchor"] as? String
            )
        }
        val tabStopsRaw = map["tabStops"] as? List<*>
        val footnotesRaw = map["footnotes"] as? List<*>
        return Block.Paragraph(
            runs = runs,
            align = map["align"] as? String ?: "auto",
            direction = map["direction"] as? String ?: "auto",
            spaceBeforePt = (map["spaceBefore"] as? Number)?.toDouble() ?: 0.0,
            spaceAfterPt = (map["spaceAfter"] as? Number)?.toDouble() ?: 0.0,
            lineSpacingMultiplier = (map["lineSpacing"] as? Number)?.toDouble() ?: 1.0,
            indentStartPt = (map["indentStart"] as? Number)?.toDouble() ?: 0.0,
            firstLineIndentPt = (map["firstLineIndent"] as? Number)?.toDouble() ?: 0.0,
            listLevel = (map["listLevel"] as? Number)?.toInt(),
            listOrdered = map["listOrdered"] as? Boolean ?: false,
            listMarker = map["listMarker"] as? String,
            tabStopsPt = tabStopsRaw?.mapNotNull { (it as? Number)?.toDouble() } ?: emptyList(),
            footnotes = footnotesRaw?.mapNotNull { it as? String } ?: emptyList(),
            // ⚠️ إضافة جديدة: انظر تعليق Block.Paragraph.bookmarkName أعلاه.
            bookmarkName = map["bookmarkName"] as? String
        )
    }

    private fun parseBorderSpec(map: Map<*, *>?): Block.BorderSpec? {
        if (map == null) return null
        return Block.BorderSpec(
            widthPt = (map["width"] as? Number)?.toDouble() ?: 1.0,
            colorArgb = (map["color"] as? Number)?.toInt() ?: 0xFF888888.toInt()
        )
    }

        private fun parseCell(map: Map<*, *>): Block.TableCellModel {
        val blocksRaw = map["blocks"] as? List<*> ?: emptyList<Any>()
        val blocks = blocksRaw.mapNotNull { it as? Map<*, *> }.mapNotNull { parseBlock(it) }
        
        val borderMap = map["border"] as? Map<*, *>
        val edgeBordersMap = map["edgeBorders"] as? Map<*, *>
        return Block.TableCellModel(
            blocks = blocks,
            colSpan = (map["colSpan"] as? Number)?.toInt() ?: 1,
            rowSpan = (map["rowSpan"] as? Number)?.toInt() ?: 1,
            backgroundColorArgb = (map["bgColor"] as? Number)?.toInt(),
            paddingPt = (map["padding"] as? Number)?.toDouble() ?: 4.0,
            verticalAlign = map["vAlign"] as? String ?: "center",
            border = parseBorderSpec(borderMap),
            edgeBorders = edgeBordersMap?.let {
                Block.EdgeBordersSpec(
                    top = parseBorderSpec(it["top"] as? Map<*, *>),
                    bottom = parseBorderSpec(it["bottom"] as? Map<*, *>),
                    left = parseBorderSpec(it["left"] as? Map<*, *>),
                    right = parseBorderSpec(it["right"] as? Map<*, *>),
                )
            },
            imageAssetRef = map["imageAssetRef"] as? String,
            imageWidthPt = (map["imageWidth"] as? Number)?.toDouble(),
            imageHeightPt = (map["imageHeight"] as? Number)?.toDouble()
        )
    }


    private fun parseTable(map: Map<*, *>): Block.Table {
        val rowsRaw = map["rows"] as? List<*> ?: emptyList<Any>()
        val rows = rowsRaw.mapNotNull { it as? List<*> }.map { row ->
            row.mapNotNull { it as? Map<*, *> }.map { parseCell(it) }
        }
        val colWidthsRaw = map["columnWidths"] as? List<*>
        val colWidths = colWidthsRaw?.mapNotNull { (it as? Number)?.toDouble() }
        // ⚠️ إصلاح حقيقي (حدود الجداول): يقرأ tblBorders على مستوى الجدول
        // — انظر تعليق Block.Table.defaultBorder أعلاه لتفصيل المشكلة.
        // "defaultBorder" يقابل الحد الموحَّد الأبسط (لو أرسلته Dart بهذا
        // الاسم)، و"border" نفس مفتاح حدود الخلية لتوافق تسمية مرن في حال
        // أرسلت الجهة الأخرى نفس بنية BorderSpec على مستوى الجدول أيضاً.
        val defaultBorderMap = (map["defaultBorder"] ?: map["border"]) as? Map<*, *>
        val insideHMap = (map["insideHBorder"] ?: map["insideH"]) as? Map<*, *>
        val insideVMap = (map["insideVBorder"] ?: map["insideV"]) as? Map<*, *>
        return Block.Table(
            rows = rows,
            columnWidths = colWidths,
            direction = map["direction"] as? String ?: "auto",
            repeatHeaderRow = map["repeatHeader"] as? Boolean ?: false,
            defaultBorder = parseBorderSpec(defaultBorderMap),
            insideHBorder = parseBorderSpec(insideHMap),
            insideVBorder = parseBorderSpec(insideVMap)
        )
    }

    private fun parseChart(map: Map<*, *>): Block.Chart {
        val seriesRaw = map["series"] as? List<*> ?: emptyList<Any>()
        val series = seriesRaw.mapNotNull { it as? Map<*, *> }.map { s ->
            val perValueColorsRaw = s["perValueColors"] as? List<*>
            ChartSeriesModel(
                name = s["name"] as? String ?: "",
                values = (s["values"] as? List<*>)?.mapNotNull { (it as? Number)?.toDouble() } ?: emptyList(),
                colorArgb = (s["color"] as? Number)?.toInt() ?: 0xFF4285F4.toInt(),
                perValueColors = perValueColorsRaw?.mapNotNull { (it as? Number)?.toInt() }
            )
        }
        return Block.Chart(
            kind = map["kind"] as? String ?: "bar",
            title = map["title"] as? String ?: "",
            categories = (map["categories"] as? List<*>)?.mapNotNull { it as? String } ?: emptyList(),
            series = series,
            widthPt = (map["width"] as? Number)?.toDouble() ?: 300.0,
            heightPt = (map["height"] as? Number)?.toDouble() ?: 200.0
        )
    }

    private fun parseBlock(map: Map<*, *>): Block? {
        return when (map["type"] as? String) {
            "paragraph" -> parseParagraph(map)
            "table" -> parseTable(map)
            "image" -> Block.ImageBlock(
                assetRef = map["assetRef"] as? String ?: "",
                widthPt = (map["width"] as? Number)?.toDouble() ?: 100.0,
                heightPt = (map["height"] as? Number)?.toDouble() ?: 100.0,
                align = map["align"] as? String ?: "center"
            )
            "divider" -> Block.Divider(
                thicknessPt = (map["thickness"] as? Number)?.toDouble() ?: 1.0,
                colorArgb = (map["color"] as? Number)?.toInt() ?: 0xFF888888.toInt(),
                spaceBeforePt = (map["spaceBefore"] as? Number)?.toDouble() ?: 0.0,
                spaceAfterPt = (map["spaceAfter"] as? Number)?.toDouble() ?: 0.0
            )
            "chart" -> parseChart(map)
            "shape" -> {
                val gradientMap = map["gradient"] as? Map<*, *>
                val shadowMap = map["shadow"] as? Map<*, *>
                Block.ShapeBlock(
                    kind = map["kind"] as? String ?: "rectangle",
                    widthPt = (map["width"] as? Number)?.toDouble() ?: 10.0,
                    heightPt = (map["height"] as? Number)?.toDouble() ?: 10.0,
                    fillColorArgb = (map["fillColor"] as? Number)?.toInt(),
                    lineColorArgb = (map["lineColor"] as? Number)?.toInt(),
                    lineWidthPt = (map["lineWidth"] as? Number)?.toDouble() ?: 0.0,
                    rotationDegrees = (map["rotation"] as? Number)?.toDouble() ?: 0.0,
                    flipHorizontal = map["flipH"] as? Boolean ?: false,
                    flipVertical = map["flipV"] as? Boolean ?: false,
                    gradientFill = gradientMap?.let {
                        val positions = (it["positions"] as? List<*>)?.mapNotNull { p -> (p as? Number)?.toFloat() } ?: emptyList()
                        val colors = (it["colors"] as? List<*>)?.mapNotNull { c -> (c as? Number)?.toInt() } ?: emptyList()
                        if (positions.isEmpty() || positions.size != colors.size) {
                            null
                        } else {
                            Block.GradientFillSpec(
                                positions = positions,
                                colorsArgb = colors,
                                vertical = it["vertical"] as? Boolean ?: true
                            )
                        }
                    },
                    shadow = shadowMap?.let {
                        Block.ShadowSpec(
                            blurRadiusPt = (it["blur"] as? Number)?.toDouble() ?: 4.0,
                            offsetXPt = (it["dx"] as? Number)?.toDouble() ?: 0.0,
                            offsetYPt = (it["dy"] as? Number)?.toDouble() ?: 0.0,
                            colorArgb = (it["color"] as? Number)?.toInt() ?: 0x59000000
                        )
                    }
                )
            }
            "group" -> {
                val childrenRaw = map["children"] as? List<*> ?: emptyList<Any>()
                val children = childrenRaw.mapNotNull { it as? Map<*, *> }.mapNotNull { parseBlock(it) }
                Block.GroupBlock(
                    children = children,
                    widthPt = (map["width"] as? Number)?.toDouble() ?: 10.0,
                    heightPt = (map["height"] as? Number)?.toDouble() ?: 10.0,
                    rotationDegrees = (map["rotation"] as? Number)?.toDouble() ?: 0.0,
                    flipHorizontal = map["flipH"] as? Boolean ?: false,
                    flipVertical = map["flipV"] as? Boolean ?: false,
                    paddingTopPt = (map["padTop"] as? Number)?.toDouble() ?: 0.0,
                    paddingBottomPt = (map["padBottom"] as? Number)?.toDouble() ?: 0.0,
                    paddingLeftPt = (map["padLeft"] as? Number)?.toDouble() ?: 0.0,
                    paddingRightPt = (map["padRight"] as? Number)?.toDouble() ?: 0.0,
                    verticalContentAlign = map["vAlign"] as? String ?: "left"
                )
            }
            "pageBreak" -> Block.PageBreak
            else -> null // نوع غير معروف — يُتجاهَل بأمان بدل إسقاط كل المستند
        }
    }
}
