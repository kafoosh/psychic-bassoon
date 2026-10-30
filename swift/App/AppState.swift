import SwiftUI
import Observation

enum LaunchState: Equatable {
    case spotlight   // fake Spotlight overlay (word method) — drawn over the screenshot
    case screenshot  // the performer's own Home Screen screenshot (Home Screenshot method)
    case canvas      // fake Notes / drawing app
}

// Single source of truth for what's on screen and the secret to be revealed.
// The secret lives in memory only — never persisted, never logged, never printed.
@Observable final class AppState {
    var launchState: LaunchState = .canvas

    // The committed secret the little guy will reveal.
    private(set) var reveal: RevealPayload? = nil

    // Partial card capture: the value from a grid tap (Canvas Grid) or a screenshot icon
    // tap (Home Screenshot), consumed when a suit bubble is pressed.
    private(set) var capturedValue: Int? = nil   // 1...13

    func captureValue(_ v: Int) { capturedValue = min(max(v, 1), 13) }

    /// Canvas Grid: a suit bubble was pressed — lock in the grid-tapped value with this
    /// suit, then CONSUME the partial capture so a stale value never leaks into the next
    /// trick. No grid tap before the suit → NO secret (reveal = nil): the bubble is then
    /// just a draw button and the ✓ won't bring the drawing to life.
    func commitCard(suit: Suit) {
        if let v = capturedValue {
            reveal = .card(Card(value: v, suit: suit))
        } else if case .word = reveal {
            // Word method (Home Screenshot pull-down): the word is already the secret —
            // the suit bubble is just "start drawing", so keep it.
        } else {
            reveal = nil
        }
        capturedValue = nil
    }

    /// Word method (Spotlight pull-down): lock in the spectator's typed word.
    func commitWord(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        reveal = trimmed.isEmpty ? nil : .word(trimmed)
    }

    func resetSecret() {
        reveal = nil
        capturedValue = nil
    }
}
