package com.example.pdf_master.pdfengine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream

/**
 * ═══════════════════════════════════════════════════════════════════════
 *  PdfImageManager
 *  ───────────────────────────────────────────────────────────────────────
 *  يسجّل صور Image XObject في PDF. الفحص الفعلي للملف الناتج (انظر سجل
 *  المحادثة) كشف أن جزءاً من التضخم الكارثي (~19.7MB من الـ ~37MB) كان
 *  بيانات صور خام (raw RGB) بلا أي ضغط — مثلاً صورة 3000×2000 بحجم 17.5
 *  ميجابايت غير مضغوطة. حتى مع حل مشكلة النص (المصدر الأكبر للتضخم)،
 *  يجب أيضاً ضغط الصور نفسها بـ JPEG (DCTDecode) بدل تضمينها كبيانات
 *  بكسل خام عبر RGB/Indexed Color Space بلا فلتر، وإلا تبقى الصور وحدها
 *  مصدر تضخم كبير متبقٍ رغم حل مشكلة النص.
 *
 *  ⚠️ إصلاح حقيقي (شفافية PNG): كان كل مدخل يُحوَّل قسراً إلى JPEG بصرف
 *  النظر عن وجود قناة ألفا، فأي صورة شفافة (مثل PNG بخلفية شفافة) كانت
 *  تظهر بخلفية سوداء صلبة في الـPDF الناتج بدل الشفافية الأصلية — خلل
 *  مؤكَّد بالاختبار الفعلي (DOCX يحوي PNG شفافاً صريحاً لهذا الغرض).
 *  الحل: إن كانت الصورة تحمل ألفا غير ثابت فعلياً (ليس كل بكسل alpha=255،
 *  أي شفافية حقيقية لا قناة ألفا صورية فقط)، نضمّنها كـ /Filter
 *  /FlateDecode RGB (لا JPEG) مع قناة SMask منفصلة (قناع تدرّج رمادي
 *  للشفافية، وفق /SMask القياسي في PDF) بدل تحويلها لـJPEG. الصور بلا
 *  شفافية فعلية تستمر بمسار JPEG المضغوط كما كان (لا تراجع في الحجم).
 *
 *  ⚠️ إصلاح حقيقي إضافي (تقليص دقة الصور لحجم العرض الفعلي): الفحص الفعلي
 *  لمسارات الاستدعاء في NativePdfRenderer.drawBitmapFit أظهر أن bytes
 *  الصورة الخام (بدقتها الأصلية الكاملة كما خرجت من الكاميرا/المصدر،
 *  وقد تبلغ آلاف البكسلات في كل بُعد) كانت تُمرَّر مباشرة لـregisterImage
 *  بصرف النظر تماماً عن حجم العرض الفعلي المطلوب في المستند (widthPt/
 *  heightPt بوحدة نقطة PDF، غالباً يقابل دقة بكسلية أصغر بكثير) — أي
 *  صورة 4000×3000 بكسل تُوضَع بعرض 2 إنش فقط في DOCX (تحتاج فعلياً نحو
 *  300×225 بكسل لجودة طباعة 150 DPI) كانت تُفكَّك وتُعاد ترميزها (JPEG)
 *  بدقتها الكاملة 4000×3000 رغم أن أي قارئ PDF سيُصغِّرها فعلياً للعرض
 *  المطلوب أثناء العرض، فلا فائدة بصرية إطلاقاً من الاحتفاظ بكل تلك
 *  البكسلات الزائدة — فقط تضخيم حجم الملف. الحل: registerImage تقبل
 *  الآن معاملين اختياريين (targetWidthPt/targetHeightPt)، فتُصغِّر
 *  الـBitmap المُفكَّك (عبر Bitmap.createScaledBitmap) لأقرب دقة تخدم
 *  150 DPI فعلياً من حجم العرض المطلوب *قبل* أي ترميز/ضغط — فقط حين
 *  تكون الدقة الأصلية أكبر فعلياً من الدقة المطلوبة (لا تكبير إطلاقاً،
 *  الذي قد يُسبِّب تمويهاً بلا أي فائدة). القيمة الافتراضية null لكليهما
 *  تحافظ على السلوك القديم تماماً (بلا تصغير) لأي استدعاء لا يمرّرهما.
 *  مسار drawBitmapCover (خلفيات الصفحة الكاملة) يُطبِّق تصغيراً مماثلاً
 *  بنفسه خارجياً *قبل* استدعاء registerImage (لأنه يُمرِّر بايتات JPEG
 *  مُرمَّزة مسبقاً لا Bitmap خاماً، فلا يستفيد من downsampleIfNeeded
 *  الداخلية هنا لو مُرِّرت لها فقط الأبعاد المستهدَفة بلا تصغير مسبق)،
 *  فلا يحتاج تمرير targetWidthPt/targetHeightPt صراحة لهذه الدالة.
 * ═══════════════════════════════════════════════════════════════════════
 */
