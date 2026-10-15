import AppKit
import SwiftUI

/// The app. Both entry points (Sources/Wispboard and Sources/WispboardTestHost) call `WispboardApp.main()`.
public struct WispboardApp: App {
    @State private var store = BoardStore()

    public init() {}

    public var body: some Scene {
        WindowGroup("Wispboard", id: "board") {
            BoardView()
                .environment(store)
                .frame(minWidth: 960, minHeight: 600)
                .background(WindowIdentifier("main.window"))
        }
        .defaultSize(width: 1040, height: 660)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("New Card")) { store.newCard() }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .background(WindowIdentifier("settings.window"))
        }
    }
}

/// Gives the hosting NSWindow an accessibility identifier, which is how scenarios tell the board window from the settings window in any language.
struct WindowIdentifier: NSViewRepresentable {
    let identifier: String

    init(_ identifier: String) { self.identifier = identifier }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.setAccessibilityIdentifier(identifier) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.setAccessibilityIdentifier(identifier)
    }
}
