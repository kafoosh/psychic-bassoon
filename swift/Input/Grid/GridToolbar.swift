import SwiftUI
import UIKit

// Canvas Grid — the SUIT half of the input, and the canvas chrome for this method.
//
//   idle / performing / done:   [C] [H] [S] [D]        ← four "draw" bubbles
//                              [DRAW A LITTLE GUY]     ← ribbon; LONG-PRESS = menu
//   drawing:                    [undo]          [✓]
//
// Each bubble reads as just another way to start drawing, but its POSITION is the suit in
// CHaSeD order. Pressing one commits the card (grid value + this suit) and opens PencilKit.

/// The bubble art per suit — the ONE table to edit to swap the icon set. Every one passes as
/// an ordinary drawing-app tool; only the rightmost bubble is coloured in.
enum SuitIcon {
    static func symbol(_ suit: Suit) -> String {
        switch suit {
        case .clubs:    return "paintpalette.fill"
        case .hearts:   return "eraser"
        case .spades:   return "pencil.and.scribble"
        case .diamonds: return "square.and.pencil"
        }
    }

    static func fill(_ suit: Suit) -> Color {
        suit == .diamonds ? LGPalette.orange : LGPalette.white
    }

    /// Chased order, left → right.
    static let order: [Suit] = [.clubs, .hearts, .spades, .diamonds]
}

struct GridToolbar: View {
    let settings: SettingsStore
    var editorMode: EditorMode
    var onSuit: (Suit) -> Void
    var onUndo: () -> Void
    var onDone: () -> Void
    var onReset: () -> Void
    var onNewPage: () -> Void
    var onShowSettings: () -> Void
    /// Home Screenshot: the menu's last row becomes "Return to Home Screen" (a full trick
    /// reset — the canvas zooms back into the screenshot) instead of "New Page".
    var onReturnHome: (() -> Void)? = nil
    /// false → leave out the bridged UIKit menu button (Home Screenshot renders this
    /// toolbar with ImageRenderer as the app's launch image; UIKit views can't draw there).
    var showsMenu = true

    private var metrics: StickerMetrics { StickerMetrics(settings: settings) }
    private var drawing: Bool { editorMode == .drawing }

    var body: some View {
        VStack(spacing: 10) {
            if drawing {
                HStack {
                    StickerUndoButton(metrics: metrics, onUndo: onUndo, onReset: onReset)
                    Spacer()
                    StickerDoneButton(metrics: metrics, onDone: onDone)
                }
            } else {
                suitRow
            }
            ribbon
                // Hidden (not removed) while drawing: the toolbar's measured height places
                // the value grid, so it must not jump when PencilKit opens.
                .opacity(drawing ? 0 : 1)
                .allowsHitTesting(!drawing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background {
            // While DRAWING, swallow touches across the bar so a stroke started under a
            // bubble isn't hidden by it (same as the legacy Little Guy toolbar).
            if drawing {
                Color.clear.contentShape(Rectangle()).ignoresSafeArea(edges: .top)
            }
        }
    }

    private var suitRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(SuitIcon.order.enumerated()), id: \.offset) { i, suit in
                if i > 0 { Spacer(minLength: 8) }
                Button { onSuit(suit) } label: {
                    StickerBubble(systemName: SuitIcon.symbol(suit), fill: SuitIcon.fill(suit), metrics: metrics)
                }
                .buttonStyle(StickerPress())
                .accessibilityLabel("Draw")
            }
        }
        // On a wide screen (opened iPhone Duo) keep the four bubbles a compact row
        // instead of spreading them to the far edges.
        .frame(maxWidth: StickerMetrics.maxReferenceWidth - 32)
        .walkTarget(.suitButtons)
    }

    private var ribbon: some View {
        // Long-press opens the performer menu via UIKit's built-in menu long-press on an
        // invisible bridged UIButton (see ToolbarMenuButton for why not a SwiftUI Menu).
        StickerRibbon(text: "DRAW A LITTLE GUY", hitTestable: true)
            .overlay { if showsMenu { ToolbarMenuButton(items: menuItems, primaryAction: false) } }
            .walkTarget(.ribbon)
            .accessibilityLabel("Draw a little guy")
    }

    private func menuItems() -> [UIMenuElement] {
        let animationMenu = UIMenu(title: "Animation", image: UIImage(systemName: "wand.and.stars"),
                                   children: AnimationSlot.allCases.map { slot in
            UIAction(title: slot.label,
                     state: AnimationSlot.from(settings.animationSlot) == slot ? .on : .off) { _ in
                settings.animationSlot = slot.rawValue
            }
        })
        return [
            animationMenu,
            UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { _ in onShowSettings() },
            onReturnHome.map { home in
                UIAction(title: "Return to Home Screen", image: UIImage(systemName: "house")) { _ in home() }
            } ?? UIAction(title: "New Page", image: UIImage(systemName: "square.and.pencil")) { _ in onNewPage() },
        ]
    }
}
