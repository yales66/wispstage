// Test host: the same app as Sources/Wispboard, plus the Wispstage stage library, which the end-to-end scenarios in E2E/ need
// for background mode (the app's windows stay beneath the wallpaper and it never takes the keyboard or the cursor).
import AppKit
import Foundation
import Wispstage
import WispboardKit

MainActor.assumeIsolated {
    // Every scenario starts from the default settings: forget what the previous launch of the test host saved.
    if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
    let app = NSApplication.shared
    // Scenarios pin the appearance with `-WispboardAppearance light|dark`, so screenshots don't follow the Mac's own setting
    // (`-AppleInterfaceStyle Light` on the command line did not override a system set to dark).
    switch UserDefaults.standard.string(forKey: "WispboardAppearance") {
    case "light": app.appearance = NSAppearance(named: .aqua)
    case "dark": app.appearance = NSAppearance(named: .darkAqua)
    default: break
    }
    _ = Wispstage.install()
    WispboardApp.main()
}
