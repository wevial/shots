import Foundation
import Testing
@testable import ShotsCore

struct ExecTests {
    @Test func collectsOutputAndExitCode() async {
        let res = await Exec.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(res == RunResult(code: 3, stdout: "out\n", stderr: "err\n", timedOut: false))
    }

    @Test func passesStdinAndCwd() async {
        let res = await Exec.run("/bin/sh", ["-c", "pwd -P; cat"], cwd: "/private/tmp", stdin: "hello")
        #expect(res.stdout == "/private/tmp\nhello")
    }

    /// The child exits at once but leaves a grandchild holding stdout. Node waited for the
    /// pipes ("close") with its timer still armed; so must we, or this never returns.
    @Test func timeoutStillKillsAGrandchildHoldingThePipe() async {
        let start = ContinuousClock.now
        let res = await Exec.run("/bin/sh", ["-c", "sleep 30 & echo started"], timeout: .milliseconds(400))
        #expect(res.timedOut)
        #expect(res.stdout == "started\n")
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func missingBinaryHasNoCode() async {
        let res = await Exec.run("/nonexistent/tool", [])
        #expect(res.code == nil)
        #expect(!res.timedOut)
    }
}
