import SwiftUI

// Shared hand-drawn drawing primitives, used by every animation routine so all props
// read as loose outlines in the figure's OWN ink colour. The wobble is deterministic
// (keyed on vertex index + seed) so it's stable frame-to-frame — no shimmer.
enum SketchInk {

    /// Deterministic pseudo-noise in [-0.5, 0.5) keyed on vertex index.
    static func det(_ i: Int, _ seed: CGFloat) -> CGFloat {
        let x = sin(CGFloat(i) * 127.1 + seed) * 43758.5453
        return (x - floor(x)) - 0.5
    }

    /// Stroke a polyline (or closed polygon) with a small hand-drawn wobble.
    static func sketch(_ ctx: GraphicsContext, _ pts: [CGPoint], ink: Color, lw: CGFloat,
                       closed: Bool = false, amp: CGFloat = 0, seed: CGFloat = 1, opacity: CGFloat = 1) {
        guard pts.count >= 2 else { return }
        var c = ctx
        c.opacity = opacity
        func j(_ i: Int, _ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x + det(i, seed) * amp, y: p.y + det(i, seed + 9.7) * amp)
        }
        var path = Path()
        path.move(to: j(0, pts[0]))
        for i in 1..<pts.count { path.addLine(to: j(i, pts[i])) }
        if closed { path.addLine(to: j(0, pts[0])) }
        c.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
    }

    /// A partially-drawn polyline: only the first `progress` (0…1) of its length is shown.
    /// Used for "draw-on" reveals (the Painter routine).
    static func sketchPartial(_ ctx: GraphicsContext, _ pts: [CGPoint], progress: CGFloat,
                              ink: Color, lw: CGFloat, closed: Bool = false,
                              amp: CGFloat = 0, seed: CGFloat = 1) -> CGPoint {
        var full = pts
        if closed, let first = pts.first { full.append(first) }
        guard full.count >= 2 else { return pts.first ?? .zero }
        // total length
        var seg: [CGFloat] = []
        var total: CGFloat = 0
        for i in 1..<full.count {
            let d = hypot(full[i].x - full[i-1].x, full[i].y - full[i-1].y)
            seg.append(d); total += d
        }
        let target = max(0, min(progress, 1)) * total
        var acc: CGFloat = 0
        var out: [CGPoint] = [full[0]]
        var tip = full[0]
        for i in 1..<full.count {
            let d = seg[i-1]
            if acc + d <= target {
                out.append(full[i]); tip = full[i]; acc += d
            } else {
                let f = d > 0 ? (target - acc) / d : 0
                tip = CGPoint(x: full[i-1].x + (full[i].x - full[i-1].x) * f,
                              y: full[i-1].y + (full[i].y - full[i-1].y) * f)
                out.append(tip)
                break
            }
        }
        sketch(ctx, out, ink: ink, lw: lw, closed: false, amp: amp, seed: seed)
        return tip
    }

    static func rectPts(_ r: CGRect, perEdge: Int = 3) -> [CGPoint] {
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        var pts: [CGPoint] = []
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            for k in 0..<perEdge {
                let f = CGFloat(k) / CGFloat(perEdge)
                pts.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            }
        }
        return pts
    }

    /// Points of an N-sided circle/ellipse (for sketchy round shapes).
    static func ovalPts(center: CGPoint, rx: CGFloat, ry: CGFloat, n: Int = 20) -> [CGPoint] {
        (0..<n).map { k in
            let a = Double(k) / Double(n) * 2 * .pi
            return CGPoint(x: center.x + rx * CGFloat(cos(a)), y: center.y + ry * CGFloat(sin(a)))
        }
    }

    static func star(_ ctx: GraphicsContext, center: CGPoint, radius: CGFloat,
                     ink: Color, lw: CGFloat, opacity: CGFloat = 1) {
        let inner = radius * 0.4
        var pts: [CGPoint] = []
        for i in 0..<8 {
            let r = (i % 2 == 0) ? radius : inner
            let a = -Double.pi / 2 + Double(i) * (.pi / 4)
            pts.append(CGPoint(x: center.x + r * CGFloat(cos(a)), y: center.y + r * CGFloat(sin(a))))
        }
        sketch(ctx, pts, ink: ink, lw: lw, closed: true, amp: radius * 0.10, seed: 6.6, opacity: opacity)
    }

    static func sparkles(_ ctx: GraphicsContext, around c: CGPoint, spread: CGFloat,
                         intensity g: CGFloat, ink: Color, lw: CGFloat) {
        let offs = [CGPoint(x: -0.5, y: -0.2), CGPoint(x: 0.45, y: -0.35), CGPoint(x: 0.1, y: -0.62),
                    CGPoint(x: -0.28, y: 0.22), CGPoint(x: 0.55, y: 0.12), CGPoint(x: -0.6, y: -0.5)]
        var cc = ctx
        cc.opacity = g
        for (i, o) in offs.enumerated() {
            let p = CGPoint(x: c.x + o.x * spread, y: c.y + o.y * spread)
            let r = spread * 0.10 * (0.6 + 0.4 * sin(CGFloat(i) * 1.7))
            let d = r * 0.6
            var path = Path()
            path.move(to: CGPoint(x: p.x - r, y: p.y)); path.addLine(to: CGPoint(x: p.x + r, y: p.y))
            path.move(to: CGPoint(x: p.x, y: p.y - r)); path.addLine(to: CGPoint(x: p.x, y: p.y + r))
            path.move(to: CGPoint(x: p.x - d, y: p.y - d)); path.addLine(to: CGPoint(x: p.x + d, y: p.y + d))
            path.move(to: CGPoint(x: p.x - d, y: p.y + d)); path.addLine(to: CGPoint(x: p.x + d, y: p.y - d))
            cc.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: max(1.5, lw * 0.5), lineCap: .round))
        }
    }

    /// A wand from `hand`, pointing away from `shoulder`, with a star tip.
    static func wand(_ ctx: GraphicsContext, hand: CGPoint, shoulder: CGPoint, length: CGFloat,
                     swing: CGFloat, opacity: CGFloat, ink: Color, lw: CGFloat) {
        var dx = hand.x - shoulder.x, dy = hand.y - shoulder.y
        let mag = hypot(dx, dy)
        if mag < 1 { dx = 0; dy = -1 } else { dx /= mag; dy /= mag }
        let sa = sin(swing), ca = cos(swing)
        let rdx = dx * ca - dy * sa, rdy = dx * sa + dy * ca
        let tip = CGPoint(x: hand.x + rdx * length, y: hand.y + rdy * length)
        let mid = CGPoint(x: hand.x + rdx * length * 0.5, y: hand.y + rdy * length * 0.5)
        sketch(ctx, [hand, mid, tip], ink: ink, lw: lw, closed: false, amp: length * 0.03, seed: 4.4, opacity: opacity)
        star(ctx, center: tip, radius: length * 0.17, ink: ink, lw: lw * 0.85, opacity: opacity)
    }

    /// The conjured paper + the secret on it. Masks whatever is behind with the canvas
    /// colour so the figure doesn't show through, then sketches the outline and content.
    /// `wipe` (0…1) reveals the paper + secret top-down (the Painter's fill-in) while the
    /// border always draws whole — a partially-materialized card still has ONE outline.
    static func cardFace(_ ctx: GraphicsContext, rect: CGRect, opacity: CGFloat, ink: Color,
                         lw: CGFloat, paper: Color, payload: RevealPayload?,
                         style: RevealStyle, glyphs: GlyphStore?, wipe: CGFloat = 1) {
        let wipeClip = Path(CGRect(x: rect.minX - lw, y: rect.minY - lw,
                                   width: rect.width + lw * 2,
                                   height: (rect.height + lw * 2) * max(wipe, 0)))
        if wipe > 0 {
            var c = ctx
            c.opacity = opacity
            if wipe < 1 { c.clip(to: wipeClip) }
            c.fill(Path(roundedRect: rect, cornerRadius: rect.width * 0.06), with: .color(paper))
        }
        sketch(ctx, rectPts(rect, perEdge: 4), ink: ink, lw: lw, closed: true,
               amp: rect.width * 0.025, seed: 2.2, opacity: opacity)
        if let payload, wipe > 0 {
            var cc = ctx
            if wipe < 1 { cc.clip(to: wipeClip) }
            let inner = rect.insetBy(dx: rect.width * 0.09, dy: rect.height * 0.07)
            RevealContent.draw(cc, in: inner, payload: payload, style: style,
                               glyphs: glyphs, ink: ink, opacity: opacity)
        }
    }
}
