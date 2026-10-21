import Foundation
import FoundationModels

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

func unavailableReason(_ availability: SystemLanguageModel.Availability) -> String? {
    switch availability {
    case .available: return nil
    case .unavailable(.appleIntelligenceNotEnabled): return "appleIntelligenceNotEnabled"
    case .unavailable(.deviceNotEligible): return "deviceNotEligible"
    case .unavailable(.modelNotReady): return "modelNotReady"
    case .unavailable(let other): return "unavailable(\(other))"
    }
}

/// Image input needs the macOS 27 Attachment API *and* a model that reports the vision capability.
/// Decided at runtime so one binary built against the 27 SDK runs text-only on 26.
func imageInputStatus(_ model: SystemLanguageModel) -> (enabled: Bool, reason: String) {
    if #available(macOS 27.0, *) {
        return model.capabilities.contains(.vision)
            ? (true, "macOS 27+ with vision capability")
            : (false, "model lacks vision capability")
    }
    return (false, "requires macOS 27 (running \(osVersionString()))")
}

func foundationModelStatus() -> [String: Any] {
    let model = SystemLanguageModel.default
    let reason = unavailableReason(model.availability)
    let image = imageInputStatus(model)
    var out: [String: Any] = [
        "osVersion": osVersionString(),
        "available": reason == nil,
        "imageInput": ["enabled": reason == nil && image.enabled, "reason": image.reason],
        "localeSupported": model.supportsLocale(),
    ]
    if let reason { out["reason"] = reason }
    if reason == nil { out["contextSize"] = model.contextSize }
    return out
}

func describe(_ error: Error) -> String {
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

/// stdin: {instructions, prompt, imagePath?, allowImage?}
func classifyWithFoundationModels(_ input: [String: Any]) async {
    let model = SystemLanguageModel.default
    if let reason = unavailableReason(model.availability) {
        emit(["unavailable": reason])
        exit(2)
    }
    guard let instructions = input["instructions"] as? String, let prompt = input["prompt"] as? String else {
        fail("classify: input needs instructions and prompt")
    }
    let allowImage = (input["allowImage"] as? Bool) ?? true
    let imagePath = input["imagePath"] as? String
    let session = LanguageModelSession(model: model, instructions: instructions)
    let options = GenerationOptions(temperature: 0.2)

    do {
        var mode = "text"
        let result: ShotClassification
        if allowImage, let imagePath, imageInputStatus(model).enabled, #available(macOS 27.0, *) {
            mode = "multimodal"
            let url = URL(fileURLWithPath: imagePath)
            result = try await session.respond(generating: ShotClassification.self, options: options) {
                prompt
                Attachment(imageURL: url).label("screenshot")
            }.content
        } else {
            result = try await session.respond(to: prompt, generating: ShotClassification.self, options: options).content
        }
        emit([
            "category": result.category, "tags": result.tags, "title": result.title,
            "confidence": result.confidence, "mode": mode,
        ])
    } catch {
        fail("classify: \(describe(error))")
    }
}
