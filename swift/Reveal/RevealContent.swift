import SwiftUI

// Draws the secret onto the conjured paper: a playing-card face or a written word,
// either typed or in the performer's captured handwriting. Pure GraphicsContext
// drawing so it composites into the same Canvas as the figure and props.
//
// Everything reads "hand-drawn": typed text is rendered per-character with a small
// deterministic position/rotation wobble (so it looks sketched, not typeset), and the
// card's bottom index is rotated 180° like a real playing card.
enum RevealContent {

    static func draw(_ context: GraphicsContext,
                     in rect: CGRect,
                     payload: RevealPayload,
                     style: RevealStyle,
                     glyphs: GlyphStore?,
                     ink: Color,
                     opacity: CGFloat) {
        var ctx = context
        ctx.opacity = opacity
        switch payload {
        case .card(let c): drawCard(ctx, rect, c, style, glyphs, ink)
        case .word(let w): drawWord(ctx, rect, w, style, glyphs, ink)
        }
    }

    // MARK: Card

    /// Classic playing-card red, used for hearts/diamonds regardless of the figure's ink.
    /// Vivid enough to read on both the cream and warm-dark Little Guy papers.
    private static let cardRed = Color(red: 0.85, green: 0.16, blue: 0.16)

    private static func drawCard(_ ctx: GraphicsContext, _ rect: CGRect, _ card: Card,
                                 _ style: RevealStyle, _ glyphs: GlyphStore?, _ ink: Color) {
        // Drawn in the figure's own ink (the whole reveal is "hand-drawn"), EXCEPT a red
        // suit (hearts/diamonds) is forced to playing-card red regardless of the drawing's
        // colour — a red card should read as red. Black suits keep the figure's ink, which
        // also keeps them legible on dark paper (a forced black would vanish).
        let pip = card.suit.isRed ? cardRed : ink
        let value = card.valueLabel
        let suit = card.suit.symbol
        let cornerH = rect.height * 0.15

        // Top-left index (upright) and bottom-right index (rotated 180°, like a real card).
        let tl = CGPoint(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.13)
        let br = CGPoint(x: rect.maxX - rect.width * 0.16, y: rect.maxY - rect.height * 0.13)
        drawIndex(ctx, value, suit, corner: tl, cornerH: cornerH, color: pip,
                  style: style, glyphs: glyphs, upsideDown: false)
        drawIndex(ctx, value, suit, corner: br, cornerH: cornerH, color: pip,
                  style: style, glyphs: glyphs, upsideDown: true)

        // Big centre pip (handwriting suit if captured, else loose).
        drawGlyphText(ctx, suit, center: CGPoint(x: rect.midX, y: rect.midY),
                      height: rect.height * 0.44, color: pip, style: style, glyphs: glyphs,
                      seed: 11.2, weight: .semibold, design: .default)
    }

    /// One corner index: the value over its suit. When `upsideDown`, the whole group is
    /// rotated 180° about the corner — a faithful copy of the opposite corner, as on a
    /// real playing card.
    private static func drawIndex(_ ctx: GraphicsContext, _ value: String, _ suit: String,
                                  corner: CGPoint, cornerH: CGFloat, color: Color,
                                  style: RevealStyle, glyphs: GlyphStore?, upsideDown: Bool) {
        var c = ctx
        if upsideDown {
            c.translateBy(x: corner.x, y: corner.y)
            c.rotate(by: .radians(.pi))
            c.translateBy(x: -corner.x, y: -corner.y)
        }
        drawGlyphText(c, value, center: corner, height: cornerH, color: color,
                      style: style, glyphs: glyphs, seed: 21.5, weight: .bold, design: .serif)
        drawGlyphText(c, suit, center: CGPoint(x: corner.x, y: corner.y + cornerH * 1.05),
                      height: cornerH * 0.95, color: color, style: style, glyphs: glyphs,
                      seed: 24.9, weight: .semibold, design: .default)
    }

    // MARK: Word

    private static func drawWord(_ ctx: GraphicsContext, _ rect: CGRect, _ word: String,
                                 _ style: RevealStyle, _ glyphs: GlyphStore?, _ ink: Color) {
        // The widest the word may be: leave a margin so the per-glyph wobble/rotation
        // (and the masked paper edge) never clips. The size estimate by character count
        // undershoots for wide letters (M/W) and long words, so we MEASURE and shrink.
        let maxWidth = rect.width * 0.86
        if style == .handwriting, let glyphs {
            var capH = rect.height * 0.55
            let natural = GlyphRenderer.naturalWidth(word, glyphs: glyphs, capHeight: capH)
            if natural > maxWidth, natural > 0 { capH *= maxWidth / natural }
            let lay = GlyphRenderer.layout(word, glyphs: glyphs, in: rect, capHeight: capH)
            strokeHandwriting(ctx, lay.strokes, ink, lineWidth: max(2.5, capH * 0.09))
            for m in lay.missing {
                drawLooseText(ctx, String(m.char), center: CGPoint(x: m.rect.midX, y: m.rect.midY),
                              size: capH, weight: .semibold, design: .serif, color: ink, seed: 41.3)
            }
        } else {
            drawLooseText(ctx, word, center: CGPoint(x: rect.midX, y: rect.midY),
                          size: rect.height * 0.55, weight: .semibold, design: .rounded,
                          color: ink, seed: 31.7, maxWidth: maxWidth)
        }
    }

