import SwiftUI
import PencilKit
import UIKit

// The Little Guy drawing canvas. The participant draws a stickman here; the performer
// taps the Done tick to ARM. After the arm delay the little guy "comes to life".
//
// The paper is a ruled 4×4 value grid (tap/drag-start = value — Canvas Grid only; in Home
// Screenshot the ruling is decoration), and the top row is GridToolbar's four suit bubbles
// (press = suit + start drawing). No keyboard.
struct CanvasScreen: View {
    let router: Router
    let settings: SettingsStore
    let glyphs: GlyphStore
    var walk: WalkthroughEngine? = nil
    /// Home Screenshot: swipe up from the bottom (idle) → zoom back to the screenshot.
    var onSwipeHome: (() -> Void)? = nil

    @State private var canvasView = PKCanvasView()
    @State private var editorMode: EditorMode = .idle
    @State private var controller = LittleGuyController()
    /// The finished reveal, baked to a still image so it persists behind the canvas when
    /// the performer re-enters drawing mode and can be drawn over (the live stage is gone).
    @State private var revealImage: UIImage?
    /// Canvas Grid: the MEASURED bottom of GridToolbar (incl. its ribbon) in screen
    /// coordinates — the top of the value grid and of the animation playfield. Held on an
    /// @Observable model, not @State: a @State write from the first geometry callback
    /// didn't re-render the freshly-mounted screen (gotcha 1), so the grid sat at the
    /// fallback position and then JUMPED on the first interaction.
    @State private var gridChrome = GridChromeModel()
    private var gridChromeBottom: CGFloat { gridChrome.bottom }
    @Environment(\.colorScheme) private var colorScheme

    private var style: AppStyle { settings.effectiveStyle }

    private var buttonSize: CGFloat {
        let w = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 390
        return StickerMetrics.buttonSize(screenWidth: w, scale: settings.buttonScale)
    }

    var body: some View {
        ZStack(alignment: .top) {
            style.canvasPaper(for: colorScheme)
                .ignoresSafeArea()
            ValueGridBackground(grid: valueGrid)
            GridInputCatcher(onValuePoint: captureGridValue, onThreeFingerDown: threeFingerSettings,
                             onSwipeUpFromBottom: onSwipeHome.map { home in
                                 { if canSwipeHome { home() } }
                             })
                .ignoresSafeArea()

            // A sticker-book scatter of flowers/sparkles behind the paper.
            LittleGuyBackdrop()

            contentLayer

            // The little guy performs on a transparent overlay aligned to the canvas,
            // so he comes to life exactly where he was drawn (no jump). He holds his
            // final pose when finished; the canvas is disarmed until reset (go Home).
            // Inserted inside an ALWAYS-PRESENT container: inserted directly as a child of
            // this top-level ZStack, the stage was evaluated but never mounted (no onAppear,
            // the drawing hid and nothing performed) — verified in the simulator.
            ZStack {
                if controller.isOnStage, let rig = controller.rig, let routine = controller.routine {
                    LittleGuyStage(
                        rig: rig,
                        routine: routine,
                        originOffset: controller.originOffset,
                        payload: router.appState.reveal,
                        revealStyle: settings.revealStyle,
                        glyphs: glyphs,
                        onFinished: { controller.finish(); if walk?.active != true { copySouvenir() } }
                    )
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }

            // Above the stage so the note chrome never vanishes mid-performance.
            GridToolbar(
                settings: settings,
                editorMode: editorMode,
                onSuit: selectSuit,
                onUndo: handleUndo,
                onDone: handleDone,
                onReset: handleReset,
                onNewPage: clearPage,
                onShowSettings: { router.openSettings() },
                // Unconditional (unlike the swipe): the performer's explicit "reset the
                // trick", even mid-performance. A beat's delay lets the menu finish
                // dismissing so the close zoom's window snapshot doesn't capture it.
                onReturnHome: onSwipeHome.map { home in
                    { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { home() } }
                }
            )
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
                gridChrome.bottom = $0
            }

            // Walkthrough (Canvas Grid): invisible anchors over the demo card's value cell and
            // the whole value grid, so the overlay can spotlight exactly where the performer
            // would tap and label every cell's value. Emitted ALWAYS (not only while the
            // walkthrough runs) — a conditional insertion here never reached RootView (same
            // dropped-insertion problem as the stage above). They're static, so they cost nothing.
            if settings.inputMethod == .canvasGrid, let demo = walk?.demoCard {
                let cell = valueGrid.cellRect(for: demo.value)
                let grid = valueGrid.rect
                ZStack {
                    Color.clear
                        .frame(width: cell.width, height: cell.height)
                        .walkTarget(.valueCell)   // before .position, which fills the parent
                        .position(x: cell.midX, y: cell.midY)
                    Color.clear
                        .frame(width: grid.width, height: grid.height)
                        .walkTarget(.valueGrid)
                        .position(x: grid.midX, y: grid.midY)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            }
        }
        .tint(style.canvasTint)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            controller.onComeToLife = comeToLife
            if walk?.active == true {
                // Walkthrough demo: a clean idle canvas with a pre-drawn little guy,
                // performed automatically when the reveal step arrives. (Canvas Grid
                // mounts the canvas from the first step — the grid steps show it blank.)
                editorMode = .idle
                if walk?.isCanvasStep == true { seedDemoFigure() }
                if walk?.isRevealStep == true { armDemo() }
            } else {
                editorMode = .idle
            }
        }
        .onChange(of: walk?.step) { _, step in
            guard walk?.active == true else { return }
            if walk?.isCanvasStep == true, canvasView.drawing.strokes.isEmpty, !controller.isOnStage {
                seedDemoFigure()
            }
            if walk?.isRevealStep == true { armDemo() }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            canvasView.resignFirstResponder()
            controller.reset()
        }
    }

