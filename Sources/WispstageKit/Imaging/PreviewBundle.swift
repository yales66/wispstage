import Foundation

/// The preview entry point (the debug executable `swift build` produces) is an executable outside any app bundle,
/// so the system attributes it to the terminal app that launched it: measured 2026-10-14, a preview process launched from a terminal
/// had `NSRunningApplication` report the terminal's localizedName, bundleIdentifier and bundleURL. With the terminal frontmost, as soon as
/// the process opened a window it became frontmost (a preview scenario reported the frontmost app changing from the terminal to the app under test,
/// both under the terminal's name), although the preview entry point never called `NSApp.activate()`.
/// So before launching a preview, the driver copies it into a minimal app bundle with its own bundle ID so it runs as itself (the E2E bundle is also launched from the driver,
/// has its own bundle ID, and does not become frontmost).
public enum PreviewBundle {
    /// Wraps the executable (copying again only when the source size or modification date changed) and returns the executable inside the bundle. Resource bundles are found the way SwiftPM's generated
    /// `Bundle.module` does: when not found next to the main bundle it falls back to an absolute path in the build directory, so they need not be copied.
    /// `name` is the bundle name (without .app); when `hostName` is given and that executable exists in the same build directory (a test host that links the stage), that one is wrapped instead.
    public static func prepare(executable: URL, in dir: URL, bundleID: String, name bundleName: String,
                               preferring hostName: String? = nil) throws -> URL {
        let fm = FileManager.default
        var executable = executable
        if let hostName {
            let host = executable.deletingLastPathComponent().appendingPathComponent(hostName)
            if fm.isExecutableFile(atPath: host.path) { executable = host }
        }
        let contents = dir.appendingPathComponent(bundleName + ".app").appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let name = executable.lastPathComponent
        let target = macOS.appendingPathComponent(name)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": name,
            "CFBundleName": bundleName,
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "NSPrincipalClass": "NSApplication",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let plistURL = contents.appendingPathComponent("Info.plist")
        if (try? Data(contentsOf: plistURL)) != plistData { try plistData.write(to: plistURL, options: .atomic) }

        if !sameFile(executable, target) {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: executable, to: target)
            let src = try fm.attributesOfItem(atPath: executable.path)
            if let date = src[.modificationDate] { try fm.setAttributes([.modificationDate: date], ofItemAtPath: target.path) }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }
        try linkResourceBundles(from: executable.resolvingSymlinksInPath().deletingLastPathComponent(), into: contents.appendingPathComponent("Resources"))
        return target
    }

    /// SwiftPM's `Bundle.module` looks for `<package>_<module>.bundle` in `Bundle.main.resourceURL` and `bundleURL`
    /// (the generated resource_bundle_accessor.swift has no build-directory fallback path), so resource bundles next to the executable are linked into Resources.
    private static func linkResourceBundles(from source: URL, into resources: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let bundles = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "bundle" } ?? []
        for b in bundles {
            let link = resources.appendingPathComponent(b.lastPathComponent)
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == b.path { continue }
            if (try? link.checkResourceIsReachable()) == true || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try fm.removeItem(at: link)
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: b)
        }
    }

    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard let x = try? fm.attributesOfItem(atPath: a.path), let y = try? fm.attributesOfItem(atPath: b.path) else { return false }
        return (x[.size] as? NSNumber) == (y[.size] as? NSNumber)
            && (x[.modificationDate] as? Date) == (y[.modificationDate] as? Date)
    }
}
