import Foundation
import Observation
import SwiftUI

/// The three columns of the board, left to right.
public enum Column: String, CaseIterable, Identifiable, Sendable {
    case today, next, done

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .today: L("Today")
        case .next: L("Next")
        case .done: L("Done")
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max.fill"
        case .next: "arrow.forward.circle.fill"
        case .done: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .today: .orange
        case .next: .blue
        case .done: .green
        }
    }
}

/// The optional colored chip on a card.
public enum Tag: String, CaseIterable, Sendable {
    case home, health, work, errands

    var title: String {
        switch self {
        case .home: L("Home")
        case .health: L("Health")
        case .work: L("Work")
        case .errands: L("Errands")
        }
    }

    func text(dark: Bool) -> Color {
        switch self {
        case .home: dark ? Color(red: 0.50, green: 0.86, blue: 0.90) : Color(red: 0.0, green: 0.38, blue: 0.43)
        case .health: dark ? Color(red: 1.0, green: 0.62, blue: 0.71) : Color(red: 0.69, green: 0.12, blue: 0.29)
        case .work: dark ? Color(red: 0.69, green: 0.72, blue: 1.0) : Color(red: 0.24, green: 0.25, blue: 0.69)
        case .errands: dark ? Color(red: 0.90, green: 0.64, blue: 0.97) : Color(red: 0.49, green: 0.18, blue: 0.62)
        }
    }

    var tint: Color {
        switch self {
        case .home: .teal
        case .health: .pink
        case .work: .indigo
        case .errands: .purple
        }
    }
}

public struct Card: Identifiable, Equatable, Sendable {
    /// A slug made once from the English title, so accessibility identifiers (`card.<id>`) stay the same in every language and after renaming.
    public let id: String
    public var title: String
    public var column: Column
    public var tag: Tag?
    public var due: Bool

    public init(id: String, title: String, column: Column, tag: Tag? = nil, due: Bool = false) {
        self.id = id
        self.title = title
        self.column = column
        self.tag = tag
        self.due = due
    }
}

enum SyncState: Equatable {
    case never, syncing, synced

    var text: String {
        switch self {
        case .never: L("Not synced yet")
        case .syncing: L("Syncing…")
        case .synced: L("Synced just now")
        }
    }
}

@MainActor
@Observable
public final class BoardStore {
    var cards: [Card]
    var selection: Card.ID?
    var inspectorShown = false
    var sync: SyncState = .never
    /// Bumped to move keyboard focus into the inspector's title field (New Card).
    var focusTitleRequest = 0
    /// The card New Card just made: its title field starts empty, so typing replaces "Untitled".
    var freshCardID: Card.ID?

    public init(cards: [Card] = BoardStore.sampleCards) {
        self.cards = cards
    }

    func cards(in column: Column) -> [Card] { cards.filter { $0.column == column } }

    /// Cards marked due that are not done yet.
    var dueCount: Int { cards.filter { $0.due && $0.column != .done }.count }

    var selectedCard: Card? { selection.flatMap { id in cards.first { $0.id == id } } }

    func select(_ id: Card.ID?) {
        selection = id
        if id != nil { inspectorShown = true }
    }

    func toggleInspector() {
        inspectorShown.toggle()
    }

    func closeInspector() {
        inspectorShown = false
        selection = nil
    }

    func move(_ id: Card.ID, to column: Column) {
        guard let i = cards.firstIndex(where: { $0.id == id }), cards[i].column != column else { return }
        var card = cards.remove(at: i)
        card.column = column
        cards.append(card)
    }

    func rename(_ id: Card.ID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[i].title = trimmed
        if freshCardID == id { freshCardID = nil }
    }

    func delete(_ id: Card.ID) {
        cards.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    func deleteSelection() -> Bool {
        guard let id = selection else { return false }
        delete(id)
        return true
    }

    func newCard() {
        var id = "untitled"
        var n = 2
        while cards.contains(where: { $0.id == id }) {
            id = "untitled-\(n)"
            n += 1
        }
        cards.insert(Card(id: id, title: L("Untitled"), column: .today), at: 0)
        select(id)
        freshCardID = id
        focusTitleRequest += 1
    }

    /// Pretends to talk to a server for a moment without blocking the main thread.
    func startSync() {
        guard sync != .syncing else { return }
        sync = .syncing
        if PlantedBugs.syncBlocksMainThread {
            Task { @MainActor in
                PlantedBugs.blockingSync()
                self.sync = .synced
            }
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            self.sync = .synced
        }
    }

    nonisolated public static var sampleCards: [Card] {
        [
            Card(id: "water-the-ferns", title: L("Water the ferns"), column: .today, tag: .home, due: true),
            Card(id: "book-a-dentist-appointment", title: L("Book a dentist appointment"), column: .today, tag: .health, due: true),
            Card(id: "reply-to-the-landlord", title: L("Reply to the landlord"), column: .today, tag: .home, due: true),
            Card(id: "sketch-the-onboarding-flow", title: L("Sketch the onboarding flow"), column: .next, tag: .work),
            Card(id: "renew-library-books", title: L("Renew library books"), column: .next, tag: .errands),
            Card(id: "plan-the-weekend-hike", title: L("Plan the weekend hike"), column: .next),
            Card(id: "fix-the-squeaky-door", title: L("Fix the squeaky door"), column: .done, tag: .home),
            Card(id: "send-the-birthday-card", title: L("Send the birthday card"), column: .done),
        ]
    }
}

/// A string from this module's string tables (English and German).
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .strings)
}

extension Bundle {
    /// The language folder of this module's resources that best matches the user's preferred languages. SwiftPM builds the app as a
    /// bare executable whose main bundle declares no localizations; launched that way with `-AppleLanguages (de)`, lookups through
    /// `Bundle.module` still returned the English text (measured with the test host), so the matching `.lproj` is picked here directly.
    static let strings: Bundle = {
        let module = Bundle.module
        guard let language = Bundle.preferredLocalizations(from: module.localizations, forPreferences: Locale.preferredLanguages).first,
              let path = module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return module }
        return bundle
    }()
}

/// Settings keys shared by the settings window and the board.
enum SettingsKey {
    static let showCompleted = "showCompleted"
    static let remind = "remindWhenDue"
    static let density = "cardDensity"
}

enum CardDensity: String, CaseIterable, Identifiable {
    case comfortable, compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comfortable: L("Comfortable")
        case .compact: L("Compact")
        }
    }
}
