import SwiftUI

// The round sticker bubbles of the Little Guy toolbar (GridToolbar's suit row and its
// Undo / Done cluster), also reused by the walkthrough's suit key.

/// Little Guy toolbar sizing, derived once from the screen width and `buttonScale`.
struct StickerMetrics {
    let buttonSize: CGFloat
    var iconSize: CGFloat { buttonSize * 0.37 }
    /// Bubbles are round; the min-44 box keeps the tap target legal when `buttonScale`
    /// shrinks the sticker below the HIG minimum (it only pads out at 0.75×, where the
    /// row has room to spare — at 1.0× and up `buttonSize` is already ≥ 44).
    var hitSide: CGFloat { max(buttonSize, 44) }

    @MainActor init(settings: SettingsStore) {
        let w = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 390
        buttonSize = Self.buttonSize(screenWidth: w, scale: settings.buttonScale)
    }

    /// Widest screen the bubbles scale with. Past this (an opened iPhone Duo) they stay
    /// phone-sized and the value grid below takes the extra room.
    static let maxReferenceWidth: CGFloat = 430
    /// The one sizing formula — the canvas header fallback and the walkthrough reuse it.
    static func buttonSize(screenWidth: CGFloat, scale: CGFloat) -> CGFloat {
        (min(screenWidth, maxReferenceWidth) / 8.5) * scale
    }
}

/// One round sticker sized to a legal tap target.
struct StickerBubble: View {
    let systemName: String
    var weight: Font.Weight = .bold
    var scale: CGFloat = 1
    let fill: Color
    let metrics: StickerMetrics

    var body: some View {
        StickerIcon(systemName: systemName, weight: weight, iconSize: metrics.iconSize * scale,
                    buttonSize: metrics.buttonSize, fill: fill, cornerRatio: 0.5)
            .frame(width: metrics.hitSide, height: metrics.hitSide)
            .contentShape(Circle())
    }
}

// Deliberately NOT a Button: `onTapGesture` + `onLongPressGesture` are mutually
// exclusive, so the 0.5s disarm can't also fire an undo and eat a stroke. The
// `pressing:` callback still drives the sticker's squish.
struct StickerUndoButton: View {
    let metrics: StickerMetrics
    let onUndo: () -> Void
    let onReset: () -> Void
    @State private var pressed = false

    var body: some View {
        StickerIcon(systemName: "arrow.uturn.backward", weight: .bold, iconSize: metrics.iconSize,
                    buttonSize: metrics.buttonSize, fill: LGPalette.purple, cornerRatio: 0.5)
            .environment(\.stickerPressed, pressed)
            .frame(width: metrics.hitSide, height: metrics.hitSide)
            .contentShape(Circle())
            .onTapGesture { onUndo() }
            .onLongPressGesture(minimumDuration: 0.5, pressing: { pressed = $0 }) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onReset()
            }
            .accessibilityLabel("Undo")
    }
}

// The covert arm. Stays a plain one-tap control with no confirmation and no tap
// haptic — the arm buzz is the performer's only cue, so an armed tap and an
// ordinary keyboard-dismiss tap must feel identical to a watching spectator.
struct StickerDoneButton: View {
    let metrics: StickerMetrics
    let onDone: () -> Void

    var body: some View {
        Button(action: onDone) {
            StickerBubble(systemName: "checkmark", weight: .heavy, fill: LGPalette.orange, metrics: metrics)
        }
        .buttonStyle(StickerPress())
        .accessibilityLabel("Done")
    }
}
