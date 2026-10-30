import SwiftUI

// Renders the rigged drawing, animated, on a transparent overlay sized to match the
// canvas exactly (same safe-area edges, minus the canvas scroll offset) so the figure
// starts right where it was drawn — no jump.
//
// While the choreography plays, a `TimelineView(.animation)` drives a per-frame redraw
// (the routine maps elapsed time → pose). The instant it ends we DROP the TimelineView
// and render a single static `Canvas` of the final frame — otherwise the timeline keeps
// re-running full forward-kinematics + prop drawing at the display refresh rate forever
// while the figure just holds its pose, which makes the whole app feel laggy.
struct LittleGuyStage: View {
    let rig: Rig
    let routine: any AnimationRoutine
    /// Canvas content offset at perform time; subtracted so drawing coords line up
    /// with what the participant sees on screen.
    var originOffset: CGPoint = .zero
    /// The secret the reveal props present (nil = no card/word).
    var payload: RevealPayload? = nil
    var revealStyle: RevealStyle = .typed
    var glyphs: GlyphStore? = nil
    var onFinished: () -> Void = {}

    @State private var start = Date()
    @State private var finished = false

    var body: some View {
        Group {
            if finished {
                Canvas { ctx, _ in
                    LittleGuyStage.drawFrame(ctx, at: routine.totalDuration, rig: rig, routine: routine,
                                             originOffset: originOffset, payload: payload,
                                             revealStyle: revealStyle, glyphs: glyphs)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(start)
                    Canvas { ctx, _ in
                        LittleGuyStage.drawFrame(ctx, at: min(elapsed, routine.totalDuration), rig: rig,
                                                 routine: routine, originOffset: originOffset,
                                                 payload: payload, revealStyle: revealStyle, glyphs: glyphs)
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear {
            start = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + routine.totalDuration) {
                guard !finished else { return }
                finished = true
                onFinished()
            }
        }
    }

    /// Draw one frame at the given time. Used live (per timeline tick), for the static held
    /// frame, and to bake the final reveal into a still image when the performer re-enters
    /// drawing mode (so the reveal persists and can be drawn over). Static + fully
    /// parameterised so the baked snapshot is pixel-identical to what was on stage.
    static func drawFrame(_ ctx: GraphicsContext, at clamped: Double, rig: Rig,
                          routine: any AnimationRoutine, originOffset: CGPoint,
                          payload: RevealPayload?, revealStyle: RevealStyle, glyphs: GlyphStore?,
                          paper: Color = Color(.systemBackground)) {
        let pose = routine.pose(at: clamped)
        for stroke in rig.strokes {
            guard stroke.points.count >= 2 else { continue }
            var path = Path()
            for (i, p) in stroke.points.enumerated() {
                var wp = rig.worldPoint(p, part: stroke.parts[i], pose: pose)
                wp.x -= originOffset.x
                wp.y -= originOffset.y
                if i == 0 { path.move(to: wp) } else { path.addLine(to: wp) }
            }
            ctx.stroke(
                path,
                with: .color(stroke.color),
                style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round)
            )
        }

        routine.drawProps(ctx, at: clamped, pose: pose, originOffset: originOffset,
                          payload: payload, style: revealStyle, glyphs: glyphs,
                          paper: paper)
    }
}
