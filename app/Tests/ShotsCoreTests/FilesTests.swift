import Foundation
import Testing
@testable import ShotsCore

struct NamingTests {
    private let calendar = Calendar.current

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func stampUsesLocalTime() {
        #expect(Files.stamp(date(2026, 10, 21, 9, 5)) == "2026-10-21_0905")
    }

    @Test func slugTitleIsFilenameSafeAndBounded() {
        #expect(Files.slugTitle("Inbox: admin / “needs you” queue!") == "inbox-admin-needs-you-queue")
        #expect(Files.slugTitle("Café résumé") == "cafe-resume")
        #expect(Files.slugTitle("../../etc/passwd") == "etc-passwd")
        #expect(Files.slugTitle("   ") == "screenshot")
        #expect(Files.slugTitle(String(repeating: "a", count: 200)).count <= 60)
        #expect(Files.slugTitle("東京 タワー") == "東京-タワー")
        #expect(!Files.slugTitle(String(repeating: "ab ", count: 30)).hasSuffix("-"))
    }

    @Test func targetName() {
        #expect(Files.targetName(captured: date(2026, 1, 2, 3, 4), title: "Hello World", ext: ".PNG") == "2026-01-02_0304_hello-world.png")
    }

    @Test func isCandidateIgnoresHiddenTempFilesAndNonImages() {
        #expect(Files.isCandidate("/x/Screenshot 2026.png"))
        #expect(Files.isCandidate("/x/Photo.HEIC"))
        #expect(!Files.isCandidate("/x/.Screenshot 2026.png"))
        #expect(!Files.isCandidate("/x/notes.txt"))
    }
}

struct MovingTests {
    @Test func uniquePathNeverReturnsAnExistingFile() throws {
        let dir = try tempRoot()
        try "1".write(toFile: Paths.join(dir, "a.png"), atomically: true, encoding: .utf8)
        try "2".write(toFile: Paths.join(dir, "a-2.png"), atomically: true, encoding: .utf8)
        #expect(Files.uniquePath(in: dir, name: "a.png") == Paths.join(dir, "a-3.png"))
        #expect(Files.uniquePath(in: dir, name: "a.png", excluding: Paths.join(dir, "a.png")) == Paths.join(dir, "a.png"))
    }

    @Test func safeMoveRefusesToOverwriteAndKeepsTheSource() throws {
        let dir = try tempRoot()
        let src = Paths.join(dir, "src.png"), dest = Paths.join(dir, "dest.png")
        try "src".write(toFile: src, atomically: true, encoding: .utf8)
        try "dest".write(toFile: dest, atomically: true, encoding: .utf8)
        #expect(throws: ShotsError("destination exists: \(dest)")) { try Files.safeMove(from: src, to: dest) }
        #expect(try String(contentsOfFile: src, encoding: .utf8) == "src")
        #expect(try String(contentsOfFile: dest, encoding: .utf8) == "dest")
    }

    @Test func safeMoveCreatesTheTargetFolder() throws {
        let dir = try tempRoot()
        let src = Paths.join(dir, "src.png"), dest = Paths.join(dir, "sub/dir/out.png")
        try "x".write(toFile: src, atomically: true, encoding: .utf8)
        try Files.safeMove(from: src, to: dest)
        #expect(!FileManager.default.fileExists(atPath: src))
        #expect(try String(contentsOfFile: dest, encoding: .utf8) == "x")
    }

    @Test func safeMoveToItselfIsANoOp() throws {
        let dir = try tempRoot()
        let src = Paths.join(dir, "a.png")
        try "x".write(toFile: src, atomically: true, encoding: .utf8)
        try Files.safeMove(from: src, to: src)
        #expect(FileManager.default.fileExists(atPath: src))
    }

    @Test func sha256MatchesShasum() throws {
        let dir = try tempRoot()
        let path = Paths.join(dir, "a.txt")
        try "hello\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(try Files.sha256(path) == "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
    }

    @Test func capturedAtIsTheBirthTime() throws {
        let path = Paths.join(try tempRoot(), "shot.png")
        try Data("x".utf8).write(to: URL(filePath: path))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 3600)], ofItemAtPath: path)
        let captured = try Files.capturedAt(path)
        #expect(abs(captured.timeIntervalSinceNow) < 60) // birth time, not the later mtime
    }
}

struct StableTests {
    @Test func waitsOutAFileThatIsStillGrowing() async throws {
        let path = Paths.join(try tempRoot(), "growing.png")
        try "a".write(toFile: path, atomically: false, encoding: .utf8)
        let writer = Task {
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(15))
                let handle = try FileHandle(forWritingTo: URL(filePath: path))
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("more".utf8))
                try handle.close()
            }
        }
        let info = try await Files.waitForStable(path, options: .init(interval: .milliseconds(40), stableChecks: 2, timeout: .seconds(3)))
        try await writer.value
        #expect(info.size == 1 + 4 * 5)
    }

    @Test func timesOutOnAMissingFile() async throws {
        let path = Paths.join(try tempRoot(), "nope.png")
        await #expect(throws: ShotsError("file never stabilised within 100ms")) {
            try await Files.waitForStable(path, options: .init(interval: .milliseconds(10), timeout: .milliseconds(100)))
        }
    }
}

struct PathsTests {
    @Test func nodeSemantics() {
        #expect(Paths.join("/a/b", "../c") == "/a/c")
        #expect(Paths.join("/a", "b/") == "/a/b/")
        #expect(Paths.resolve("/a/./b/../c/") == "/a/c")
        #expect(Paths.resolve("x", cwd: "/cwd") == "/cwd/x")
        #expect(Paths.extname("a.png") == ".png")
        #expect(Paths.extname(".bashrc") == "")
        #expect(Paths.extname("/x.y/a") == "")
        #expect(Paths.basename("/a/b.png") == "b.png")
        #expect(Paths.dirname("/a/b.png") == "/a")
        #expect(Paths.dirname("/a") == "/")
        #expect(Paths.expandHome("~/x", home: "/Users/me") == "/Users/me/x")
        #expect(Paths.expandHome("~x", home: "/Users/me") == "~x")
    }
}