    // MARK: Content

    // MARK: Canvas Grid

    /// The value grid: from the measured bottom of the toolbar down to the home indicator.
    private var valueGrid: ValueGrid {
        let size = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .screen.bounds.size ?? CGSize(width: 390, height: 844)
        let top = gridChromeBottom > 0 ? gridChromeBottom : DeviceMetrics.topSafeInset + 110
        let bottom = size.height - DeviceMetrics.bottomSafeInset
        return ValueGrid(rect: CGRect(x: 0, y: top, width: size.width, height: max(bottom - top, 0)))
    }

    /// A grid tap / drag-start: record the value (the last touch before a suit wins).
    /// Never while drawing — PencilKit owns the paper then (and sits above the catcher).
    private func captureGridValue(_ point: CGPoint) {
        // Canvas Grid only: in Home Screenshot the value comes from the icon tap, and the
        // canvas grid is just page ruling — no capture, no tick.
        guard settings.inputMethod == .canvasGrid, editorMode != .drawing, !router.showSettings,
              let value = valueGrid.value(at: point) else { return }
        router.appState.captureValue(value)
        if settings.gridTapHaptic { gridChrome.tick() }
    }

    /// A suit bubble: commit the card (or clear it, if no grid value was tapped — see
    /// AppState.commitCard), then start drawing. AUTO-FRESH — if a trick is
    /// pending, performing, or finished, the page is cleared first so this is a brand-new
    /// performance; strokes on an idle page are kept (the participant is continuing).
    private func selectSuit(_ suit: Suit) {
        router.appState.commitCard(suit: suit)
        if controller.phase != .idle { clearPage() }
        editorMode = .drawing
    }

    /// Blank page, re-armable — leaves the committed secret alone.
    private func clearPage() {
        controller.reset()
        revealImage = nil
        canvasView.drawing = PKDrawing()
        canvasView.undoManager?.removeAllActions()
    }

    /// Home Screenshot "close the app": allowed while idle before a suit is pressed and once a
    /// reveal has finished — never mid-drawing or while a trick is armed/performing.
    private var canSwipeHome: Bool {
        editorMode != .drawing && walk?.active != true
            && (controller.phase == .idle || controller.phase == .done)
    }

    private func threeFingerSettings() {
        guard editorMode != .drawing, !router.showSettings, walk?.active != true else { return }
        router.openSettings()
    }