    // MARK: Pieces

    /// Draws a short token (card value, suit symbol, or centre pip) handwriting-first:
    /// the performer's captured glyph if present, otherwise the loose hand-lettered
    /// fallback in the given weight/design.
    private static func drawGlyphText(_ ctx: GraphicsContext, _ text: String, center: CGPoint,
                                      height: CGFloat, color: Color, style: RevealStyle,
                                      glyphs: GlyphStore?, seed: CGFloat,
                                      weight: Font.Weight, design: Font.Design) {
        if style == .handwriting, let glyphs {
            let cell = CGRect(x: center.x - height * 0.85, y: center.y - height / 2,
                              width: height * 1.7, height: height)
            let lay = GlyphRenderer.layout(text, glyphs: glyphs, in: cell, capHeight: height)
            strokeHandwriting(ctx, lay.strokes, color, lineWidth: max(2, height * 0.12))
            for m in lay.missing {
                drawLooseText(ctx, String(m.char), center: CGPoint(x: m.rect.midX, y: m.rect.midY),
                              size: height, weight: weight, design: design, color: color, seed: seed)
            }
            if !lay.strokes.isEmpty || !lay.missing.isEmpty { return }
        }
        drawLooseText(ctx, text, center: center, size: height, weight: weight,
                      design: design, color: color, seed: seed)
    }

    private static func strokeHandwriting(_ ctx: GraphicsContext, _ strokes: [[CGPoint]],
                                          _ color: Color, lineWidth: CGFloat) {
        for line in strokes {
            guard line.count >= 2 else { continue }
            var path = Path()
            path.move(to: line[0])
            for p in line.dropFirst() { path.addLine(to: p) }
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    /// Draws a string one character at a time, each glyph nudged and rotated by a small
    /// deterministic amount so typeset text reads as loosely hand-lettered. The wobble is
    /// keyed on character index + seed, so it is stable frame-to-frame (no shimmer).
    private static func drawLooseText(_ ctx: GraphicsContext, _ s: String, center: CGPoint,
                                      size: CGFloat, weight: Font.Weight, design: Font.Design,
                                      color: Color, seed: CGFloat, maxWidth: CGFloat = .infinity) {
        let chars = Array(s)
        guard !chars.isEmpty else { return }

        // Resolve & measure each glyph at a given size, laid out horizontally.
        func resolve(_ size: CGFloat) -> (items: [(rt: GraphicsContext.ResolvedText, w: CGFloat)], total: CGFloat, spacing: CGFloat) {
            let spacing = size * 0.02
            let box = CGSize(width: size * 3, height: size * 2)
            var items: [(rt: GraphicsContext.ResolvedText, w: CGFloat)] = []
            var total: CGFloat = 0
            for ch in chars {
                var rt = ctx.resolve(Text(String(ch)).font(.system(size: size, weight: weight, design: design)))
                rt.shading = .color(color)
                let w = rt.measure(in: box).width
                items.append((rt, w))
                total += w + spacing
            }
            return (items, total - spacing, spacing)
        }

        // Shrink to fit: the rendered width is linear in font size, so measure once at
        // the requested size, then re-resolve at the scaled-down size if it overflows.
        var size = size
        var m = resolve(size)
        if m.total > maxWidth, m.total > 0 {
            size *= maxWidth / m.total
            m = resolve(size)
        }

        var x = center.x - m.total / 2
        for (i, item) in m.items.enumerated() {
            let cx = x + item.w / 2
            let jx = det(i, seed) * size * 0.05
            let jy = det(i, seed + 3.3) * size * 0.06
            let rot = det(i, seed + 7.1) * 0.14     // ≈ ±4° per glyph
            var c = ctx
            c.translateBy(x: cx + jx, y: center.y + jy)
            c.rotate(by: .radians(Double(rot)))
            c.draw(item.rt, at: .zero, anchor: .center)
            x += item.w + m.spacing
        }
    }

    /// Deterministic pseudo-noise in [-0.5, 0.5) keyed on glyph index (stable per frame).
    private static func det(_ i: Int, _ seed: CGFloat) -> CGFloat {
        let x = sin(CGFloat(i) * 127.1 + seed) * 43758.5453
        return (x - floor(x)) - 0.5
    }
}
