import SwiftUI

// Playful "sticker" chrome for the `.littleGuy` canvas — a cream sketchpad with
// scattered orange flowers/sparkles and chunky black-outlined buttons. Scoped to
// Little Guy only; Basic/Notes keep their realistic Apple-Notes look.

// MARK: - Palette

enum LGPalette {
    static let ink    = Color(hex: "#1C1B19")   // near-black outline + glyph ink
    static let white  = Color(hex: "#FFFDF8")   // back / menu sticker fill
    static let orange = Color(hex: "#EE7D2B")   // accent: decorations + Done tick
    static let purple = Color(hex: "#B6A2E8")   // draw + undo sticker
    static let yellow = Color(hex: "#F4C740")   // brand pop
    static let paper  = Color(hex: "#FBF6EA")   // cream sketchpad + header block

    /// Flower/sparkle tint + deeper centre. Little Guy is light-only, so these are
    /// fixed — no dark variant.
    static let decorTint = Color(hex: "#EF8326")
    static let decorDeep = Color(hex: "#C75A1E")
}

// MARK: - Sticker surface

/// Press state for the sticker chrome, published by `StickerPress` (a ButtonStyle can't
/// hand its `isPressed` to its own label any other way) and read by `stickerSurface`.
/// Defaults to false, so a sticker used outside a Button (the menu) is simply never pressed.
private struct StickerPressedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var stickerPressed: Bool {
        get { self[StickerPressedKey.self] }
        set { self[StickerPressedKey.self] = newValue }
    }
}

/// Squish a sticker into the page on press. Put this on the Button, not the label.
struct StickerPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.stickerPressed, configuration.isPressed)
    }
}

private struct StickerSurface: ViewModifier {
    let fill: Color
    let corner: CGFloat
    let offset: CGFloat
    let lineWidth: CGFloat
    @Environment(\.stickerPressed) private var pressed

    func body(content: Content) -> some View {
        // Pressing shrinks the ink backdrop AND slides the face down-left by the same
        // delta, so the backdrop's outer edge stays put while the sticker sinks into it —
        // it reads as being pressed flat onto the paper, then springing back.
        let shadow = pressed ? offset * 0.25 : offset
        let shift = offset - shadow
        return content
            .background(RoundedRectangle(cornerRadius: corner, style: .continuous).fill(fill))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(LGPalette.ink, lineWidth: lineWidth)
            )
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(LGPalette.ink)
                    .offset(x: -shadow, y: shadow)
            )
            .offset(x: -shift, y: shift)
            // Animates ONLY when the press state flips — never an always-on timeline.
            .animation(.spring(response: 0.18, dampingFraction: 0.65), value: pressed)
    }
}

extension View {
    /// The "sticker" treatment worn by every Little Guy toolbar button: a colour fill,
    /// a thin ink outline, and a HARD offset backdrop — a solid ink shape nudged
    /// down-left (like a sticker peeling off the page). No blur.
    func stickerSurface(fill: Color, corner: CGFloat, offset: CGFloat, lineWidth: CGFloat = 2) -> some View {
        modifier(StickerSurface(fill: fill, corner: corner, offset: offset, lineWidth: lineWidth))
    }
}

/// A square icon laid into a sticker surface. Used as the label for the toolbar's
/// back / draw / undo / done / menu buttons so they all share one look. `cornerRatio`
/// 0.5 makes it a round "bubble" (the floating Little Guy chrome); 0.3 is the original
/// rounded chip.
struct StickerIcon: View {
    let systemName: String
    var weight: Font.Weight = .bold
    let iconSize: CGFloat
    let buttonSize: CGFloat
    var fill: Color
    var icon: Color = LGPalette.ink
    var cornerRatio: CGFloat = 0.3

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconSize, weight: weight))
            .foregroundStyle(icon)
            .frame(width: buttonSize, height: buttonSize)
            .stickerSurface(fill: fill, corner: buttonSize * cornerRatio, offset: buttonSize * 0.1)
    }
}

/// The "DRAW A LITTLE GUY" prompt as a stuck-on paper ribbon, riding in the toolbar row
/// between the back bubble and the right cluster. Decorative by default — hit-testing is
/// off so a tap falls through to the paper (which opens the keyboard). Canvas Grid turns
/// `hitTestable` on: its ribbon carries the long-press settings menu.
struct StickerRibbon: View {
    let text: String
    var hitTestable = false