class PdfImageManager(private val writer: PdfWriter) {

    private val registeredObjNums = HashMap<String, Int>()

    /** الدقة المستهدَفة (بكسل/إنش) للصور المُصغَّرة وفق حجم عرضها الفعلي
     *  في المستند — 150 DPI كافٍ بصرياً تماماً (لا فرق يُلاحَظ بالعين
     *  المجردة عن الدقة الأصلية الأعلى) لمعظم الصور المُضمَّنة في مستندات
     *  Office النموذجية (شعارات، صور توضيحية، لقطات شاشة)، وهو ما تستخدمه
     *  Word/PowerPoint نفسها فعلياً افتراضياً عند "ضغط الصور" المدمج فيها
     *  (خيار "Print" في Word يقابل 220ppi، و"Web" يقابل 150ppi — نختار
     *  القيمة الوسطى الأكثر أماناً بصرياً لمستند قد يُطبَع فعلياً). */
    private val targetDpi = 150f
    private val ptPerInch = 72f

    /** يسجّل صورة من بايتات خام (أي صيغة يدعمها BitmapFactory: PNG/JPEG/
     *  WebP/BMP) ويُعيد اسم المصدر المختصر لاستخدامه في /Resources
     *  /XObject ثم drawImageXObject. كل استدعاء يُنشئ كائن XObject جديداً
     *  (لا تخزين مؤقت/cache هنا لأن كل استدعاء غالباً صورة مختلفة فعلياً؛
     *  الطبقة المستدعية في NativePdfRenderer هي المسؤولة عن تفادي معالجة
     *  نفس بايتات الصورة مرتين إن لزم ذلك).
     *
     *  [targetWidthPt]/[targetHeightPt] (نقطة PDF، اختياريان): حجم العرض
     *  الفعلي المطلوب في المستند — إن مُرِّرا كلاهما (غير null)، تُصغَّر
     *  الصورة لأقرب دقة تخدم targetDpi من هذا الحجم *فقط* لو كانت دقتها
     *  الأصلية أعلى فعلياً (لا تكبير أبداً). انظر تعليق الكلاس أعلاه. */
    fun registerImage(
        bytes: ByteArray,
        resourceNamePrefix: String,
        index: Int,
        targetWidthPt: Float? = null,
        targetHeightPt: Float? = null
    ): String {
        val resourceName = "${resourceNamePrefix}$index"
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            ?: throw IllegalArgumentException("تعذّر فك تشفير بيانات الصورة (صيغة غير مدعومة أو بيانات تالفة)")

        val bitmap = downsampleIfNeeded(decoded, targetWidthPt, targetHeightPt)

        try {
            if (bitmap.hasAlpha() && hasRealTransparency(bitmap)) {
                registerObjNumFor(resourceName, buildRgbWithSMask(bitmap))
            } else {
                registerObjNumFor(resourceName, buildJpeg(bitmap))
            }
            return resourceName
        } finally {
            bitmap.recycle()
            if (bitmap !== decoded) decoded.recycle()
        }
    }

