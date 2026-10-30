import Foundation

// MARK: - Card

enum Suit: Int, CaseIterable, Codable, Identifiable {
    case clubs, hearts, spades, diamonds   // order matches the 4th-row icons on home page 2

    var id: Int { rawValue }
    var symbol: String { ["♣", "♥", "♠", "♦"][rawValue] }
    var name: String { ["clubs", "hearts", "spades", "diamonds"][rawValue] }
    var isRed: Bool { self == .hearts || self == .diamonds }
    /// Capitalized word ("Hearts") — reads like an invented app name on the fake home
    /// (the Check Swipe Input verify labels).
    var displayName: String { name.capitalized }
}

struct Card: Equatable, Codable {
    var value: Int   // 1...13  (1 = Ace, 11 = Jack, 12 = Queen, 13 = King)
    var suit: Suit

    var valueLabel: String {
        switch value {
        case 1:  return "A"
        case 11: return "J"
        case 12: return "Q"
        case 13: return "K"
        default: return String(value)
        }
    }

    // Long value word used by the playing-card asset filenames (ace_of_spades …).
    private var valueWord: String {
        switch value {
        case 1:  return "ace"
        case 11: return "jack"
        case 12: return "queen"
        case 13: return "king"
        default: return String(value)
        }
    }

    /// e.g. "A♠", "10♥"
    var shortLabel: String { "\(valueLabel)\(suit.symbol)" }

    /// Capitalized word for a bare 1...13 value ("Ace", "Seven", "King") — reads like an
    /// invented app name on the fake home (the Check Swipe Input verify labels).
    static func valueDisplayName(_ v: Int) -> String {
        switch v {
        case 1:  return "Ace"
        case 2:  return "Two"
        case 3:  return "Three"
        case 4:  return "Four"
        case 5:  return "Five"
        case 6:  return "Six"
        case 7:  return "Seven"
        case 8:  return "Eight"
        case 9:  return "Nine"
        case 10: return "Ten"
        case 11: return "Jack"
        case 12: return "Queen"
        case 13: return "King"
        default: return String(v)
        }
    }

    /// Base filename in the bundled "Playing cards" deck, e.g. "ace_of_spades".
    var assetBaseName: String { "\(valueWord)_of_\(suit.name)" }
}

// What the little guy ultimately reveals.
enum RevealPayload: Equatable {
    case card(Card)
    case word(String)

    var displayText: String {
        switch self {
        case .card(let c): return c.shortLabel
        case .word(let w): return w
        }
    }
}

// MARK: - Style

// The canvas look. Only Little Guy remains (Basic/Notes were removed); the enum is kept
// as the hook for future styles. Raw values are persisted (`appStyleV1`) — never renumber.
enum AppStyle: Int, CaseIterable, Codable, Identifiable {
    case littleGuy = 2

    var id: Int { rawValue }
    var label: String { "Little Guy" }

    /// The display name of this style's app — shown as the Spotlight decoy / Siri suggestion.
    var appDisplayName: String { "A Little Guy" }

    /// The decoy app name typed out / shown in the fake Siri suggestion.
    var spotlightAppName: String { appDisplayName }
}

// MARK: - Settings value types

enum ArmHaptic: Int, CaseIterable, Codable, Identifiable {
    case off, low, medium, high
    var id: Int { rawValue }
    var label: String { ["Off", "Low", "Med", "High"][rawValue] }
}

enum RevealStyle: Int, CaseIterable, Codable, Identifiable {
    case typed, handwriting
    var id: Int { rawValue }
    var label: String { ["Typed", "Handwriting"][rawValue] }
}
