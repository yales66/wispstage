// Prints what the CI machine grants the processes that `swift test` starts, so a skipped or failing GUI test can be traced to a missing capability.
import ApplicationServices
import CoreGraphics

let session = CGSessionCopyCurrentDictionary() as? [String: Any]
print("graphical session:  \(session?["kCGSSessionOnConsoleKey"] as? Bool ?? false)")
print("screen recording:   \(CGPreflightScreenCaptureAccess())")
print("accessibility:      \(AXIsProcessTrusted())")
print("post events:        \(CGPreflightPostEventAccess())")
