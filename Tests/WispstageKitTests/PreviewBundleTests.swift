import Foundation
import Testing
@testable import WispstageKit

struct PreviewBundleTests {
    static let bundleID = "com.example.e2e.preview"

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func wrapsExecutableInAppBundleWithItsOwnBundleID() throws {
        let dir = try tempDir()
        let exe = dir.appendingPathComponent("SampleApp")
        try Data("v1".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let out = dir.appendingPathComponent("out")

        let wrapped = try PreviewBundle.prepare(executable: exe, in: out, bundleID: Self.bundleID, name: "Example Preview")
        #expect(wrapped.path.hasSuffix(".app/Contents/MacOS/SampleApp"))
        #expect(try Data(contentsOf: wrapped) == Data("v1".utf8))
        #expect(FileManager.default.isExecutableFile(atPath: wrapped.path))
        let plistURL = wrapped.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        let plist = try #require(NSDictionary(contentsOf: plistURL))
        #expect(plist["CFBundleIdentifier"] as? String == Self.bundleID)
        #expect(plist["CFBundleExecutable"] as? String == "SampleApp")
        #expect(plist["CFBundlePackageType"] as? String == "APPL")
    }

    @Test func linksNeighboringResourceBundlesIntoResources() throws {
        let dir = try tempDir()
        let exe = dir.appendingPathComponent("SampleApp")
        try Data("v1".utf8).write(to: exe)
        let res = dir.appendingPathComponent("SampleApp_SampleAppCore.bundle")
        try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: res.appendingPathComponent("marker"))
        let wrapped = try PreviewBundle.prepare(executable: exe, in: dir.appendingPathComponent("out"), bundleID: Self.bundleID, name: "Example Preview")
        let linked = wrapped.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/SampleApp_SampleAppCore.bundle/marker")
        #expect(try Data(contentsOf: linked) == Data("x".utf8))
    }

    @Test func copiesAgainWhenTheSourceChanges() throws {
        let dir = try tempDir()
        let exe = dir.appendingPathComponent("SampleApp")
        try Data("v1".utf8).write(to: exe)
        let out = dir.appendingPathComponent("out")
        _ = try PreviewBundle.prepare(executable: exe, in: out, bundleID: Self.bundleID, name: "Example Preview")
        try Data("version 2".utf8).write(to: exe)
        let wrapped = try PreviewBundle.prepare(executable: exe, in: out, bundleID: Self.bundleID, name: "Example Preview")
        #expect(try Data(contentsOf: wrapped) == Data("version 2".utf8))
    }
}
