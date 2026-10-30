import SwiftUI
import UIKit

// Canvas Grid — the VALUE half of the input. The paper below the toolbar is split into
// a 4×4 grid, ruled like a sketchbook so it reads as page texture, not a keypad:
//
//      ┌────┬────┬────┬────┐
//      │ A  │ 2  │ 3  │ 4  │   row 0
//      │ 5  │ 6  │ 7  │ 8  │   row 1
//      │ 9  │ 10 │ J  │ Q  │   row 2
//      │ K  │ K  │ K  │ K  │   row 3 — the whole row is King
//      └────┴────┴────┴────┘
//
// Geometry + hit math live ONLY here, shared by the capture (GridInputCatcher), the
// drawing (ValueGridBackground) and the walkthrough highlight, so they can't disagree.
struct ValueGrid: Equatable {
    static let rows = 4
    static let cols = 4

    /// The grid's area in SCREEN coordinates (the paper ignores the safe area, so its
    /// local space is the screen).
    let rect: CGRect

    var cellSize: CGSize {
        CGSize(width: rect.width / CGFloat(Self.cols), height: rect.height / CGFloat(Self.rows))
    }

    func cell(row: Int, col: Int) -> CGRect {
        CGRect(x: rect.minX + CGFloat(col) * cellSize.width,
               y: rect.minY + CGFloat(row) * cellSize.height,
               width: cellSize.width, height: cellSize.height)
    }

    /// The card value (1…13) a touch at `p` selects, or nil outside the grid.
    func value(at p: CGPoint) -> Int? {
        guard rect.width > 0, rect.height > 0,
              p.x >= rect.minX, p.x <= rect.maxX, p.y >= rect.minY, p.y <= rect.maxY else { return nil }
        let col = min(Int((p.x - rect.minX) / cellSize.width), Self.cols - 1)
        let row = min(Int((p.y - rect.minY) / cellSize.height), Self.rows - 1)
        return row == Self.rows - 1 ? 13 : row * Self.cols + col + 1
    }

    /// The cell that selects `value` (the King row returns the whole row).
    func cellRect(for value: Int) -> CGRect {
        let v = min(max(value, 1), 13)
        if v == 13 {
            let first = cell(row: Self.rows - 1, col: 0)
            return CGRect(x: rect.minX, y: first.minY, width: rect.width, height: first.height)
        }
        return cell(row: (v - 1) / Self.cols, col: (v - 1) % Self.cols)
    }
}

/// The ruled sketchbook page: a faint minor grid over the whole sheet, with the 4×4
/// value lines drawn a hair stronger and continued edge to edge (see below). The King row
/// is ruled EXACTLY like the others so nothing on the page singles it out. Static Canvas,
/// no timeline (gotcha 6); never hit-tests.
struct ValueGridBackground: View {
    let grid: ValueGrid

    /// Minor squares per major cell, across.
    private static let minorPerCell = 4

