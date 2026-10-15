import CoreGraphics
import Foundation
import Testing
@testable import WispstageKit

struct ScreenshotTests {
    @Test(.enabled(if: CGPreflightScreenCaptureAccess(), "needs Screen Recording permission for the process running the tests"))
    func failedCaptureReportsScreencaptureExitStatusAndErrorText() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        // A nonexistent window number: screencapture exits with 1 and writes "could not create image from window" to standard error (measured 2026-10-15).
        let why = Screenshot.captureError(windowID: 99_999_999, to: url)
        #expect(why?.contains("exit status 1") == true)
        #expect(why?.contains("could not create image") == true)
        #expect(!Screenshot.capture(windowID: 99_999_999, to: url))
    }
}