    private var contentLayer: some View {
        ZStack(alignment: .topLeading) {
            // The baked reveal sits behind the (clear) canvas so new strokes draw on top of
            // it. Same fill/safe-area as the canvas, so it overlays exactly where the figure
            // performed. Hidden while the live stage is up (it renders the same frame itself).
            if let revealImage, !controller.isOnStage {
                Image(uiImage: revealImage)
                    .resizable()
                    .ignoresSafeArea(.container, edges: .bottom)
                    .allowsHitTesting(false)
            }

            NotesCanvasView(
                canvasView: $canvasView,
                isToolPickerVisible: editorMode == .drawing
            )
            .ignoresSafeArea(.container, edges: .bottom)
            .allowsHitTesting(editorMode == .drawing)
            // Hide the static strokes while the rigged copy performs over them.
            .opacity(controller.isOnStage ? 0 : 1)

        }
    }

    // MARK: Actions

    // Enter drawing mode. If a performance is on stage (holding its final pose) or an
    // arm is pending, clear it first so the canvas becomes visible and editable again —
    // otherwise the little guy's held pose keeps the canvas hidden (opacity 0) and
    // PencilKit never receives touches. Resetting also re-enables the Done-tick arm, so
    // the figure can be drawn on and performed again without going Home.
    //
    // After a FINISHED reveal we first bake the final frame to a still image and clear the
    // original strokes, so the canvas keeps showing the reveal (not the pre-performance
    // stickman) with new PencilKit strokes layered on top.
    private func enterDrawing() {
        switch controller.phase {
        case .done:
            // Finished reveal: bake it to a persistent backdrop and clear the original
            // strokes (the figure now lives in the baked image at its FINAL pose, so the
            // pre-performance stickman doesn't ghost through). Stay SPENT — Done won't
            // re-arm; only going Home resets for another trick.
            if let baked = captureRevealImage() {
                revealImage = baked
                canvasView.drawing = PKDrawing()
                canvasView.undoManager?.removeAllActions()
            }
            controller.prepareForEdit()
        case .armed, .performing:
            // Abort a pending / in-progress arm before any reveal — still re-armable.
            controller.reset()
        case .idle:
            break
        }
        editorMode = .drawing
    }

    // Render the held final reveal frame (figure in final pose + conjured card/props) to a
    // transparent still image, sized and positioned to match the live stage exactly.
    private func captureRevealImage() -> UIImage? {
        guard let rig = controller.rig, let routine = controller.routine else { return nil }
        let size = canvasView.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }

        let origin = controller.originOffset
        let payload = router.appState.reveal
        let style = settings.revealStyle
        let glyphs = self.glyphs
        // The conjured paper is the one APPEARANCE-DYNAMIC colour in the reveal. ImageRenderer
        // runs detached from the view hierarchy, so a dynamic `Color(.systemBackground)` would
        // resolve to its LIGHT variant (white) regardless of dark mode. Resolve it against the
        // canvas's real traits up front so the baked card matches the live stage exactly.
        let paper = Color(uiColor: UIColor.systemBackground.resolvedColor(with: canvasView.traitCollection))
        let frame = Canvas { ctx, _ in
            LittleGuyStage.drawFrame(ctx, at: routine.totalDuration, rig: rig, routine: routine,
                                     originOffset: origin, payload: payload,
                                     revealStyle: style, glyphs: glyphs, paper: paper)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, colorScheme)   // match appearance for any other dynamic colour

