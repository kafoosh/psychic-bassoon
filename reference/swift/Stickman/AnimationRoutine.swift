import SwiftUI

// A selectable "comes to life" performance. Each routine maps elapsed time → figure pose
// and draws its own props (in the figure's ink) over the figure. The Classic walks and
// conjures a box; the others have entirely different choreographies + props.
protocol AnimationRoutine {
    var totalDuration: Double { get }
    func pose(at t: Double) -> FigurePose
    func drawProps(_ ctx: GraphicsContext, at t: Double, pose: FigurePose, originOffset: CGPoint,
                   payload: RevealPayload?, style: RevealStyle, glyphs: GlyphStore?, paper: Color)
}

// The performer-chosen animation. Persisted as `SettingsStore.animationSlot` (Int).
// `.random` is a meta-slot — it isn't a routine itself; it re-rolls a fresh concrete
// routine on every reveal (see `resolved()` / `AnimationFactory.make`). It's declared
// LAST so the existing raw values (0–4) keep mapping to the same routines.
enum AnimationSlot: Int, CaseIterable, Identifiable, Codable {
    case classic, topHat, fishing, painter, balloon, random

    var id: Int { rawValue }
    var label: String { ["The Classic", "Top Hat", "Fishing", "Painter", "Balloon", "Random"][rawValue] }

    static func from(_ raw: Int) -> AnimationSlot { AnimationSlot(rawValue: raw) ?? .classic }

    /// The concrete, directly-playable routines — every slot except `.random`.
    static var playable: [AnimationSlot] { allCases.filter { $0 != .random } }

    /// Resolve to a concrete routine. `.random` rolls a fresh routine on each call
    /// (called once per reveal in `comeToLife`), so every performance differs; every
    /// other slot returns itself.
    func resolved() -> AnimationSlot {
        self == .random ? (Self.playable.randomElement() ?? .classic) : self
    }
}

// Everything a routine needs, computed once by CanvasScreen.comeToLife.
struct RoutineSetup {
    let rig: Rig
    let dropDistance: CGFloat   // fall from drawn spot to the floor
    let walkDX: CGFloat         // horizontal travel for routines that walk (else 0)
    let sideSign: CGFloat       // +1 = props favour the right, −1 = left (opposite the walk)
    let propScale: CGFloat      // prop size basis, sized so props fit the open side
    let screenSize: CGSize      // for entries from off-screen (sky / top edge)
    // The PLAYFIELD: the chrome occludes the top header bar and (Notes/Basic) the bottom
    // toolbar — the stage sits BELOW them in the ZStack, so anything drawn there is hidden.
    // These insets (in stage coords) keep the figure, the floor, and the reveal props between
    // the bars, and are passed to `fitOnScreen` so the card can never hide behind the chrome.
    let topInset: CGFloat       // header height below the safe-area top
    let bottomInset: CGFloat    // bottom toolbar height above the screen bottom

    var skeleton: Skeleton { rig.skeleton }

    /// Build the setup from the rigged figure and the live canvas geometry. Shared by
    /// `CanvasScreen.comeToLife` (and the verification harness) so prop sizing/placement
    /// is computed in exactly one place.
    ///
    /// Key idea: after the figure walks to the roomier side, props are drawn on the
    /// OPPOSITE (open) side, offset from the figure's feet. So `propScale` is sized to the
    /// room actually left between the *planted* feet and the open-side edge — guaranteeing
    /// the reveal fits the screen no matter where (or how big) the figure was drawn.
    static func make(rig: Rig, canvasBounds: CGRect, contentOffset: CGPoint,
                     topInset: CGFloat = 56, bottomInset: CGFloat = 90) -> RoutineSetup {
        let width = canvasBounds.width
        let offX = contentOffset.x

        // Drop from the drawn spot to a floor just above the bottom toolbar (so the planted
        // feet + scissoring legs clear it). Floor is chrome-aware now, not a hardcoded 96.
        let viewport = canvasBounds.height
        let footClear: CGFloat = 6
        let floorScreenY = max(viewport * 0.5, viewport - bottomInset - footClear)
        let floorY = contentOffset.y + floorScreenY
        let drop = max(0, floorY - rig.skeleton.bbox.maxY)

        // Walk to the roomier side; perform toward the opposite (open) side.
        let figCenterX = rig.skeleton.bbox.midX
        let leftRoom = figCenterX - offX
        let rightRoom = (offX + width) - figCenterX
        let goRight = rightRoom >= leftRoom
        let sideSign: CGFloat = goRight ? -1 : 1            // open side = opposite the walk
        let targetX = offX + width * (goRight ? 0.68 : 0.32)
        let walkDX = targetX - figCenterX

        // Size the props so they fit BOTH ways:
        //  • horizontally — room from the planted FEET to the open-side edge (props reach out
        //    sideways by up to ~0.90·propScale);
        //  • vertically — headroom from the feet up to the header (the reveal card rises by up
        //    to ~1.15·propScale). This is the fix for "small figure → props poke into the
        //    header": a small figure had props forced to a large MINIMUM that overflowed.
        let feetScreenX = rig.skeleton.feet.x + walkDX - offX
        let openRoom = goRight ? feetScreenX : (width - feetScreenX)
        let margin: CGFloat = 14
        let hReach: CGFloat = 0.90                          // worst-case sideways prop reach / propScale
        let vReach: CGFloat = 1.15                          // worst-case upward card reach / propScale
        let headroom = floorScreenY - topInset
        let hCap = (openRoom - margin) / hReach
        let vCap = (headroom - margin) / vReach
        let maxProp = width * 0.80
        // No inflated minimum — props are as large as the room allows (down to a small floor so
        // they're never degenerate), guaranteeing they fit the playfield however small the figure.
        let propScale = max(40, min(maxProp, hCap, vCap))

        return RoutineSetup(rig: rig, dropDistance: drop, walkDX: walkDX, sideSign: sideSign,
                            propScale: propScale, screenSize: canvasBounds.size,
                            topInset: topInset, bottomInset: bottomInset)
    }
}

extension FigurePose {
    /// A rest pose with the legs straightened (the routines build on this so legs are
    /// always rigid straight segments).
    static func rest(_ s: Skeleton) -> FigurePose {
        var p = FigurePose()
        p.leftShinAngle = s.leftShinStraighten
        p.rightShinAngle = s.rightShinStraighten
        return p
    }
}

enum AnimationFactory {
    static func make(_ slot: AnimationSlot, _ s: RoutineSetup) -> any AnimationRoutine {
        switch slot {
        case .classic: return ClassicRoutine(s)
        case .topHat:  return TopHatRoutine(s)
        case .fishing: return FishingRoutine(s)
        case .painter: return PainterRoutine(s)
        case .balloon: return BalloonRoutine(s)
        case .random:  return make(slot.resolved(), s)   // re-rolls a concrete routine each reveal
        }
    }
}
