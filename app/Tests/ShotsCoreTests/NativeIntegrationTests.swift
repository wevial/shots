import Foundation
import Testing
@testable import ShotsCore

// Exercises the real native layer (Vision, xattrs, Finder tags). Compiled only when this test
// target depends on ShotsNative; ported from test/helper.integration.test.ts.
#if canImport(ShotsNative)
import ShotsNative

private func run(_ command: String, _ arguments: [String], input: Data? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: command)
    process.arguments = arguments
    let out = Pipe()
    process.standardOutput = out
    if let input {
        let inPipe = Pipe()
        process.standardInput = inPipe
        try process.run()
        inPipe.fileHandleForWriting.write(input)
        try inPipe.fileHandleForWriting.close()
    } else {
        try process.run()
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Writes the same xattrs the screenshot tool does (binary plists, hex-encoded for `xattr -wx`).
private func markAsScreenshot(_ path: String, type: String = "selection") throws {
    // plutil writes binary; go through a temp file so the bytes survive.
    func hex(_ value: String) throws -> String {
        let tmp = Paths.join(NSTemporaryDirectory(), "bplist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let xml = "<?xml version=\"1.0\"?><plist version=\"1.0\">\(value)</plist>"
        try Data(xml.utf8).write(to: URL(filePath: tmp + ".xml"))
        defer { try? FileManager.default.removeItem(atPath: tmp + ".xml") }
        _ = try run("/usr/bin/plutil", ["-convert", "binary1", "-o", tmp, tmp + ".xml"])
        return try Data(contentsOf: URL(filePath: tmp)).map { String(format: "%02x", $0) }.joined()
    }
    _ = try run("/usr/bin/xattr", ["-wx", "com.apple.metadata:kMDItemIsScreenCapture", try hex("<true/>"), path])
    _ = try run("/usr/bin/xattr", ["-wx", "com.apple.metadata:kMDItemScreenCaptureType", try hex("<string>\(type)</string>"), path])
}

struct NativeIntegrationTests {
    let native = SystemNative()

    @Test func visionOCRReadsTheFixtures() async throws {
        let code = try await native.ocr(Fixtures.path("code.png"), languages: [])
        #expect(code.text.contains("loadConfig"))
        #expect(code.width == 1200)
        #expect(code.height == 600)
        let error = try await native.ocr(Fixtures.path("error.png"), languages: [])
        #expect(error.text.contains("Traceback"))
        #expect(try await native.ocr(Fixtures.path("blank.png"), languages: []).text == "")
    }

    @Test func screenshotMetadataComesFromXattrsImmediately() async throws {
        let path = try Fixtures.drop("code.png", into: try tempRoot(), as: "shot.png")
        #expect(try await native.meta(path).isScreenCapture != true)
        try markAsScreenshot(path, type: "window")
        #expect(try await native.meta(path) == ScreenshotMeta(isScreenCapture: true, captureType: "window", source: .xattr))
    }

    @Test func finderTagsLandInUserTagsAndMergeRemoveCorrectly() async throws {
        let path = try Fixtures.drop("code.png", into: try tempRoot(), as: "tagged.png")
        func read() throws -> [String] {
            let hex = try run("/usr/bin/xattr", ["-px", "com.apple.metadata:_kMDItemUserTags", path]).filter { !$0.isWhitespace }
            var bytes = Data()
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                bytes.append(UInt8(hex[index..<next], radix: 16)!)
                index = next
            }
            return try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String] ?? []
        }
        try await native.setTags(path, ["code", "typescript"], remove: [])
        #expect(try read() == ["code\n0", "typescript\n0"])
        try await native.setTags(path, ["design"], remove: ["code"])
        #expect(try read() == ["typescript\n0", "design\n0"])
    }

    @Test func fmStatusReportsAvailabilityAndTheImageInputDecision() async throws {
        let status = try await native.fmStatus()
        #expect(status.osVersion.wholeMatch(of: /\d+\.\d+.*/) != nil)
        let major = Int(status.osVersion.split(separator: ".").first ?? "") ?? 0
        if major < 27 {
            #expect(!status.imageInput.enabled)
            #expect(status.imageInput.reason.contains("macOS 27"))
        }
        if !status.available { #expect(status.reason?.isEmpty == false) }
    }
}
#endif
