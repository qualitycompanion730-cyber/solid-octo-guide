package com.example.pdf_master.pdfengine

import android.graphics.Color
import kotlin.math.min

// ═══════════════════════════════════════════════════════════════════════
//  ShapeRenderer.kt
//  ─────────────────────────────────────────────────────────────────────
//  مُستخرَج من NativePdfRenderer.kt كجزء من إعادة هيكلة الملف الضخم إلى
//  ملفات بمسؤولية واحدة. يحوي رسم الأشكال الهندسية (drawShape) وهيكلها
//  الصامت (drawShapeSilhouette: oval/triangle/star/...) كدوال top-level.
//  drawGroup استُبعِدت عمداً من هذا الملف ولم تُنقَل — فهي تستدعي
//  measureParagraph وdrawLayoutLines من قسم النصوص في NativePdfRenderer.kt
//  فتبقى هناك لتجنّب تشابك دائري بين الملفات.
// ═══════════════════════════════════════════════════════════════════════

    fun drawShape(ctx: DrawCtx, shape: Block.ShapeBlock, x: Float, y: Float) {
        val w = shape.widthPt.toFloat()
        val h = shape.heightPt.toFloat()
        if (w < 0.5f || h < 0.5f) return
        val cb = ctx.cb

        val hasTransform = shape.rotationDegrees != 0.0 || shape.flipHorizontal || shape.flipVertical
        cb.save()
        if (hasTransform) {
            val cx = x + w / 2f
            val cyPdf = ctx.pointY(y + h / 2f)
            val rad = Math.toRadians(-shape.rotationDegrees)
            val cos = kotlin.math.cos(rad).toFloat()
            val sin = kotlin.math.sin(rad).toFloat()
            val flipX = if (shape.flipHorizontal) -1f else 1f
            val flipY = if (shape.flipVertical) -1f else 1f
            cb.transform(cos * flipX, sin * flipX, -sin * flipY, cos * flipY, cx, cyPdf)
            cb.translate(-cx, -cyPdf)
        }

        if (shape.shadow != null) {
            val s = shape.shadow
            // ⚠️ إصلاح حقيقي مؤكَّد (شفافية ظل الشكل كانت تُتجاهَل وتُرسَم
            // معتمة بالكامل): setFillColor(s.colorArgb) وحدها تستخرج فقط
            // RGB وتتجاهل قناة الألفا تماماً (PDF لا يحمل ألفا في عامل rg
            // نفسه) — أي ظل بلون نصف-شفاف (مثل الافتراضي 0x59000000، ~35%
            // تعتيم) كان يُرسَم أسود معتماً 100% فعلياً، لا ظلاً ناعماً
            // كما هو مقصود تصميمياً. ctx.withAlpha هنا يُطبِّق شفافية
            // حقيقية عبر كائن /ExtGState فعلي (انظر PdfExtGStateManager.kt)
            // قبل الرسم، ويُلغيها تلقائياً بعده (q/Q داخلياً) فلا تتسرّب
            // لأي عملية رسم لاحقة.
            ctx.withAlpha(s.colorArgb) {
                cb.save()
                cb.translate(s.offsetXPt.toFloat(), -s.offsetYPt.toFloat())
                cb.setFillColor(s.colorArgb)
                drawShapeSilhouette(cb, shape.kind, x, ctx.pointY(y + h), w, h, fill = true, stroke = false)
                cb.restore()
            }
        }

        if (shape.gradientFill != null) {
            cb.setFillColor(shape.gradientFill.colorsArgb.firstOrNull() ?: Color.GRAY)
        } else if (shape.fillColorArgb != null) {
            cb.setFillColor(shape.fillColorArgb)
        }
        val hasFill = shape.gradientFill != null || shape.fillColorArgb != null
        val hasStroke = shape.lineColorArgb != null && shape.lineWidthPt > 0
        if (hasStroke) {
            cb.setStrokeColor(shape.lineColorArgb!!)
            cb.setLineWidth(shape.lineWidthPt.toFloat())
        }

        val py = ctx.pointY(y + h)
        drawShapeSilhouette(cb, shape.kind, x, py, w, h, hasFill, hasStroke)

        cb.restore()
    }

    fun drawShapeSilhouette(
        cb: PdfContentBuilder, kind: String, x: Float, yBottomLeft: Float, w: Float, h: Float,
        fill: Boolean, stroke: Boolean
    ) {
        fun px(xl: Float) = x + xl
        fun py(yl: Float) = yBottomLeft + (h - yl)

        fun polygon(points: List<Pair<Float, Float>>) {
            if (points.isEmpty()) return
            cb.moveTo(px(points[0].first), py(points[0].second))
            for (i in 1 until points.size) cb.lineTo(px(points[i].first), py(points[i].second))
            cb.closePath()
            cb.paintPath(fill, stroke)
        }

        when (kind) {
            "oval" -> cb.ovalPath(px(w / 2f), py(h / 2f), w / 2f, h / 2f, fill, stroke)
            "line" -> { cb.moveTo(px(0f), py(0f)); cb.lineTo(px(w), py(h)); cb.paintPath(fill = false, stroke = true) }
            "roundedRectangle" -> {
                val r = (min(w, h) * 0.12f).coerceIn(2f, 14f)
                val k = 0.5523f * r
                cb.moveTo(px(r), py(0f))
                cb.lineTo(px(w - r), py(0f))
                cb.curveTo(px(w - r + k), py(0f), px(w), py(r - k), px(w), py(r))
                cb.lineTo(px(w), py(h - r))
                cb.curveTo(px(w), py(h - r + k), px(w - r + k), py(h), px(w - r), py(h))
                cb.lineTo(px(r), py(h))
                cb.curveTo(px(r - k), py(h), px(0f), py(h - r + k), px(0f), py(h - r))
                cb.lineTo(px(0f), py(r))
                cb.curveTo(px(0f), py(r - k), px(r - k), py(0f), px(r), py(0f))
                cb.closePath()
                cb.paintPath(fill, stroke)
            }
            "triangle" -> polygon(listOf(w / 2f to 0f, w to h, 0f to h))
            "diamond" -> polygon(listOf(w / 2f to 0f, w to h / 2f, w / 2f to h, 0f to h / 2f))
            "pentagon" -> {
                val notch = w * 0.75f
                polygon(listOf(0f to 0f, notch to 0f, w to h / 2f, notch to h, 0f to h))
            }
            "chevron" -> {
                val tip = w * 0.25f
                polygon(listOf(0f to 0f, w - tip to 0f, w to h / 2f, w - tip to h, 0f to h, tip to h / 2f))
            }
            "hexagon" -> {
                val inset = w * 0.25f
                polygon(listOf(inset to 0f, w - inset to 0f, w to h / 2f, w - inset to h, inset to h, 0f to h / 2f))
            }
            "rightArrow" -> {
                val shaftH = h * 0.5f
                val shaftTop = (h - shaftH) / 2f
                val headW = w * 0.4f
                polygon(listOf(
                    0f to shaftTop, w - headW to shaftTop, w - headW to 0f,
                    w to h / 2f, w - headW to h, w - headW to shaftTop + shaftH, 0f to shaftTop + shaftH
                ))
            }
            "star" -> polygon(starPointsLocal(w, h, 5))
            else -> { cb.fillRect(px(0f), py(h), w, h); if (stroke) cb.strokeRect(px(0f), py(h), w, h) }
        }
    }

    fun starPointsLocal(w: Float, h: Float, points: Int): List<Pair<Float, Float>> {
        val cx = w / 2f; val cy = h / 2f
        val outerR = min(w, h) / 2f
        val innerR = outerR * 0.4f
        val result = mutableListOf<Pair<Float, Float>>()
        val step = Math.PI / points
        var angle = -Math.PI / 2
        for (i in 0 until points * 2) {
            val r = if (i % 2 == 0) outerR else innerR
            result.add((cx + r * Math.cos(angle)).toFloat() to (cy + r * Math.sin(angle)).toFloat())
            angle += step
        }
        return result
    }