    var body: some View {
        // ~154pt at full size. It SHRINKS rather than vanishing when the bubbles grow:
        // with a big "Notes Button Size" on a narrow phone a fixed-size ribbon had to be
        // suppressed entirely (any scale over ~1.04 on a 375pt screen), which loses the
        // prompt for exactly the people who scaled the UI up. minimumScaleFactor buys
        // ~27pt of give; below that `ribbonFits` steps it aside so it can never truncate.
        Text(text)
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .tracking(0.5)
            .foregroundStyle(LGPalette.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .stickerSurface(fill: LGPalette.yellow, corner: 8, offset: 3)
            .rotationEffect(.degrees(-1.5))
            // Decorative to touch, but NOT to VoiceOver — it's the only prompt on screen
            // now that the body placeholder is gone.
            .allowsHitTesting(hitTestable)
    }
}

// MARK: - Decorative backdrop

// A static scatter of orange flowers, four-point sparkles, and little sunbursts
// behind the paper — the "back of the sticker book". Drawn once in a Canvas (no
// timeline) so it never costs a frame; sits below the clear PencilKit surface and
// is hit-test transparent, so the participant still draws straight onto the paper.
struct LittleGuyBackdrop: View {
    private enum Kind { case flower, sparkle, burst }
    private struct Deco { let kind: Kind; let x, y, r, opacity, rot: CGFloat }

    // Normalised positions (x,y in 0…1), absolute radii in points, kept to the
    // periphery so the centre stays clean for the drawing; a couple of faint ones
    // drift inward for texture.
    private static let decos: [Deco] = [
        Deco(kind: .flower,  x: 0.12, y: 0.27, r: 28, opacity: 0.50, rot: 0),
        Deco(kind: .sparkle, x: 0.88, y: 0.25, r: 24, opacity: 0.50, rot: 12),
        Deco(kind: .flower,  x: 0.92, y: 0.45, r: 20, opacity: 0.42, rot: 0),
        Deco(kind: .sparkle, x: 0.06, y: 0.40, r: 16, opacity: 0.40, rot: 8),
        Deco(kind: .burst,   x: 0.14, y: 0.82, r: 30, opacity: 0.48, rot: 0),
        Deco(kind: .sparkle, x: 0.85, y: 0.75, r: 28, opacity: 0.52, rot: -10),
        Deco(kind: .flower,  x: 0.33, y: 0.92, r: 22, opacity: 0.45, rot: 0),
        Deco(kind: .sparkle, x: 0.63, y: 0.55, r: 14, opacity: 0.28, rot: 0),
        Deco(kind: .sparkle, x: 0.20, y: 0.62, r: 12, opacity: 0.26, rot: 0),
    ]

    var body: some View {
        Canvas { ctx, size in
            let tint = LGPalette.decorTint
            let deep = LGPalette.decorDeep
            for d in Self.decos {
                let c = CGPoint(x: d.x * size.width, y: d.y * size.height)
                ctx.opacity = d.opacity
                switch d.kind {
                case .flower:  Self.flower(ctx, c, d.r, tint, deep)
                case .sparkle: Self.sparkle(ctx, c, d.r, tint, d.rot)
                case .burst:   Self.burst(ctx, c, d.r, tint)
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    // MARK: shape drawing

    private static func disc(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    private static func flower(_ ctx: GraphicsContext, _ c: CGPoint, _ r: CGFloat,
                               _ color: Color, _ deep: Color) {
        let petal = r * 0.55, ring = r * 0.60
        for i in 0..<5 {
            let a = CGFloat(i) / 5 * 2 * .pi - .pi / 2
            let pc = CGPoint(x: c.x + cos(a) * ring, y: c.y + sin(a) * ring)
            ctx.fill(disc(pc, petal), with: .color(color))
        }
        ctx.fill(disc(c, r * 0.50), with: .color(color))
        ctx.fill(disc(c, r * 0.26), with: .color(deep))
    }

    private static func sparkle(_ ctx: GraphicsContext, _ c: CGPoint, _ r: CGFloat,
                                _ color: Color, _ rotDeg: CGFloat) {
        let inner = r * 0.30
        let rot = rotDeg * .pi / 180
        var p = Path()
        for i in 0..<8 {
            let a = rot + CGFloat(i) * (.pi / 4) - .pi / 2
            let rad = (i % 2 == 0) ? r : inner
            let pt = CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        ctx.fill(p, with: .color(color))
    }

    private static func burst(_ ctx: GraphicsContext, _ c: CGPoint, _ r: CGFloat,
                              _ color: Color) {
        let n = 12, inner = r * 0.34, outer = r, halfW = r * 0.085
        for i in 0..<n {
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi
            let dx = cos(a), dy = sin(a), px = -sin(a), py = cos(a)
            var p = Path()
            p.move(to: CGPoint(x: c.x + dx * inner + px * halfW, y: c.y + dy * inner + py * halfW))
            p.addLine(to: CGPoint(x: c.x + dx * outer, y: c.y + dy * outer))
            p.addLine(to: CGPoint(x: c.x + dx * inner - px * halfW, y: c.y + dy * inner - py * halfW))
            p.closeSubpath()
            ctx.fill(p, with: .color(color))
        }
        ctx.fill(disc(c, r * 0.30), with: .color(color))
    }
}
