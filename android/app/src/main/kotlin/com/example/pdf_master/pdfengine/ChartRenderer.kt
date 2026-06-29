package com.example.pdf_master.pdfengine

import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.text.TextPaint
import kotlin.math.min

// ═══════════════════════════════════════════════════════════════════════
//  ChartRenderer.kt
//  ─────────────────────────────────────────────────────────────────────
//  مُستخرَج من NativePdfRenderer.kt كجزء من إعادة هيكلة الملف الضخم (كان
//  2321 سطراً) إلى ملفات بمسؤولية واحدة. يحوي كل منطق رسم الرسوم البيانية
//  (Bar/Line/Pie) كدوال top-level تستقبل DrawCtx كمعامل أول — بنفس توقيع
//  الاستدعاء الأصلي تماماً (drawChart(ctx, ...)) فلم تتغيّر نقطة الاستدعاء
//  الوحيدة في drawBlock داخل NativePdfRenderer.kt. تم التأكد عبر فحص دقيق
//  أن هذه المجموعة لا تستدعي أي عضو آخر من NativePdfRenderer (فقط ctx.*،
//  cb.*، ودوال أندرويد الأساسية)، فهي معزولة تماماً وآمنة للنقل.
// ═══════════════════════════════════════════════════════════════════════

    fun drawChart(ctx: DrawCtx, chart: Block.Chart, x: Float, y: Float, w: Float) {
        val h = chart.heightPt.toFloat()
        var topOffset = 0f

        // 1. رسم العنوان (Title) متمركزاً
        if (chart.title.isNotEmpty()) {
            val titlePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 12f; color = Color.BLACK; typeface = Typeface.DEFAULT_BOLD }
            val titleX = x + (w / 2f) - (titlePaint.measureText(chart.title) / 2f)
            drawTextLineBidiAware(ctx.cb, chart.title, titleX, ctx.pointY(y + 12f), titlePaint)
            topOffset = 22f
        }

        // 2. رسم مفتاح الخريطة (Legend) أسفل العنوان
        var legendHeight = 0f
        if (chart.series.isNotEmpty() && chart.kind != "pie") {
            val legendPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 8f; color = Color.DKGRAY; typeface = Typeface.DEFAULT }
            var lx = x + 10f
            val ly = y + topOffset + 5f
            for (series in chart.series) {
                if (series.name.isEmpty()) continue
                ctx.cb.setFillColor(series.colorArgb)
                ctx.cb.fillRect(lx, ctx.pointY(ly), 7f, 7f)
                drawTextLineBidiAware(ctx.cb, series.name, lx + 10f, ctx.pointY(ly + 6f), legendPaint)
                lx += 10f + legendPaint.measureText(series.name) + 15f
            }
            legendHeight = 18f
        }

        val plotLeft = x + 40f // مساحة لأرقام المحور الصادي
        val plotTop = y + topOffset + legendHeight
        val plotRight = x + w - 15f
        val plotBottom = y + h - 20f

        // 3. رسم المخطط الفعلي
        when (chart.kind) {
            "pie" -> drawPieChart(ctx, chart, plotLeft, plotTop, plotRight, plotBottom)
            "line" -> drawLineChart(ctx, chart, plotLeft, plotTop, plotRight, plotBottom, filled = false)
            "area" -> drawLineChart(ctx, chart, plotLeft, plotTop, plotRight, plotBottom, filled = true)
            else -> drawBarChart(ctx, chart, plotLeft, plotTop, plotRight, plotBottom)
        }
    }

    fun drawGridAndAxes(ctx: DrawCtx, left: Float, top: Float, right: Float, bottom: Float, maxVal: Double) {
        val cb = ctx.cb
        // رسم خطوط الشبكة الأفقية وقيم المحور الصادي (Y-Axis)
        val steps = 4
        val labelPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 7f; color = Color.GRAY; typeface = Typeface.DEFAULT }
        for (i in 0..steps) {
            val py = bottom - (i.toFloat() / steps) * (bottom - top)
            val v = (maxVal * i / steps).toInt().toString()
            cb.setStrokeColor(Color.LTGRAY)
            cb.setLineWidth(0.5f)
            cb.drawLine(left, ctx.pointY(py), right, ctx.pointY(py)) // Grid line
            drawTextLineBidiAware(cb, v, left - labelPaint.measureText(v) - 4f, ctx.pointY(py + 3f), labelPaint)
        }
        
        // رسم المحاور الأساسية
        cb.setStrokeColor(Color.DKGRAY); cb.setLineWidth(1.2f)
        cb.drawLine(left, ctx.pointY(top), left, ctx.pointY(bottom))
        cb.drawLine(left, ctx.pointY(bottom), right, ctx.pointY(bottom))
    }

    fun drawBarChart(ctx: DrawCtx, chart: Block.Chart, left: Float, top: Float, right: Float, bottom: Float) {
        val cb = ctx.cb
        val allValues = chart.series.flatMap { s -> s.values.map { kotlin.math.abs(it) } }
        val maxVal = (allValues.maxOrNull() ?: 1.0).coerceAtLeast(0.0001)
        
        drawGridAndAxes(ctx, left, top, right, bottom, maxVal)

        val rectWidth = right - left
        val effectiveCatCount = (if (chart.categories.isNotEmpty()) chart.categories.size else chart.series.firstOrNull()?.values?.size ?: 0).coerceAtLeast(1)
        val groupWidth = rectWidth / effectiveCatCount
        val seriesCount = chart.series.size.coerceAtLeast(1)
        val barWidth = (groupWidth * 0.7f) / seriesCount

        val labelPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 7f; color = Color.BLACK; typeface = Typeface.DEFAULT }

        for (catIdx in 0 until effectiveCatCount) {
            // رسم تسمية الفئة أسفل العمود (X-Axis Label)
            if (catIdx < chart.categories.size) {
                val catName = chart.categories[catIdx]
                val catX = left + catIdx * groupWidth + (groupWidth / 2f) - (labelPaint.measureText(catName) / 2f)
                drawTextLineBidiAware(cb, catName, catX, ctx.pointY(bottom + 12f), labelPaint)
            }

            // رسم الأعمدة
            for ((sIdx, series) in chart.series.withIndex()) {
                val value = series.values.getOrElse(catIdx) { 0.0 }
                val barHeight = (kotlin.math.abs(value) / maxVal).toFloat() * (bottom - top)
                val barLeft = left + catIdx * groupWidth + groupWidth * 0.15f + sIdx * barWidth
                val color = series.perValueColors?.getOrNull(catIdx) ?: series.colorArgb
                cb.setFillColor(color)
                cb.fillRect(barLeft, ctx.pointY(bottom), barWidth * 0.9f, barHeight)
            }
        }
    }

    fun drawLineChart(ctx: DrawCtx, chart: Block.Chart, left: Float, top: Float, right: Float, bottom: Float, filled: Boolean) {
        val cb = ctx.cb
        val allValues = chart.series.flatMap { it.values }
        val maxVal = (allValues.maxOrNull() ?: 1.0).coerceAtLeast(0.0001)
        
        drawGridAndAxes(ctx, left, top, right, bottom, maxVal)

        val effectiveCatCount = (if (chart.categories.isNotEmpty()) chart.categories.size else chart.series.firstOrNull()?.values?.size ?: 0).coerceAtLeast(2)
        val stepX = (right - left) / (effectiveCatCount - 1).coerceAtLeast(1)

        val labelPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 7f; color = Color.BLACK; typeface = Typeface.DEFAULT }

        // رسم تسمية المحور السيني (X-Axis Labels)
        for (catIdx in 0 until effectiveCatCount) {
            if (catIdx < chart.categories.size) {
                val catName = chart.categories[catIdx]
                val catX = left + catIdx * stepX - (labelPaint.measureText(catName) / 2f)
                drawTextLineBidiAware(cb, catName, catX, ctx.pointY(bottom + 12f), labelPaint)
            }
        }

        // رسم الخطوط والنقاط
        for (series in chart.series) {
            val points = mutableListOf<Pair<Float, Float>>()
            for ((i, value) in series.values.withIndex()) {
                val px = left + i * stepX
                val pyCanvas = bottom - (value / maxVal).toFloat() * (bottom - top)
                points.add(px to pyCanvas)
            }
            if (filled && points.isNotEmpty()) {
                cb.setFillColor(colorWithAlpha(series.colorArgb, 90))
                cb.moveTo(points.first().first, ctx.pointY(bottom))
                for ((px, pyCanvas) in points) cb.lineTo(px, ctx.pointY(pyCanvas))
                cb.lineTo(points.last().first, ctx.pointY(bottom))
                cb.closePath()
                cb.paintPath(fill = true, stroke = false)
            }
            cb.setStrokeColor(series.colorArgb); cb.setLineWidth(2f)
            for (i in 1 until points.size) {
                val (px0, py0) = points[i - 1]; val (px1, py1) = points[i]
                cb.drawLine(px0, ctx.pointY(py0), px1, ctx.pointY(py1))
            }
            // رسم النقاط (Dots)
            cb.setFillColor(series.colorArgb)
            for ((px, pyCanvas) in points) {
                cb.ovalPath(px, ctx.pointY(pyCanvas), 3f, 3f, fill = true, stroke = false)
            }
        }
    }

    fun drawPieChart(ctx: DrawCtx, chart: Block.Chart, left: Float, top: Float, right: Float, bottom: Float) {
        val cb = ctx.cb
        val series = chart.series.firstOrNull() ?: return
        val total = series.values.sumOf { kotlin.math.abs(it) }.coerceAtLeast(0.0001)
        val size = min(right - left, bottom - top)
        val cx = (left + right) / 2f
        val cyCanvas = (top + bottom) / 2f
        var startAngle = -90f
        val fallbackPalette = intArrayOf(
            Color.parseColor("#4285F4"), Color.parseColor("#EA4335"),
            Color.parseColor("#FBBC05"), Color.parseColor("#34A853"),
            Color.parseColor("#9C27B0"), Color.parseColor("#FF9800")
        )
        
        val labelPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 9f; color = Color.WHITE; typeface = Typeface.DEFAULT_BOLD }
        val legendPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 8f; color = Color.DKGRAY; typeface = Typeface.DEFAULT }
        
        var legendY = top + 10f
        for ((i, value) in series.values.withIndex()) {
            val sweep = (kotlin.math.abs(value) / total * 360.0).toFloat()
            val color = series.perValueColors?.getOrNull(i) ?: fallbackPalette[i % fallbackPalette.size]
            cb.setFillColor(color)
            cb.pieSlice(cx, ctx.pointY(cyCanvas), size / 2f, -startAngle, -sweep, fill = true)
            
            // رسم النسبة المئوية داخل الشريحة إذا كانت واسعة كفاية
            if (sweep > 15f) {
                val midAngle = startAngle + (sweep / 2f)
                val rad = Math.toRadians(midAngle.toDouble())
                val labelX = cx + (size / 3.5f) * Math.cos(rad).toFloat()
                val labelY = cyCanvas + (size / 3.5f) * Math.sin(rad).toFloat()
                val percentText = "${((kotlin.math.abs(value) / total) * 100).toInt()}%"
                drawTextLineBidiAware(cb, percentText, labelX - (labelPaint.measureText(percentText)/2f), ctx.pointY(labelY - 4f), labelPaint)
            }
            
            // رسم مفتاح الخريطة الخاص بالدائرة
            val catName = if (chart.categories.size > i) chart.categories[i] else "عنصر ${i+1}"
            cb.fillRect(right + 5f, ctx.pointY(legendY + 7f), 7f, 7f)
            drawTextLineBidiAware(cb, catName, right + 16f, ctx.pointY(legendY + 8f + 6f), legendPaint)
            legendY += 15f
            
            startAngle += sweep
        }
    }

    fun colorWithAlpha(argb: Int, alpha: Int): Int =
        Color.argb(alpha, Color.red(argb), Color.green(argb), Color.blue(argb))
