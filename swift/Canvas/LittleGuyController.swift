import SwiftUI
import Observation

// Owns the arm → perform lifecycle of the trick. The participant draws a stickman
// (disarmed); the performer taps the Done tick to ARM; after `armDelaySeconds`
// the little guy "comes to life". Phase 6 implements the actual rig + animation by
// setting `onComeToLife`; here it's just the spine + timing.
@MainActor @Observable final class LittleGuyController {
    enum Phase: Equatable { case idle, armed, performing, done }

    private(set) var phase: Phase = .idle

    /// Once a performance has finished, the canvas is "spent": the Done tick can't fire
    /// another performance. Only a full `reset()` (going Home) clears this — so a trick
    /// runs once per canvas visit. Drawing on top of the held reveal stays allowed.
    private(set) var isSpent = false

    /// Whether the Done tick may arm a (new) performance right now.
    var canArm: Bool { phase == .idle && !isSpent }

    /// Built when the trick fires; the stage reads these to render. Set on a
    /// reference type so writes from the escaping arm callback always reflect.
    var rig: Rig? = nil
    var routine: (any AnimationRoutine)? = nil
    /// Canvas scroll offset captured at perform time, so the stage lines up exactly.
    var originOffset: CGPoint = .zero

    /// True while the little guy is on stage (performing or holding the finish).
    var isOnStage: Bool { (phase == .performing || phase == .done) && rig != nil }

    var isArmed: Bool { phase == .armed || phase == .performing }

    /// Set by CanvasScreen. Phase 6 fills this with rig-and-animate; called once
    /// the arm delay elapses. Kept @ObservationIgnored so wiring it doesn't churn views.
    @ObservationIgnored var onComeToLife: (() -> Void)?

    @ObservationIgnored private var armTask: Task<Void, Never>?

    /// Arm the trick. After `delay` seconds (the performer's setup window) the
    /// little guy comes to life. A no-op if already armed/performing.
    func arm(delay: Double) {
        guard canArm else { return }
        phase = .armed
        armTask?.cancel()
        armTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.phase == .armed else { return }
            self.phase = .performing
            self.onComeToLife?()
        }
    }

    /// Called once the choreography ends. Keeps `rig`/`animator` so the stage holds
    /// the figure's final pose in place — it stays until the performer resets (which,
    /// per the trick, means going back out to Home). The canvas is now disarmed:
    /// `arm` only fires from `.idle`, so the Done tick can't re-trigger it.
    func finish() {
        guard phase == .performing else { return }
        phase = .done
        isSpent = true          // no re-arm until the performer goes Home (full reset)
    }

    /// Leave the held reveal for editing: drop the stage and return to idle so PencilKit
    /// is editable again, but STAY spent — the Done tick can't fire another performance.
    /// Used when the performer taps Draw after a finished reveal (the reveal is baked into
    /// a backdrop by CanvasScreen first). Only `reset()` clears `isSpent`.
    func prepareForEdit() {
        armTask?.cancel()
        armTask = nil
        phase = .idle
        rig = nil
        routine = nil
        originOffset = .zero
    }

    /// Disarm and return to a fully clean, re-armable state (used when going Home).
    func reset() {
        armTask?.cancel()
        armTask = nil
        phase = .idle
        rig = nil
        routine = nil
        originOffset = .zero
        isSpent = false
    }
}
