package com.example.pdf_master.pdfengine

import android.text.Spannable
import android.text.TextPaint
import android.graphics.Typeface

// ═══════════════════════════════════════════════════════════════════════
//  TextRunSupport.kt
//  ─────────────────────────────────────────────────────────────────────
//  مُستخرَج من NativePdfRenderer.kt كجزء من إعادة هيكلة الملف الضخم إلى
//  ملفات بمسؤولية واحدة. يحوي دعم تشكيل/ترتيب النص ثنائي الاتجاه (BiDi)
//  ووسوم Span المخصصة للخطوط والتباعد بين الحروف. كانت هذه العناصر
//  top-level بالفعل في الملف الأصلي (private، مقيَّدة لذلك الملف وحده) —
//  رُفِع معدِّل الوصول هنا لأنها تُستخدَم الآن من ثلاثة ملفات معاً:
//  NativePdfRenderer.kt (الفقرات، العلامة المائية، علامات القوائم)،
//  ChartRenderer.kt (عناوين/تسميات الرسوم البيانية)، وهذا الملف نفسه.
// ═══════════════════════════════════════════════════════════════════════

class CustomTypefaceSpan(private val typeface: Typeface) :
    android.text.style.MetricAffectingSpan() {
    override fun updateDrawState(paint: TextPaint) = apply(paint)
    override fun updateMeasureState(paint: TextPaint) = apply(paint)
    private fun apply(paint: TextPaint) { paint.typeface = typeface }
}

class LetterSpacingSpan(private val spacingEm: Float) :
    android.text.style.MetricAffectingSpan() {
    override fun updateDrawState(paint: TextPaint) { paint.letterSpacing = spacingEm }
    override fun updateMeasureState(paint: TextPaint) { paint.letterSpacing = spacingEm }
}

// ═══════════════════════════════════════════════════════════════════════
//  مساعدات Bidi على مستوى الملف (top-level)
//  ───────────────────────────────────────────────────────────────────────
//  top-level وليست private methods داخل NativePdfRenderer لأن المُستدعي
//  الثاني (drawWatermark) مُعرَّف داخل DrawCtx، وهي class منفصلة كلياً
//  عن NativePdfRenderer (لا closure ضمنية تصلها لـ private methods في
//  class آخر) — انظر تعريف `private class DrawCtx` أعلاه في الملف.
//
//  ⚠️ ملاحظة تصحيح مهمة: المحاولة الأولى استخدمت android.icu.text.Bidi
//  بافتراض توقيع مطابق لـ ICU4J الكامل (getBaseDirection بقيمة Int،
//  DIRECTION_RIGHT_TO_LEFT كحقل على مستوى الكلاس، constructor(String,
//  Int)) — وهذا خاطئ بالفحص الفعلي عبر فشل gradle build: الكلاس المتاح
//  هنا فعلياً هو java.text.Bidi القياسي (JDK، متوفر من Android API 1)،
//  وتوقيعه يختلف تحديداً في:
//   • constructor(String, Int) موجود لكن قيم flags هي Bidi.DIRECTION_*
//     (وليس Bidi.RTL/Bidi.LTR كما كتبتُ خطأً أول مرة).
//   • getRunLevel(i) تُرجع Byte لا Int — المقارنة % 2 == 1 تحتاج تحويل
//     صريح .toInt() أولاً.
//   • getBaseDirection() ثابتة (static) على الكلاس وتُرجع Int يطابق
//     Bidi.LTR (0) أو Bidi.RTL (1) مباشرة — لا DIRECTION_RIGHT_TO_LEFT
//     (تلك قيم flags لمُنشئ الكلاس فقط، ثابتان مختلفان تماماً).
// ═══════════════════════════════════════════════════════════════════════

data class BidiRun(val start: Int, val end: Int, val isRtl: Boolean)

/**
 * يقسّم [lineStart, lineEnd) ضمن [text] إلى bidi runs متجانسة الاتجاه
 * عبر java.text.Bidi القياسي. انظر الشرح الكامل لسبب الإصلاح في تعليق
 * drawLayoutLines داخل NativePdfRenderer.
 */