    /** يُصغِّر [src] لأقرب دقة تخدم targetDpi من حجم العرض المطلوب (نقطة
     *  PDF) — فقط حين تكون دقة src البكسلية الأصلية أعلى فعلياً من الدقة
     *  المطلوبة في أي من البُعدين (لا تكبير أبداً، لا تشويه نسبة العرض
     *  للارتفاع: تُحسَب نسبة تصغير واحدة من أصغر البُعدين النسبيين وتُطبَّق
     *  على كليهما معاً). يُعيد src نفسه (بلا أي نسخة جديدة) إن لم تُمرَّر
     *  أبعاد مستهدَفة، أو إن كانت الدقة الأصلية أصغر من أو تساوي المطلوبة
     *  فعلياً (تفادي أي تكلفة Bitmap.createScaledBitmap غير ضرورية). */
    private fun downsampleIfNeeded(src: Bitmap, targetWidthPt: Float?, targetHeightPt: Float?): Bitmap {
        if (targetWidthPt == null || targetHeightPt == null || targetWidthPt <= 0f || targetHeightPt <= 0f) return src
        val targetPxW = (targetWidthPt / ptPerInch * targetDpi).toInt().coerceAtLeast(1)
        val targetPxH = (targetHeightPt / ptPerInch * targetDpi).toInt().coerceAtLeast(1)
        if (src.width <= targetPxW && src.height <= targetPxH) return src
        // نسبة تصغير واحدة (لا نسبتان مختلفتان للعرض/الارتفاع) للحفاظ على
        // نسبة العرض للارتفاع الأصلية تماماً — نختار الأكبر نسبياً من
        // (targetPxW/src.width, targetPxH/src.height) كي لا نُصغِّر أكثر
        // من اللازم في أي بُعد (الصورة الناتجة قد تكون أكبر بقليل من
        // الهدف في بُعد واحد فقط، أبداً أصغر منه في أي بُعد).
        val scale = maxOf(targetPxW.toFloat() / src.width, targetPxH.toFloat() / src.height).coerceAtMost(1f)
        if (scale >= 0.999f) return src // لا فائدة عملية من تصغير أقل من 0.1%
        val newW = (src.width * scale).toInt().coerceAtLeast(1)
        val newH = (src.height * scale).toInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(src, newW, newH, true)
    }

    private fun registerObjNumFor(resourceName: String, objNum: Int) {
        registeredObjNums[resourceName] = objNum
    }

    /** فحص فعلي (لا افتراض من hasAlpha وحده، الذي يصح حتى لو كل بكسل
     *  alpha=255 فعلياً): يتحقق من وجود بكسل واحد على الأقل بقناة ألفا
     *  غير كاملة، تفادياً لإنفاق مسار RGB+SMask الأثقل (بلا ضغط DCT) على
     *  صور تحمل قناة ألفا تقنياً لكنها معتمة بالكامل عملياً. */
    private fun hasRealTransparency(bitmap: Bitmap): Boolean {
        val w = bitmap.width
        val h = bitmap.height
        if (w <= 0 || h <= 0) return false
        // نمسح بخطوة لتفادي تكلفة O(w*h) كاملة على صور كبيرة جداً؛ شفافية
        // حقيقية (خلفية شفافة كاملة أو جزئية) تظهر عادة بكثافة كافية
        // ليكتشفها مسح متقطع بأمان دون فحص كل بكسل فعلياً.
        val stepX = (w / 64).coerceAtLeast(1)
        val stepY = (h / 64).coerceAtLeast(1)
        var y = 0
        while (y < h) {
            var x = 0
            while (x < w) {
                val a = (bitmap.getPixel(x, y) ushr 24) and 0xFF
                if (a < 255) return true
                x += stepX
            }
            y += stepY
        }
        return false
    }

