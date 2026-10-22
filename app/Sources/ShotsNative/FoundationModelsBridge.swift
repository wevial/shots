import Foundation
import FoundationModels
import ShotsCore

@Generable
struct ShotClassification {
    @Guide(description: "Exactly one category name copied from the allowed list")
    var category: String
    @Guide(description: "Up to 5 short lowercase tags describing the content", .maximumCount(5))
    var tags: [String]
    @Guide(description: "Short descriptive title, 3 to 8 words, no punctuation")
    var title: String
    @Guide(description: "0.9+ only if the content unmistakably fits one category; 0.5-0.7 if two categories could fit; below 0.5 if guessing", .range(0...1))
    var confidence: Double
}

func osVersionString() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}

private func unavailableReason(_ availability: SystemLanguageModel.Availability) -> String? {
    switch availability {
    case .available: return nil
    case .unavailable(.appleIntelligenceNotEnabled): return "appleIntelligenceNotEnabled"
    case .unavailable(.deviceNotEligible): return "deviceNotEligible"
    case .unavailable(.modelNotReady): return "modelNotReady"
    case .unavailable(let other): return "unavailable(\(other))"
    }
}

/// Image input needs the macOS 27 Attachment API *and* a model that reports the vision
/// capability. Decided at runtime so one binary built against the 27 SDK runs text-only on 26.
private func imageInputStatus(_ model: SystemLanguageModel) -> (enabled: Bool, reason: String) {
    if #available(macOS 27.0, *) {
        return model.capabilities.contains(.vision)
            ? (true, "macOS 27+ with vision capability")
            : (false, "model lacks vision capability")
    }
    return (false, "requires macOS 27 (running \(osVersionString()))")
}

func foundationModelStatus() -> FmStatus {
    let model = SystemLanguageModel.default
    let reason = unavailableReason(model.availability)
    let image = imageInputStatus(model)
    return FmStatus(
        osVersion: osVersionString(), available: reason == nil, reason: reason,
        imageInput: .init(enabled: reason == nil && image.enabled, reason: image.reason),
        contextSize: reason == nil ? model.contextSize : nil,
        localeSupported: model.supportsLocale())
}

/// Error names the apple backend matches on (`exceededContextWindowSize` triggers its retry).
private func describe(_ error: Error) -> String {
    if let e = error as? LanguageModelSession.GenerationError {
        switch e {
        case .exceededContextWindowSize: return "exceededContextWindowSize"
        case .guardrailViolation: return "guardrailViolation"
        case .unsupportedLanguageOrLocale: return "unsupportedLanguageOrLocale"
        case .assetsUnavailable: return "assetsUnavailable"
        case .decodingFailure: return "decodingFailure"
        case .rateLimited: return "rateLimited"
        case .concurrentRequests: return "concurrentRequests"
        case .refusal: return "refusal"
        case .unsupportedGuide: return "unsupportedGuide"
        @unknown default: return "\(e)"
        }
    }
    return "\(error)"
}

private func generate(instructions: String, prompt: String, imagePath: String) async throws -> (ShotClassification, mode: String) {
    let model = SystemLanguageModel.default
    let session = LanguageModelSession(model: model, instructions: instructions)
    let options = GenerationOptions(temperature: 0.2)
    if imageInputStatus(model).enabled, #available(macOS 27.0, *) {
        let url = URL(fileURLWithPath: imagePath)
        let content = try await session.respond(generating: ShotClassification.self, options: options) {
            prompt
            Attachment(imageURL: url).label("screenshot")
        }.content
        return (content, "multimodal")
    }
    let content = try await session.respond(to: prompt, generating: ShotClassification.self, options: options).content
    return (content, "text")
}

func classifyWithFoundationModels(instructions: String, prompt: String, imagePath: String, timeout: Duration) async -> FmClassifyResponse {
    if let reason = unavailableReason(SystemLanguageModel.default.availability) {
        return .unavailable(reason: reason)
    }
    // shots-helper was killed at the timeout; here the request is cancelled and abandoned,
    // so a model that ignores cancellation can't hold up the job.
    let response = await withDeadline(timeout) { () -> FmClassifyResponse in
        do {
            let (result, mode) = try await generate(instructions: instructions, prompt: prompt, imagePath: imagePath)
            return .ok(
                ClassifyResult(category: result.category, tags: result.tags, title: result.title, confidence: result.confidence),
                mode: mode)
        } catch is CancellationError {
            return .timedOut
        } catch {
            return .error(message: "classify: \(describe(error))")
        }
    }
    return response ?? .timedOut
}