        let renderer = ImageRenderer(content: frame)
        renderer.scale = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.scale ?? 2
        renderer.isOpaque = false
        return renderer.uiImage
    }

    private func handleUndo() {
        if canvasView.undoManager?.canUndo == true {
            canvasView.undoManager?.undo()
        } else if !canvasView.drawing.strokes.isEmpty {
            canvasView.drawing = PKDrawing()
            canvasView.undoManager?.removeAllActions()
        }
    }

    // Tapping Done out of DRAWING mode (with a drawing present) is the secret arm. It arms
    // ONLY when a secret was entered (a value before the suit, or a word) — otherwise
    // the ✓ just closes the tools like an ordinary drawing app and the figure stays put.
    private func handleDone() {
        let wasDrawing = editorMode == .drawing
        editorMode = .idle
        canvasView.resignFirstResponder()
        let hasSecret = router.appState.reveal != nil
        if wasDrawing, hasSecret, !canvasView.drawing.strokes.isEmpty, controller.canArm {
            controller.arm(delay: settings.armDelaySeconds)
            triggerArmHaptic()
        }
    }

    private func handleReset() {
        controller.reset()
    }

    // Fired when the arm delay elapses: auto-rig the participant's drawing and
    // hand it to the animator, which the stage overlay renders. (Phase 7 will
    // extend the choreography with the wand/box/card reveal.)
    private func comeToLife() {
        let drawing = canvasView.drawing
        guard !drawing.strokes.isEmpty else { controller.finish(); return }
        #if DEBUG
        // Opt-in capture of the real drawn figure (launch arg `-rigCaptureEnabled YES`), so a
        // misbehaving on-device drawing becomes a replayable harness fixture — see
        // RigHarness.captureDrawing/replayCaptured. Never compiles into release
        // (RigHarness is DEBUG-only), never fires without the flag.
        if UserDefaults.standard.bool(forKey: "rigCaptureEnabled") {
            RigHarness.captureDrawing(drawing)
        }
        #endif
        // Resolve colours against the canvas appearance so a white (dark-mode) figure
        // stays white when it comes alive.
        var rig = RigFitter.fit(drawing, traits: canvasView.traitCollection)
        // Auto-Rig off → animate the drawing as ONE rigid piece (ignore the detected limbs),
        // i.e. treat it as if it weren't recognised as rig-able.
        if !settings.autoRig { rig = rig.nonArticulated }

        // Drop to the lower canvas, walk to the roomier side, and size the props to the
        // room left on the open side so the reveal always fits the screen — all computed
        // in one shared place (see RoutineSetup.make). The stage sits BELOW the toolbars in
        // the ZStack, so pass the real header/bottom-bar heights (the playfield insets) so
        // the figure + reveal never play behind the chrome (worst for a small figure).
        let (topInset, bottomInset) = stageInsets()
        let setup = RoutineSetup.make(rig: rig, canvasBounds: canvasView.bounds,
                                      contentOffset: canvasView.contentOffset,
                                      topInset: topInset, bottomInset: bottomInset)
        controller.rig = rig
        controller.originOffset = canvasView.contentOffset
        controller.routine = AnimationFactory.make(AnimationSlot.from(settings.animationSlot), setup)
    }

    // The animation playfield's chrome insets in STAGE coordinates (the stage's top aligns with
    // the canvas top, below the status bar). The HEADER = the top toolbar + ribbon; the FOOTER =
    // the home indicator. RoutineSetup uses these so the figure + reveal stay between them
    // instead of rendering behind the chrome.
    private func stageInsets() -> (top: CGFloat, bottom: CGFloat) {
        // The chrome is MEASURED (toolbar + ribbon); the stage's top sits at the safe-area
        // top, so convert the screen-space bottom into stage space.
        let top = gridChromeBottom > 0
            ? gridChromeBottom - DeviceMetrics.topSafeInset + 10
            : buttonSize + 36
        let safeBottom = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.safeAreaInsets.bottom ?? 34
        return (top, safeBottom + 10)
    }

    // MARK: Walkthrough demo

    // Drop a ready-made stickman onto the canvas so the walkthrough can show the
    // draw → check → reveal beat without anyone drawing one.
    private func seedDemoFigure() {
        let size = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .screen.bounds.size ?? CGSize(width: 390, height: 844)
        canvasView.drawing = WalkthroughDemo.figureDrawing(in: size)
    }

    // Auto-arm the seeded figure (no Done tap needed). A short beat lets layout settle
    // so the rig setup reads a valid canvas bounds.
    private func armDemo() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard walk?.active == true, controller.canArm,
                  !canvasView.drawing.strokes.isEmpty else { return }
            editorMode = .idle
            controller.arm(delay: 0)
        }
    }

    // The locked "souvenir": once the performance finishes, silently place a copy of the
    // drawing on the clipboard so the performer can paste it into the real Notes app.
    private func copySouvenir() {
        let drawing = canvasView.drawing
        guard !drawing.strokes.isEmpty else { return }
        let bounds = drawing.bounds.insetBy(dx: -24, dy: -24)
        let scale = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.scale ?? 2
        UIPasteboard.general.image = drawing.image(from: bounds, scale: scale)
    }

    private func triggerArmHaptic() {
        switch settings.armHaptic {
        case .off:    break
        case .low:    UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .high:   UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
    }
}