    /** يبني كائن XObject لصورة JPEG مضغوطة (DCTDecode) — المسار الأصلي،
     *  بلا أي دعم شفافية (يُستخدَم فقط لصور بلا ألفا حقيقي). */
    private fun buildJpeg(bitmap: Bitmap): Int {
        val jpegBytes = ByteArrayOutputStream().also {
            bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it)
        }.toByteArray()

        val dictExtra = buildString {
            append("/Type /XObject\n/Subtype /Image\n")
            append("/Width ${bitmap.width}\n/Height ${bitmap.height}\n")
            append("/ColorSpace /DeviceRGB\n/BitsPerComponent 8\n")
            append("/Filter /DCTDecode\n")
        }
        // ⚠️ buildStreamObject يضغط بـ Flate افتراضياً، لكن بيانات
        // JPEG مضغوطة مسبقاً (DCT) — ضغطها مجدداً بـ Flate مضيعة
        // حسابية بلا أي فائدة فعلية (بل قد يكبّرها بايتات قليلة).
        // نستخدم compress=false هنا، مع كتابة /Filter /DCTDecode وحده
        // بدل /FlateDecode الذي تضيفه buildStreamObject تلقائياً.
        val streamObj = writer.buildStreamObject(jpegBytes, dictExtra, compress = false)
        return writer.addObject(streamObj)
    }

    /** يبني كائن XObject لصورة RGB خام (مضغوطة Flate لا JPEG، لأن DCT لا
     *  يدعم قناة رابعة) مع كائن /SMask منفصل (قناع ألفا رمادي 8-بت) —
     *  هذا هو الأسلوب القياسي في PDF لدعم شفافية حقيقية. */
    private fun buildRgbWithSMask(bitmap: Bitmap): Int {
        val w = bitmap.width
        val h = bitmap.height
        val rgb = ByteArray(w * h * 3)
        val alpha = ByteArray(w * h)
        val row = IntArray(w)
        var rgbPos = 0
        var aPos = 0
        for (yy in 0 until h) {
            bitmap.getPixels(row, 0, w, 0, yy, w, 1)
            for (xx in 0 until w) {
                val px = row[xx]
                rgb[rgbPos++] = ((px ushr 16) and 0xFF).toByte() // R
                rgb[rgbPos++] = ((px ushr 8) and 0xFF).toByte()  // G
                rgb[rgbPos++] = (px and 0xFF).toByte()           // B
                alpha[aPos++] = ((px ushr 24) and 0xFF).toByte() // A
            }
        }

        val smaskObj = writer.addObject(
            writer.buildStreamObject(
                alpha,
                "/Type /XObject\n/Subtype /Image\n/Width $w\n/Height $h\n" +
                    "/ColorSpace /DeviceGray\n/BitsPerComponent 8\n"
            )
        )

        val dictExtra = buildString {
            append("/Type /XObject\n/Subtype /Image\n")
            append("/Width $w\n/Height $h\n")
            append("/ColorSpace /DeviceRGB\n/BitsPerComponent 8\n")
            append("/SMask ${writer.ref(smaskObj)}\n")
        }
        val streamObj = writer.buildStreamObject(rgb, dictExtra, compress = true)
        return writer.addObject(streamObj)
    }

    /** كل الصور المسجَّلة لصفحة واحدة — تُستخدَم لبناء قاموس /Resources
     *  /XObject الخاص بتلك الصفحة (الصور، خلافاً للخطوط، عادة فريدة لكل
     *  صفحة فلا حاجة لمشاركتها بين الصفحات بنفس آلية الخطوط). */
    fun allRegisteredForCurrentPage(): Map<String, Int> = HashMap(registeredObjNums)

    /** يُستدعى بعد إنهاء كل صفحة لتصفير السجل قبل بدء الصفحة التالية. */
    fun resetForNextPage() = registeredObjNums.clear()
}
