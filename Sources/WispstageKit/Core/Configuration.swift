import Foundation

/// Everything an adopter (the app under test) plugs into the driver: paths, names, output line protocol, window kinds, text check parameters and lifecycle hooks.
/// The driver knows no specific app; the adopter's scenario package supplies all of these at its entry point (`WispstageCLI.main(suite:)`).
public struct E2EConfiguration {
    /// App name used in the summary header and in hints.
    public var appName: String
    /// The adopter's project directory (relative paths resolve against it).
    public var projectDir: URL
    /// Default executable under test; background mode takes the instance lock (`ScreenLock`) by its app bundle's Bundle ID.
    public var defaultExecutable: URL
    /// Each run's output directory goes under this (`<runsDir>/<timestamp>/`).
    public var runsDir: URL
    /// Root directory of baseline screenshots (`<baselinesDir>/<group>/<scenario>/<screenshot name>.png`).
    public var baselinesDir: URL
    /// Line protocol of the app's standard output; an app without a command channel still runs with the default, it just gets no events or acknowledgments.
    public var outputProtocol: any OutputProtocol
    /// How window kinds are recognized.
    public var classifier: any WindowClassifier
    public var textChecks: TextCheckConfig
    public var hooks: any E2EHooks

    public init(appName: String, projectDir: URL, defaultExecutable: URL, runsDir: URL? = nil, baselinesDir: URL? = nil,
                outputProtocol: any OutputProtocol = PrefixedLineProtocol(prefix: PrefixedLineProtocol.defaultPrefix),
                classifier: any WindowClassifier = ConventionWindowClassifier(),
                textChecks: TextCheckConfig = TextCheckConfig(), hooks: any E2EHooks = NoHooks()) {
        self.appName = appName
        self.projectDir = projectDir
        self.defaultExecutable = defaultExecutable
        self.runsDir = runsDir ?? projectDir.appendingPathComponent("build/e2e-runs")
        self.baselinesDir = baselinesDir ?? projectDir.appendingPathComponent("e2e-baselines")
        self.outputProtocol = outputProtocol
        self.classifier = classifier
        self.textChecks = textChecks
        self.hooks = hooks
    }

    /// For unit tests and unconfigured use: all paths are in the temporary directory.
    public static var standalone: E2EConfiguration {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wispstage")
        return E2EConfiguration(appName: "wispstage", projectDir: tmp, defaultExecutable: tmp.appendingPathComponent("app"))
    }
}

/// The app-specific parts of each step's text checks.
public struct TextCheckConfig {
    /// Every key in the app's string table: text equal to a key is reported as unreplaced (a failed localization lookup displays the key itself). See `CopyKeys`.
    public var copyKeys: Set<String>
    /// Regexes for the app's string key naming scheme (beyond the generic `%@` and `{…}`); a match in UI text is reported as unreplaced.
    public var extraPlaceholderPatterns: [String]
    /// Languages for text recognition in the truncation check (Vision's recognitionLanguages).
    public var ocrLanguages: [String]

    public init(copyKeys: Set<String> = [], extraPlaceholderPatterns: [String] = [], ocrLanguages: [String] = ["en-US"]) {
        self.copyKeys = copyKeys
        self.extraPlaceholderPatterns = extraPlaceholderPatterns
        self.ocrLanguages = ocrLanguages
    }

    /// The compiled extra placeholder regexes; invalid ones are skipped.
    public var compiledPatterns: [NSRegularExpression] {
        extraPlaceholderPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }
}

/// All of an adopter's scenarios and configuration.
public struct E2ESuite {
    public var configuration: E2EConfiguration
    public var scenarios: [Scenario]

    public init(configuration: E2EConfiguration, scenarios: [Scenario]) {
        self.configuration = configuration
        self.scenarios = scenarios
    }
}
