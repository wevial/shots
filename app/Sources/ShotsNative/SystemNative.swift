import Foundation
import ShotsCore

/// The real `Native`: macOS services, called in process. Formerly the separate shots-helper binary.
public struct SystemNative: Native {
    public init() {}

    public func meta(_ path: String) async throws -> ScreenshotMeta {
        try await screenshotMeta(path: path)
    }

    public func context() async throws -> AppContext? {
        // An app that doesn't answer AX calls must not hold up filing; the old helper call
        // gave up after 5 s too. The capture itself can't be interrupted, so it's abandoned.
        guard let context = await withDeadline(.seconds(5), captureAppContext) else { throw ShotsError("context timed out") }
        return context
    }

    public func ocr(_ path: String, languages: [String]) async throws -> OcrResult {
        // Vision blocks for a while; keep it off the cooperative pool's few threads.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try recognizeText(path: path, languages: languages) })
            }
        }
    }

    public func fmStatus() async throws -> FmStatus {
        foundationModelStatus()
    }

    public func fmClassify(instructions: String, prompt: String, imagePath: String, timeout: Duration) async -> FmClassifyResponse {
        await classifyWithFoundationModels(instructions: instructions, prompt: prompt, imagePath: imagePath, timeout: timeout)
    }

    public func setTags(_ path: String, _ tags: [String], remove: [String]) async throws {
        try mergeFinderTags(path: path, tags: tags, remove: remove)
    }

    public func copyToClipboard(_ path: String) async throws {
        try await MainActor.run { try copyImageToPasteboard(path: path) }
    }

    public func permissions() async throws -> Permissions {
        currentPermissions()
    }
}
