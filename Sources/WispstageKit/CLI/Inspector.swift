import AppKit
import Foundation

/// A running app the command line attaches to, by pid or bundle ID.
public enum InspectTarget: Equatable {
    case pid(pid_t)
    case bundleID(String)
}

/// Options for `windows`, `listing` and `shot`: `--pid N` or `--bundle-id ID` (exactly one), plus `--out`, `--window` and `--id`.
/// Both `--name value` and `--name=value` are accepted.
public struct InspectOptions {
    public static let known: Set<String> = ["--pid", "--bundle-id", "--out", "--window", "--id"]

    /// Invalid arguments (exit code 2).
    public struct Invalid: Error, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    public var target: InspectTarget
    public var values: [String: String]

    public static func parse(_ args: [String]) throws -> InspectOptions {
        let values = try optionValues(args, known: known)
        switch (values["--pid"], values["--bundle-id"]) {
        case (let p?, nil):
            guard let n = pid_t(p) else { throw Invalid(message: "--pid must be an integer: \(p)") }
            return InspectOptions(target: .pid(n), values: values)
        case (nil, let id?):
            return InspectOptions(target: .bundleID(id), values: values)
        default:
            throw Invalid(message: "Give exactly one of --pid and --bundle-id")
        }
    }
}

/// Parses `--name value` or `--name=value` options, accepting only names in `known`; throws `InspectOptions.Invalid` on bad input.
func optionValues(_ args: [String], known: Set<String>) throws -> [String: String] {
    var values: [String: String] = [:]
    var i = 0
    while i < args.count {
        let a = args[i]
        let (name, inline): (String, String?) = a.firstIndex(of: "=").map { (String(a[..<$0]), String(a[a.index(after: $0)...])) } ?? (a, nil)
        guard known.contains(name) else { throw InspectOptions.Invalid(message: "Unknown argument \(a)") }
        if let inline {
            values[name] = inline
            i += 1
        } else {
            guard i + 1 < args.count else { throw InspectOptions.Invalid(message: "\(name) needs a value") }
            values[name] = args[i + 1]
            i += 2
        }
    }
    return values
}

/// Attaches to a running app to read its windows and UI, without launching it through `AppProcess`.
public enum Inspector {
    public static func pid(of target: InspectTarget) throws -> pid_t {
        switch target {
        case .pid(let p): return p
        case .bundleID(let id):
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else {
                throw E2EFailure("No running app with bundle ID \(id)")
            }
            return app.processIdentifier
        }
    }

    /// The process's on-screen windows, with kinds assigned by the default convention (`ConventionWindowClassifier`).
    public static func windows(pid: pid_t, classifier: any WindowClassifier = ConventionWindowClassifier()) -> [AppWindow] {
        WindowList.resolve(pid: pid, app: AXNode.application(pid: pid), known: [:], classifier: classifier)
    }

    /// A text listing of each window's UI (same format as the NN-<step>.ax.txt a scenario writes per step), followed by visible elements that have no accessibility identifier.
    public static func listing(pid: pid_t) -> String {
        let ax = AXNode.application(pid: pid)
        let ws = windows(pid: pid)
        var out = ""
        for (i, w) in ws.enumerated() where w.ax != nil {
            let o = Observer.observe(w, app: ax, above: ws[..<i].map(\.frame), image: { nil })
            out += o.listingHeader + AXListing.render(o.entries)
            let missing = o.elements.filter { e in
                e.visibleFrame != nil
                    && MissingIdentifier.isMissing(role: e.role, subrole: e.subrole, id: e.id, text: e.text, actionable: e.actionable,
                                                   labelledByAncestor: false)
            }
            if !missing.isEmpty {
                out += "-- missing identifiers: \(missing.count)\n"
                for e in missing {
                    let f = e.frame.map { "(\(Int($0.minX - w.frame.minX)),\(Int($0.minY - w.frame.minY)) \(Int($0.width))x\(Int($0.height)))" } ?? ""
                    out += "  \(e.role ?? "?") \"\((e.text ?? "").prefix(AXListing.textLimit))\" \(f)\n"
                }
            }
        }
        return out
    }

    /// Screenshots windows (only `window` when given); with `id`, crops to the element with that accessibility identifier. Returns the files written.
    public static func shot(pid: pid_t, window: Int?, id: String?, to dir: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ws = windows(pid: pid).filter { window == nil || $0.id == window }
        guard !ws.isEmpty else { throw E2EFailure(window.map { "No window \($0)" } ?? "Process \(pid) has no visible windows") }
        var out: [URL] = []
        for w in ws {
            let file = dir.appendingPathComponent("\(w.kind.rawValue)-\(w.id).png")
            if let why = Screenshot.captureError(windowID: w.id, to: file) { throw E2EFailure(why) }
            guard let id else { out.append(file); continue }
            guard let node = w.ax?.first(where: { $0.identifier == id }), let frame = node.frame else { continue }
            guard let img = PNG.load(file),
                  let r = Crop.pixelRect(element: frame, window: w.frame, imageSize: CGSize(width: img.width, height: img.height), margin: 0),
                  let cut = Crop.crop(img, to: r) else { throw E2EFailure("Frame of \(id) is outside window \(w.id)") }
            let crop = dir.appendingPathComponent("\(w.kind.rawValue)-\(w.id)-\(FileName.safe(id)).png")
            guard PNG.write(cut, to: crop) else { throw E2EFailure("Could not write \(crop.path)") }
            try? FileManager.default.removeItem(at: file)
            out.append(crop)
        }
        if let id, out.isEmpty { throw E2EFailure("No element with identifier \(id)") }
        return out
    }
}
