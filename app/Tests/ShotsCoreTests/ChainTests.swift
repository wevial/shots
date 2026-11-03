import Foundation
import Testing
@testable import ShotsCore

private let config = Config.defaults(home: "/tmp/x")
private let input = ClassifyInput(
    imagePath: "/tmp/x.png", ocrText: "const x = 1;", appContext: appContext(), captureType: "selection",
    dimensions: .init(width: 10, height: 10), categories: config.categories
)
private let open = PrivacyVerdict.allowed
private let closed = PrivacyVerdict(cloudAllowed: false, reason: "denylisted app com.1password.1password")

struct ChainTests {
    @Test func stopsAtTheFirstConfidentResult() async throws {
        let a = MockBackend("apple", [ok("code", 0.9)])
        let b = MockBackend("claude-code", [ok("docs", 0.95)], cloud: true)
        let d = try await runChain(input, backends: [a, b], config: config, privacy: open)
        #expect(d.final.category == "code")
        #expect(d.backend == "apple")
        #expect(b.calls.isEmpty)
    }

    @Test func escalatesOnLowConfidenceAndKeepsTheBest() async throws {
        let a = MockBackend("apple", [ok("code", 0.4)])
        let b = MockBackend("claude-code", [ok("errors", 0.8)], cloud: true)
        let d = try await runChain(input, backends: [a, b], config: config, privacy: open)
        #expect(d.backend == "claude-code")
        #expect(!d.review)
        #expect(d.final.category == "errors")
        #expect(d.attempts.map(\.backend) == ["apple", "claude-code"])
    }

    @Test func fallsThroughErrorsUnavailabilityAndTimeouts() async throws {
        let a = MockBackend("apple", [fail(.unavailable, "appleIntelligenceNotEnabled")])
        let b = MockBackend("claude-code", [fail(.timeout)], cloud: true)
        let c = MockBackend("codex", [ok("receipts", 0.7)], cloud: true)
        let d = try await runChain(input, backends: [a, b, c], config: config, privacy: open)
        #expect(d.backend == "codex")
        let kinds = d.attempts.map { attempt -> String in
            if case .failure(let kind, _) = attempt.outcome { return kind.rawValue }
            return "ok"
        }
        #expect(kinds == ["unavailable", "timeout", "ok"])
    }

    @Test func allLowBestWinsButGoesToMiscForReview() async throws {
        let a = MockBackend("apple", [ok("code", 0.3)])
        let b = MockBackend("codex", [ok("design", 0.5)], cloud: true)
        let d = try await runChain(input, backends: [a, b], config: config, privacy: open)
        #expect(d.backend == "codex")
        #expect(d.review)
        #expect(d.suggestedCategory == "design")
        #expect(d.final.category == "misc")
        #expect(d.final.confidence == 0.5)
    }

    @Test func unknownCategoryBecomesMiscAndReviewEvenWhenConfident() async throws {
        let d = try await runChain(input, backends: [MockBackend("apple", [ok("memes", 0.99)])], config: config, privacy: open)
        #expect(d.review)
        #expect(d.suggestedCategory == "memes")
        #expect(d.final.category == "misc")
    }

    @Test func throwsChainErrorWithEveryAttemptWhenNothingSucceeds() async throws {
        let a = MockBackend("apple", [fail(.error, "boom")])
        do {
            _ = try await runChain(input, backends: [a], config: config, privacy: open)
            Issue.record("expected a ChainError")
        } catch {
            #expect(error.message == "all backends failed: apple: error (boom)")
            #expect(error.attempts.count == 1)
        }
        do {
            _ = try await runChain(input, backends: [], config: config, privacy: open)
        } catch {
            #expect(error.message == "all backends failed: no backends configured")
        }
    }

    @Test func aThrowingBackendCountsAsAnErrorNotACrash() async throws {
        let a = MockBackend("apple", steps: [{ _ in throw ShotsError("helper crashed") }])
        let b = MockBackend("codex", [ok("code", 0.9)], cloud: true)
        let d = try await runChain(input, backends: [a, b], config: config, privacy: open)
        #expect(d.backend == "codex")
        #expect(d.attempts[0].outcome == .failure(.error, message: "helper crashed"))
    }

    @Test func confidenceCapForcesEscalationPastAnOverconfidentBackend() async throws {
        let a = MockBackend("apple", [ok("code", 0.9)])
        let b = MockBackend("claude-code", [ok("design", 0.8)], cloud: true)
        var capped = config
        capped.confidenceCap = ["apple": 0.55]
        let d = try await runChain(input, backends: [a, b], config: capped, privacy: open)
        #expect(d.backend == "claude-code")
        #expect(d.attempts[0].outcome.result?.confidence == 0.55)
        #expect(d.attempts[0].outcome == .success(ClassifyResult(category: "code", tags: ["code"], title: "code shot", confidence: 0.55), detail: "capped from 0.9"))
    }