fun bidiRunsForLine(
    text: CharSequence, lineStart: Int, lineEnd: Int, lineIsRtl: Boolean
): List<BidiRun> {
    val lineText = text.subSequence(lineStart, lineEnd).toString()
    if (lineText.isEmpty()) return emptyList()

    val flags = if (lineIsRtl)
        java.text.Bidi.DIRECTION_RIGHT_TO_LEFT else java.text.Bidi.DIRECTION_LEFT_TO_RIGHT
    val bidi = java.text.Bidi(lineText, flags)

    // نص بلا أي تعدد اتجاه فعلي (سطر عربي خالص أو إنجليزي خالص):
    // run واحد بكامل نطاق السطر، نتجنب تكلفة/تعقيد تقسيم لا لزوم له.
    if (bidi.runCount <= 1) {
        return listOf(BidiRun(lineStart, lineEnd, lineIsRtl))
    }

    val runs = ArrayList<BidiRun>(bidi.runCount)
    for (i in 0 until bidi.runCount) {
        val runStart = lineStart + bidi.getRunStart(i)
        val runEnd = lineStart + bidi.getRunLimit(i)
        if (runEnd <= runStart) continue
        val runIsRtl = bidi.getRunLevel(i).toInt() % 2 == 1 // مستوى فردي = RTL وفق UAX #9
        runs.add(BidiRun(runStart, runEnd, runIsRtl))
    }

    // ترتيب الـ runs نفسها بصرياً (UAX #9 L2): في سطر RTL، أول run يُرسم
    // بصرياً هو آخر run منطقياً (الأقرب لأقصى اليمين). java.text.Bidi
    // يُرجع الـ runs بترتيب منطقي (logical) دوماً، فنعكس نحن قائمة الـ
    // runs (لا محتوى أي run بداخلها) عند سطر RTL لنحصل على ترتيب الرسم
    // البصري الصحيح من اليسار إلى اليمين على الصفحة.
    return if (lineIsRtl) runs.asReversed() else runs
}

/**
 * نسخة عامة من bidiRunsForLine، لاستخدامها على نصوص سطر واحد لا تمر
 * عبر StaticLayout (علامة مائية، عنوان مخطط) — حيث لا يوجد
 * getParagraphDirection جاهز، فنستنتج اتجاه الفقرة بأول حرف قوي فيها.
 *
 * ⚠️ تصحيح ثانٍ مؤكَّد بفشل بناء فعلي: java.text.Bidi.getBaseDirection
 * (static) غير متوفرة على Android Runtime (ART) — أُضيفت فقط في JDK 9+
 * القياسي، وART لا يعرض كل إضافات JDK اللاحقة على java.text.Bidi رغم
 * توفر الكلاس الأساسي نفسه (المُنشئ وgetRunCount/Start/Limit/Level،
 * المُستخدَمة في bidiRunsForLine أعلاه، أثبت فشل البناء توفرها فعلاً).
 * البديل المضمون: نبني Bidi بعلم DIRECTION_DEFAULT_LEFT_TO_RIGHT (يجعل
 * المكتبة تحسب الاتجاه العام تلقائياً من أول حرف قوي في النص وفق
 * Unicode UAX #9 القاعدتين P2/P3 — هذا هو نفس التعريف الذي تنفّذه
 * getBaseDirection داخلياً، فقط عبر مسار API مختلف)، ثم نستعلم
 * baseIsLeftToRight() — method instance عادية موجودة في java.text.Bidi
 * منذ JDK 1.4 الأصلي، فهي مضمونة على ART.
 */
fun drawTextLineBidiAware(
    cb: PdfContentBuilder, text: CharSequence, baselineX: Float, baselineY: Float, paint: TextPaint
) {
    if (text.isEmpty()) return
    val baseBidi = java.text.Bidi(text.toString(), java.text.Bidi.DIRECTION_DEFAULT_LEFT_TO_RIGHT)
    val firstStrongIsRtl = !baseBidi.baseIsLeftToRight()
    val runs = bidiRunsForLine(text, 0, text.length, firstStrongIsRtl)
    // ⚠️ نفس إصلاح التراكب الموجود في drawLayoutLines أعلاه: نُراكم عرض
    // كل run المُرسَل فعلياً (قيمة الإرجاع من drawTextLine) في cursorX
    // بدل تمرير baselineX الثابت لكل runs — وإلا يُرسم كل run (مثلاً
    // عنوان مخطط أو علامة مائية مختلطة عربي/إنجليزي) فوق الذي قبله.
    var cursorX = baselineX
    for (run in runs) {
        val advance = cb.drawTextLine(text, run.start, run.end, cursorX, baselineY, run.isRtl, paint)
        cursorX += advance
    }
}
//