import Foundation

/// A failure with a message meant for people: it ends up in the log, a job's `last_error`,
/// or the CLI's `error: …` line.
public struct ShotsError: LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The text to show for any error: the description a `LocalizedError` gives, otherwise
/// whatever the error prints as.
public func errorMessage(_ error: any Error) -> String {
    if let error = error as? LocalizedError, let description = error.errorDescription { return description }
    return String(describing: error)
}
