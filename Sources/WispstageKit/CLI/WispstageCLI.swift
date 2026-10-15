import Foundation

/// Command-line entry point of your scenario package: `list`, `run`, `baseline accept`. The package's main.swift calls `WispstageCLI.main(suite:)`.
///
///   <scenario-package> list [filter...]
///   <scenario-package> run [--mode foreground|background] [--shots=key|all|none] [filter...]
///   <scenario-package> baseline accept <run-dir> [scenario-filter...]
///
/// Exit codes: run returns 1 when anything fails, 2 when no scenario matched or arguments are invalid, and 75 when the screen is locked
/// before the run starts (`LockScreen.exitCode`); baseline accept returns 1 when it saved nothing; a usage error returns 2.
public enum WispstageCLI {
    public static func main(suite: E2ESuite, arguments: [String] = Array(CommandLine.arguments.dropFirst()),
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> Never {
        let args = arguments
        let command = CommandLine.arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "e2e"
        switch args.first {
        case "list":
            Runner.list(suite.scenarios, filters: Array(args.dropFirst()))
            exit(0)
        case "run":
            if LockScreen.isLocked {
                print("Screen is locked, skipped")
                exit(LockScreen.exitCode)
            }
            do {
                let (rawMode, rest) = try RunMode.extract(from: Array(args.dropFirst()))
                let mode = try RunMode.resolve(cli: rawMode, environment: environment)
                let o = try RunOptions.parse(rest)
                exit(Runner.run(suite, filters: o.filters, shots: o.shots, mode: mode))
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(2)
            }
        case "baseline" where args.count >= 3 && args[1] == "accept":
            let runDir = URL(fileURLWithPath: args[2])
            let root = suite.configuration.baselinesDir
            do {
                let n = try Baselines.accept(runDir: runDir, filters: Array(args.dropFirst(3)), root: root)
                print("Saved \(n) baseline screenshots to \(root.path)")
                exit(n > 0 ? 0 : 1)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        default:
            print("Usage: \(command) list [filter...] | run [--mode foreground|background] [--shots=key|all|none] [filter...] | baseline accept <run-dir> [scenario-filter...]\n"
                  + "  --mode can also come from the \(RunMode.environmentKey) environment variable; the default is background")
            exit(args.isEmpty ? 0 : 2)
        }
    }
}
