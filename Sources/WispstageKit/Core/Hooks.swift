import Foundation

/// Everything needed to launch the app under test once. Adopters build it in their own `extension E2ETest`, then call `launch(_:step:)`.
public struct LaunchSpec {
    public var executable: URL
    public var arguments: [String]
    /// Layered over the driver's own environment variables (the inherited environment, the stage's `WISPSTAGE_STAGE*`).
    public var environment: [String: String]
    public var ready: ReadySignal
    public var readyTimeout: TimeInterval
    public var quit: QuitStrategy
    /// Baseline screenshot group (such as `<language>-<appearance>-<hour cycle>`, see `Baselines.variant`); nil keeps the previous one.
    public var variant: String?
    /// UI language (the plural check runs only when it starts with `en`); nil means the system's first preferred language, which the app follows.
    public var language: String?
    /// The adopter's own tags; hooks use them to decide whether to act (for example, tracking costs when a real model is connected).
    public var tags: Set<String>
    /// In background mode, after launch, checks once from window metadata whether the windows stayed hidden (`VisibilityGate`).
    public var checksVisibility: Bool
    /// Hint appended to the error when the executable is missing (how to build it).
    public var missingHint: String?

    public init(executable: URL, arguments: [String] = [], environment: [String: String] = [:],
                ready: ReadySignal = .anyWindow, readyTimeout: TimeInterval = 30, quit: QuitStrategy = .terminate,
                variant: String? = nil, language: String? = nil, tags: Set<String> = [], checksVisibility: Bool = true,
                missingHint: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.ready = ready
        self.readyTimeout = readyTimeout
        self.quit = quit
        self.variant = variant
        self.language = language
        self.tags = tags
        self.checksVisibility = checksVisibility
        self.missingHint = missingHint
    }

    /// `-AppleLanguages (<language>) -AppleLocale <region>@hours=h23|h12`. AppleICUForce24HourTime in the argument domain
    /// does not affect DateFormatter's "j" template (measured 2026-10-14); only a locale identifier with @hours= switches the hour cycle.
    public static func localeArguments(language: String, region: String, hour24: Bool) -> [String] {
        ["-AppleLanguages", "(\(language))", "-AppleLocale", "\(region)@hours=\(hour24 ? "h23" : "h12")"]
    }
}

/// When the app counts as ready after launch.
public enum ReadySignal {
    /// An event of a given type arrives (a `.event` recognized by `OutputProtocol`).
    case event(String)
    /// Some line satisfies the condition.
    case line((OutputLine) -> Bool)
    /// Accessibility can read at least one window (use this for apps without a command channel).
    case anyWindow

    func satisfied(lines: [(Date, OutputLine)], hasWindow: () -> Bool) -> Bool {
        switch self {
        case .event(let type): return lines.contains { if case .event(let e) = $0.1 { return e.type == type } else { return false } }
        case .line(let match): return lines.contains { match($0.1) }
        case .anyWindow: return hasWindow()
        }
    }
}

/// How to quit normally.
public enum QuitStrategy {
    /// Send this line to standard input and wait 5 seconds; if it has not quit, SIGTERM, then SIGKILL.
    case command(String)
    /// SIGTERM directly; SIGKILL if it does not exit in time.
    case terminate
}

/// Callbacks an adopter attaches to the driver lifecycle; every method has an empty default implementation.
public protocol E2EHooks {
    /// Before launching the app (outside the `launch` step). Throwing prevents the launch and fails the scenario.
    func willLaunch(_ spec: LaunchSpec, test: E2ETest) throws
    /// After the app process ends (called on every stop; the same process may be reported more than once, so hooks deduplicate themselves).
    func didStop(_ process: AppProcess, spec: LaunchSpec?, test: E2ETest)
}

public extension E2EHooks {
    func willLaunch(_ spec: LaunchSpec, test: E2ETest) throws {}
    func didStop(_ process: AppProcess, spec: LaunchSpec?, test: E2ETest) {}
}

/// Hooks that do nothing.
public struct NoHooks: E2EHooks {
    public init() {}
}
