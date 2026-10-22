import Foundation

/// On-device Foundation Models, through `Native.fmClassify`. The native side decides text
/// vs. multimodal at runtime (macOS 27 + vision capability), so this always passes the image.
/// The 4096-token context on macOS 26 is why OCR is clipped hard here.
public struct AppleBackend: Backend {
    public let name = "apple"
    public let isCloud = false
    public var native: any Native
    public var timeout: Duration

    public init(native: any Native, timeout: Duration) {
        self.native = native
        self.timeout = timeout
    }

    public func classify(_ input: ClassifyInput) async -> ClassifyOutcome {
        let response = await ask(input, maxOcrChars: 4000)
        // A context overflow is worth one retry with less OCR.
        guard case .error(let message) = response, message.contains("exceededContextWindowSize") else {
            return outcome(response)
        }
        switch await ask(input, maxOcrChars: 1200) {
        case .ok(let result, let mode): return validated(result, mode: mode)
        case .unavailable(let reason): return .failure(.error, message: reason)
        case .timedOut: return .failure(.error, message: timedOutMessage)
        case .error(let message): return .failure(.error, message: message)
        }
    }

    private func ask(_ input: ClassifyInput, maxOcrChars: Int) async -> FmClassifyResponse {
        await native.fmClassify(
            instructions: Prompt.instructions,
            prompt: Prompt.build(input, maxOcrChars: maxOcrChars),
            imagePath: input.imagePath,
            timeout: timeout
        )
    }

    private func outcome(_ response: FmClassifyResponse) -> ClassifyOutcome {
        switch response {
        case .ok(let result, let mode): validated(result, mode: mode)
        case .unavailable(let reason): .failure(.unavailable, message: reason)
        case .timedOut: .failure(.timeout, message: timedOutMessage)
        case .error(let message): .failure(.error, message: message)
        }
    }

    private var timedOutMessage: String { "apple timed out after \(timeout.milliseconds)ms" }

    /// The model's output goes through the same shape check and normalization as the CLI
    /// backends' replies.
    private func validated(_ raw: ClassifyResult, mode: String) -> ClassifyOutcome {
        switch validateResult(raw.json) {
        case .valid(let result): .success(result, detail: mode)
        case .invalid(let errors): .failure(.invalid, message: errors.joined(separator: "; "))
        }
    }
}
