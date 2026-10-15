import CoreGraphics
import Foundation

/// Compares two screenshots pixel by pixel.
public enum PixelDiff {
    public struct Result {
        public var differing: Int
        public var total: Int
        public var ratio: Double
        public var isDifferent: Bool
        /// Highlight image: differing pixels in red, the rest a faded copy of the new image; nil when the sizes differ.
        public var highlight: RGBAImage?
    }

    /// A pixel counts as differing when some channel differs by more than this (0 to 255): suppresses small jitter from antialiasing and color conversion.
    /// Picked by hand, not yet measured.
    public static let channelTolerance = 8
    /// A screenshot counts as different only when the share of differing pixels exceeds this. Picked by hand, not yet measured.
    public static let ratioTolerance = 0.005

    public static func compare(_ baseline: RGBAImage, _ current: RGBAImage) -> Result {
        guard baseline.width == current.width, baseline.height == current.height else {
            return Result(differing: current.width * current.height, total: current.width * current.height, ratio: 1, isDifferent: true, highlight: nil)
        }
        let n = current.width * current.height
        var out = [UInt8](repeating: 255, count: n * 4)
        var differing = 0
        baseline.pixels.withUnsafeBufferPointer { a in
            current.pixels.withUnsafeBufferPointer { b in
                for p in 0..<n {
                    let i = p * 4
                    var d = 0
                    for c in 0..<4 { d = max(d, abs(Int(a[i + c]) - Int(b[i + c]))) }
                    if d > channelTolerance {
                        differing += 1
                        out[i] = 255; out[i + 1] = 0; out[i + 2] = 0
                    } else {
                        // Unchanged pixels: the new image in gray, faded to 40%, so the red dots stand out
                        let luma = (Int(b[i]) * 299 + Int(b[i + 1]) * 587 + Int(b[i + 2]) * 114) / 1000
                        let v = UInt8(255 - (255 - luma) * 4 / 10)
                        out[i] = v; out[i + 1] = v; out[i + 2] = v
                    }
                }
            }
        }
        let ratio = n == 0 ? 0 : Double(differing) / Double(n)
        return Result(differing: differing, total: n, ratio: ratio, isDifferent: ratio > ratioTolerance,
                      highlight: RGBAImage(width: current.width, height: current.height, pixels: out))
    }
}

/// One screenshot that takes part in baseline comparison (full window or element), recorded in each scenario directory's shots.json.
public struct ShotRecord: Codable, Equatable {
    public var file: String
    /// Baseline group `<language>-<appearance>-<clock>`, from the launch arguments at capture time.
    public var variant: String

    public init(file: String, variant: String) {
        self.file = file
        self.variant = variant
    }

    public static let fileName = "shots.json"

    public static func write(_ records: [ShotRecord], to scenarioDir: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(records).write(to: scenarioDir.appendingPathComponent(fileName))
    }

    public static func read(from scenarioDir: URL) -> [ShotRecord] {
        guard let d = try? Data(contentsOf: scenarioDir.appendingPathComponent(fileName)) else { return [] }
        return (try? JSONDecoder().decode([ShotRecord].self, from: d)) ?? []
    }
}

/// Baseline screenshots: `<baselinesDir>/<language>-<appearance>-<clock>/<scenario>/<shot>.png`, checked into the repository.
public enum Baselines {
    public struct Diff: Codable, Equatable {
        public var file: String
        public var ratio: Double
        public var baseline: String
        public var diffImage: String?
    }

    public struct Comparison: Equatable {
        public var same = 0
        public var diffs: [Diff] = []
        public var missing: [String] = []
    }


    /// Records sys when `hour24` is nil (the preview entry point sets no clock format and follows the system).
    public static func variant(language: String, appearance: Appearance, hour24: Bool?) -> String {
        "\(language)-\(appearance.rawValue)-\(hour24.map { $0 ? "24h" : "12h" } ?? "sys")"
    }

    /// Without an explicit appearance, follow the system: reads AppleInterfaceStyle from the global domain.
    public static func resolve(_ appearance: Appearance?) -> Appearance {
        if let appearance { return appearance }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark" ? .dark : .light
    }

    /// Saves the screenshots of the scenarios a run's filters select (full-window and element screenshots listed in shots.json) as baselines, overwriting ones with the same name. Returns how many were saved.
    @discardableResult
    public static func accept(runDir: URL, filters: [String], root: URL) throws -> Int {
        let fm = FileManager.default
        let dirs = try fm.contentsOfDirectory(at: runDir, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let names = ScenarioFilter.select(dirs.map(\.lastPathComponent).sorted(), filters: filters)
        var count = 0
        for name in names {
            let sc = runDir.appendingPathComponent(name)
            for r in ShotRecord.read(from: sc) {
                let src = sc.appendingPathComponent(r.file)
                guard fm.fileExists(atPath: src.path) else { continue }
                let dst = root.appendingPathComponent(r.variant).appendingPathComponent(name).appendingPathComponent(r.file)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
                count += 1
            }
        }
        return count
    }

    /// Compares each screenshot listed in the scenario directory's shots.json with the baseline of the same name; for differing ones writes <shot>.diff.png into the scenario directory.
    public static func compare(scenarioDir: URL, scenario: String, root: URL) -> Comparison {
        var out = Comparison()
        for r in ShotRecord.read(from: scenarioDir) {
            let base = root.appendingPathComponent(r.variant).appendingPathComponent(scenario).appendingPathComponent(r.file)
            let cur = scenarioDir.appendingPathComponent(r.file)
            guard FileManager.default.fileExists(atPath: base.path) else { out.missing.append(r.file); continue }
            guard let a = RGBAImage(contentsOf: base), let b = RGBAImage(contentsOf: cur) else {
                out.diffs.append(Diff(file: r.file, ratio: 1, baseline: base.path, diffImage: nil))
                continue
            }
            let d = PixelDiff.compare(a, b)
            guard d.isDifferent else { out.same += 1; continue }
            var diffPath: String?
            if let h = d.highlight?.cgImage {
                let url = scenarioDir.appendingPathComponent((r.file as NSString).deletingPathExtension + ".diff.png")
                if PNG.write(h, to: url) { diffPath = url.path }
            }
            out.diffs.append(Diff(file: r.file, ratio: d.ratio, baseline: base.path, diffImage: diffPath))
        }
        return out
    }
}
