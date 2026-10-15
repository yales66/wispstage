import Foundation

/// `.wispstage.json` at the project root: where your scenario package is and what its executable target is called.
/// `wispstage list|run|baseline ...` looks for it from the current directory upward, then forwards the whole command to
/// `swift run --package-path <scenario-package> <executable-target> list|run|baseline ...`.
///
///     {"scenarioPackage": "app/Scripts/E2E", "product": "myapp-e2e"}
///
/// `scenarioPackage` is relative to the directory containing the config file.
public struct ScenarioPackageConfig: Codable, Equatable {
    public static let fileName = ".wispstage.json"

    public var scenarioPackage: String
    public var product: String

    public init(scenarioPackage: String, product: String) {
        self.scenarioPackage = scenarioPackage
        self.product = product
    }

    /// Searches `dir` and each parent for the config file; nil when none exists up to the root, throws when one is found but malformed.
    public static func find(from dir: URL) throws -> (config: ScenarioPackageConfig, dir: URL)? {
        var d = dir.standardizedFileURL
        while true {
            let file = d.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: file.path) {
                do {
                    return (try JSONDecoder().decode(ScenarioPackageConfig.self, from: Data(contentsOf: file)), d)
                } catch {
                    throw E2EFailure("Could not read \(file.path) (it needs string fields scenarioPackage and product): \(error)")
                }
            }
            if d.path == "/" { return nil }
            d = d.deletingLastPathComponent().standardizedFileURL
        }
    }

    /// The full forwarded command: `swift run --package-path <scenario-package> <executable-target>` followed by `args` unchanged.
    public func swiftRunArguments(configDir: URL, forwarding args: [String]) -> [String] {
        let package = (scenarioPackage.hasPrefix("/") ? URL(fileURLWithPath: scenarioPackage)
            : configDir.appendingPathComponent(scenarioPackage)).standardizedFileURL.path
        return ["swift", "run", "--package-path", package, product] + args
    }
}
