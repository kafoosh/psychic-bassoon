import SwiftUI

// Per-style chrome for the drawing canvas. Little Guy is the app's own playful
// "sticker-book" look (the only style today; the switch-free accessors are the hook
// for future styles).
extension AppStyle {
    /// Accent used for the Done tick, cursor, links, slot highlight.
    var canvasTint: Color { Color(hex: "#EE7D2B") }   // sticker-book orange

    /// The canvas "paper": always a warm cream sheet — it's locked to light mode, so
    /// there's no dark variant.
    func canvasPaper(for scheme: ColorScheme) -> Color { LGPalette.paper }
}