    var body: some View {
        Canvas { ctx, size in
            let r = grid.rect
            guard r.width > 0, r.height > 0 else { return }
            let cell = grid.cellSize
            let minor = cell.width / CGFloat(Self.minorPerCell)
            // Minor rows per cell rounded so the major lines land ON a minor line.
            let minorRows = max(1, Int((cell.height / minor).rounded()))
            let minorH = cell.height / CGFloat(minorRows)

            var minorPath = Path()
            // Verticals across the whole sheet, phase-aligned to the grid.
            var x = r.minX.truncatingRemainder(dividingBy: minor)
            while x <= size.width {
                minorPath.move(to: CGPoint(x: x, y: 0)); minorPath.addLine(to: CGPoint(x: x, y: size.height))
                x += minor
            }
            // Horizontals, phase-aligned to the grid top.
            var y = r.minY.truncatingRemainder(dividingBy: minorH)
            while y <= size.height {
                minorPath.move(to: CGPoint(x: 0, y: y)); minorPath.addLine(to: CGPoint(x: size.width, y: y))
                y += minorH
            }
            ctx.stroke(minorPath, with: .color(LGPalette.decorTint.opacity(0.07)), lineWidth: 0.5)

            // The major lines CONTINUE across the whole sheet at the same pitch — verticals
            // top to bottom, horizontals repeating above and below the value rows — so the
            // page reads as one even sketchbook ruling, with no boxed-in region (or King-row
            // edge) for the person drawing to notice. Only the hit math knows where it ends.
            var major = Path()
            for c in 1..<ValueGrid.cols {
                let gx = r.minX + CGFloat(c) * cell.width
                major.move(to: CGPoint(x: gx, y: 0)); major.addLine(to: CGPoint(x: gx, y: size.height))
            }
            var gy = r.minY.truncatingRemainder(dividingBy: cell.height)
            while gy <= size.height {
                major.move(to: CGPoint(x: 0, y: gy)); major.addLine(to: CGPoint(x: size.width, y: gy))
                gy += cell.height
            }
            ctx.stroke(major, with: .color(LGPalette.decorTint.opacity(0.08)), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

// The paper's touch surface in Canvas Grid. Real UIKit recognisers (live on frame one,
// like the home's PanCatcher) so the FIRST touch of the trick is never lost:
// - a 1-finger TAP, or the touch-down point of a 1-finger DRAG → `onValuePoint`
//   (a casual swipe across the page counts where it STARTED);
// - a 3-finger swipe DOWN → `onThreeFingerDown` (opens Settings).
// The 1-finger pan caps at one touch, so a 3-finger swipe can never also pick a value.
// Per gotcha 1 the consumer writes an @Observable model / AppState from these, and the
// recognisers only see touches while nothing above (PencilKit in drawing mode, the
// toolbar) claims them.
struct GridInputCatcher: UIViewRepresentable {
    var onValuePoint: (CGPoint) -> Void
    var onThreeFingerDown: () -> Void
    /// Home Screenshot: a 1-finger swipe UP that starts in the bottom band of the screen
    /// ("close the app"). Generous on purpose — a real thumb starts anywhere near the home
    /// indicator and swipes at an angle. Home Screenshot's canvas has no grid capture, so
    /// the band can't collide with value input. nil → not detected.
    var onSwipeUpFromBottom: (() -> Void)? = nil
    /// false → only a real TAP reports a value point (Home Screenshot: a drag is a swipe,
    /// not an app launch). true (Canvas Grid) → a drag's touch-down point counts too.
    var valueOnDragStart = true
    /// Home Screenshot: a 1-finger swipe DOWN anywhere (Spotlight, like the real home).
    var onSwipeDown: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let c = context.coordinator

        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = c
        view.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = c
        view.addGestureRecognizer(pan)

        let three = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handleThreePan(_:)))
        three.minimumNumberOfTouches = 3
        three.maximumNumberOfTouches = 4
        three.delegate = c
        view.addGestureRecognizer(three)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: GridInputCatcher
        init(_ parent: GridInputCatcher) { self.parent = parent }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let v = g.view else { return }
            parent.onValuePoint(g.location(in: v))
        }

        private var panStart: CGPoint = .zero
        private var firedSwipeUp = false
        private var firedSwipeDown = false
        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            let loc = g.location(in: v), tr = g.translation(in: v)
            switch g.state {
            case .began:
                // location − translation = the true touch-down point.
                panStart = CGPoint(x: loc.x - tr.x, y: loc.y - tr.y)
                firedSwipeUp = false
                firedSwipeDown = false
                if parent.valueOnDragStart { parent.onValuePoint(panStart) }
            case .changed, .ended:
                if !firedSwipeDown, let onDown = parent.onSwipeDown,
                   tr.y > 60 || (g.state == .ended && tr.y > 20 && g.velocity(in: v).y > 600),
                   tr.y > abs(tr.x) {
                    firedSwipeDown = true
                    onDown()
                }
                guard !firedSwipeUp, let onUp = parent.onSwipeUpFromBottom else { return }
                // Start anywhere in the bottom band (home-indicator inset + ~1 thumb-width).
                let band = DeviceMetrics.bottomSafeInset + 90
                let fromBottom = panStart.y > v.bounds.height - band
                // Travel 50pt up, or a quick upward flick; mostly-vertical (a diagonal thumb
                // swipe up to ~50° off vertical still counts).
                let rise = -tr.y
                let flick = g.state == .ended && rise > 20 && g.velocity(in: v).y < -500
                if fromBottom, rise > 50 || flick, rise > abs(tr.x) * 0.85 {
                    firedSwipeUp = true
                    onUp()
                }
            default:
                break
            }
        }

        private var firedThree = false
        @objc func handleThreePan(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            switch g.state {
            case .began:
                firedThree = false
            case .changed:
                guard !firedThree else { return }
                let t = g.translation(in: v)
                if t.y > 40 && t.y > abs(t.x) {
                    firedThree = true
                    parent.onThreeFingerDown()
                }
            default:
                firedThree = false
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// Canvas Grid's live, callback-written state (see gotcha 1 — writes from geometry /
/// UIKit callbacks must land on an @Observable object to re-render reliably), plus the
/// grid-tap haptic, kept PREPARED so the tick fires with no first-tap latency.
@MainActor @Observable final class GridChromeModel {
    var bottom: CGFloat = 0 {
        didSet { if bottom > 0 { Self.lastBottom = bottom } }
    }
    /// The last measured value, for the Home Screenshot launch image (rendered before the
    /// canvas — and so this model — exists).
    @ObservationIgnored static var lastBottom: CGFloat = 0
    @ObservationIgnored private let haptic = UIImpactFeedbackGenerator(style: .light)

    func tick() {
        haptic.impactOccurred(intensity: 0.75)
        haptic.prepare()
    }
}