    @Test func decisionJSONIsTheRecatContract() async throws {
        let d = try await runChain(input, backends: [MockBackend("apple", [ok("code", 0.9)])], config: config, privacy: open)
        var json = d.json
        if case .object(var object) = json, case .array(var attempts) = object["attempts"], case .object(var first) = attempts[0] {
            first["ms"] = 0 // timing varies
            attempts[0] = .object(first)
            object["attempts"] = .array(attempts)
            json = .object(object)
        }
        #expect(json.serialized() == #"{"final":{"category":"code","tags":["code"],"title":"code shot","confidence":0.9,"scratch":false},"backend":"apple","review":false,"suggestedCategory":null,"attempts":[{"backend":"apple","ms":0,"outcome":{"ok":true,"result":{"category":"code","tags":["code"],"title":"code shot","confidence":0.9,"scratch":false}}}]}"#)
    }
}

struct PrivacyTests {
    @Test func denylistedShotsNeverReachCloudBackendsAndRulesFillsIn() async throws {
        let apple = MockBackend("apple", [fail(.unavailable, "modelNotReady")])
        let cloud = MockBackend("claude-code", [ok("code", 0.99)], cloud: true)
        let d = try await runChain(input, backends: [apple, cloud], config: config, privacy: closed, rules: RulesBackend(appRules: config.appRules))
        #expect(cloud.calls.isEmpty)
        #expect(d.backend == "rules")
        #expect(d.final.category == "code") // VS Code → code via appRules
        #expect(d.attempts.first { $0.backend == "claude-code" }?.outcome == .failure(.skipped, message: closed.reason!))
    }

    @Test func denylistedWithAppleAvailableUsesAppleOnly() async throws {
        let apple = MockBackend("apple", [ok("finance", 0.8)])
        let cloud = MockBackend("codex", [ok("code", 0.99)], cloud: true)
        let d = try await runChain(input, backends: [apple, cloud], config: config, privacy: closed, rules: RulesBackend(appRules: config.appRules))
        #expect(d.backend == "apple")
        #expect(cloud.calls.isEmpty)
    }

    @Test func privacyVerdictRules() {
        let password = appContext(bundleId: "com.1password.1password", appName: "1Password")
        #expect(!privacyVerdict(config, context: password).cloudAllowed)

        var custom = config
        custom.cloudDenylist = ["Chase"]
        #expect(!privacyVerdict(custom, context: appContext(bundleId: "com.chase", appName: "chase")).cloudAllowed)

        var offline = config
        offline.allowCloud = false
        #expect(privacyVerdict(offline, context: appContext()) == PrivacyVerdict(cloudAllowed: false, reason: "allowCloud=false"))

        var domains = config
        domains.cloudDenylistDomains = ["chase.com"]
        let bank = appContext(bundleId: "com.google.Chrome", appName: "Chrome", url: "https://secure.chase.com/web/auth")
        #expect(privacyVerdict(domains, context: bank) == PrivacyVerdict(cloudAllowed: false, reason: "denylisted domain chase.com"))
        #expect(privacyVerdict(domains, context: appContext(url: "https://notchase.com")).cloudAllowed)
        domains.cloudDenylistDomains = ["*.chase.com"]
        #expect(!privacyVerdict(domains, context: bank).cloudAllowed)

        var strict = config
        strict.cloudWhenAppUnknown = false
        #expect(!privacyVerdict(strict, context: nil).cloudAllowed)
        #expect(privacyVerdict(config, context: nil).cloudAllowed)
    }
}

struct RulesBackendTests {
    private let rules = RulesBackend(appRules: config.appRules)

    private func classify(_ text: String, context: AppContext? = nil) async -> ClassifyResult? {
        var copy = input
        copy.ocrText = text
        copy.appContext = context
        return await rules.classify(copy).result
    }

    @Test func appMappingBeatsKeywords() async {
        let result = await classify("Traceback (most recent call last)", context: appContext())
        #expect(result?.category == "code")
        #expect(result?.confidence == 0.7)
        #expect(result?.tags == ["code"])
        #expect(result?.title == "config.ts — shots")
    }

    @Test func keywordsWhenTheAppIsUnknown() async {
        let result = await classify("Traceback (most recent call last):\nValueError")
        #expect(result?.category == "errors")
        #expect(result?.confidence == 0.5)
        #expect(result?.title == "Traceback (most recent call last):")
    }

    @Test func codeKeywordsMatchAtLineEnds() async {
        #expect(await classify("x = 1;\ny = 2")?.category == "code")
        #expect(await classify("if (a) {\n  b\n}")?.category == "code")
    }

    @Test func wordBoundariesWorkLikeJavaScript() async {
        #expect(await classify("my receipts folder")?.category == "misc") // \breceipt\b doesn't match "receipts"
        #expect(await classify("Your RECEIPT is ready")?.category == "receipts")
    }

    @Test func miscWithLowConfidenceWhenNothingMatches() async {
        let result = await classify("lorem ipsum")
        #expect(result?.category == "misc")
        #expect(result?.confidence == 0.2)
    }
}
