import Foundation

/// The `wispstage` command: subcommands that run locally (attach to a running app, re-render a summary), plus `list`, `run` and
/// `baseline`, which are forwarded unchanged to your scenario package.
///
///   wispstage windows (--pid N | --bundle-id ID)
///   wispstage listing (--pid N | --bundle-id ID) [--out file]
///   wispstage shot (--pid N | --bundle-id ID) [--window window-id] [--id identifier] [--out dir]
///   wispstage summary <run-dir>
///   wispstage init [--app-name name] [--executable executable under test, relative to the project root] [--dir scenario package dir, default E2E]
///   wispstage list [filter...]
///   wispstage run [--mode foreground|background] [--shots=key|all|none] [filter...]
///   wispstage baseline accept <run-dir> [scenario-filter...]
///
/// `list`, `run` and `baseline` look for `.wispstage.json` from the current directory upward and exec
/// `swift run --package-path <scenarioPackage> <product> <arguments unchanged>`; the scenario package sets the exit code.
/// Exit codes: 2 for usage or argument errors, 1 when execution fails.
public enum WispstageTool {
    public static let usage = """
        Usage:
          wispstage windows (--pid N | --bundle-id ID)                 List the app's on-screen windows
          wispstage listing (--pid N | --bundle-id ID) [--out file]    Export the UI listing and list visible elements without an accessibility identifier
          wispstage shot (--pid N | --bundle-id ID) [--window window-id] [--id identifier] [--out dir]   Screenshot windows or crop an element by identifier
          wispstage summary <run-dir>                                  Re-read results.json and rewrite summary.txt
          wispstage init [--app-name name] [--executable path] [--dir dir]   Create a scenario package (default E2E/) and .wispstage.json in this project
          wispstage list [filter...]                                   List scenarios (this and the next two are forwarded to the scenario package via .wispstage.json)
          wispstage run [--mode foreground|background] [--shots=key|all|none] [filter...]   Run scenarios, in background mode by default
          wispstage baseline accept <run-dir> [scenario-filter...]     Save that run's screenshots as baselines
        """

    public static func main(_ args: [String]) -> Int32 {
        guard let sub = args.first else {
            print(usage)
            return 0
        }
        let rest = Array(args.dropFirst())
        do {
            if let forwarded = forwardedArguments(args) { return try forward(forwarded) }
            switch sub {
            case "windows":
                let o = try InspectOptions.parse(rest)
                for w in Inspector.windows(pid: try Inspector.pid(of: o.target)) { print(w) }
            case "listing":
                let o = try InspectOptions.parse(rest)
                let text = Inspector.listing(pid: try Inspector.pid(of: o.target))
                if let out = o.values["--out"] {
                    try text.write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
                    print("Wrote \(out)")
                } else {
                    print(text, terminator: "")
                }
            case "shot":
                let o = try InspectOptions.parse(rest)
                let window = try o.values["--window"].map { v -> Int in
                    guard let n = Int(v) else { throw E2EFailure("--window must be an integer: \(v)") }
                    return n
                }
                let dir = URL(fileURLWithPath: o.values["--out"] ?? FileManager.default.currentDirectoryPath)
                for f in try Inspector.shot(pid: try Inspector.pid(of: o.target), window: window, id: o.values["--id"], to: dir) {
                    print(f.path)
                }
            case "summary":
                guard rest.count == 1 else { throw UsageError() }
                print(try Runner.rewriteSummary(runDir: URL(fileURLWithPath: rest[0])), terminator: "")
            case "init":
                let o = try ProjectInit.Options.parse(rest)
                let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                let i = ProjectInit(options: o, projectName: cwd.lastPathComponent, kit: ProjectInit.kitDependency(root: ProjectInit.kitRoot()))
                let report = try i.write(to: cwd)
                for f in report.created { print("Created \(f)") }
                for f in report.skipped { print("Already exists, not overwritten: \(f)") }
                print("The scenario package depends on WispstageKit at \(i.kitDescription)\n")
                print(i.nextSteps, terminator: "")
            case "-h", "--help", "help":
                print(usage)
            default:
                throw UsageError()
            }
            return 0
        } catch is UsageError {
            print(usage)
            return 2
        } catch let e as InspectOptions.Invalid {
            FileHandle.standardError.write(Data("\(e.message)\n".utf8))
            return 2
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }
    }

    struct UsageError: Error {}

    /// Top-level subcommands forwarded to the scenario package: only your scenario package knows its scenarios, so these arguments go to it unchanged.
    static let forwardedSubcommands: Set<String> = ["list", "run", "baseline"]

    /// The arguments to forward (identical to those received) when the subcommand goes to the scenario package; nil for subcommands that run locally.
    static func forwardedArguments(_ args: [String]) -> [String]? {
        guard let sub = args.first, forwardedSubcommands.contains(sub) else { return nil }
        return args
    }

    /// Finds `.wispstage.json` and replaces this process with `swift run` (exec); the scenario package sets the exit code.
    static func forward(_ args: [String]) throws -> Int32 {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let (config, dir) = try ScenarioPackageConfig.find(from: cwd) else {
            throw E2EFailure("No \(ScenarioPackageConfig.fileName) found in \(cwd.path) or any parent directory (create one: {\"scenarioPackage\": \"<scenario package dir>\", \"product\": \"<executable target>\"})")
        }
        let argv = ["/usr/bin/env"] + config.swiftRunArguments(configDir: dir, forwarding: args)
        fflush(stdout)
        var cargs = argv.map { strdup($0) } + [nil]
        execv(argv[0], &cargs)
        throw E2EFailure("Could not exec \(argv.joined(separator: " ")) (errno \(errno))")
    }
}
