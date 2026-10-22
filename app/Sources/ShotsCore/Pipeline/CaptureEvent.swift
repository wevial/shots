/// What happened to a screenshot that just landed, for a "just captured" preview.
///
/// Only a live arrival on its first attempt reports events, the same rule as the clipboard
/// copy, so a startup scan or a retry never pops anything up. A job reports `landed` once it
/// is known to be a screenshot, then exactly one of `filed` or `failed`.
public enum CaptureEvent: Sendable, Equatable {
    /// `path` is the file in the inbox. `copied` is true when it went to the clipboard.
    case landed(jobID: Int64, path: String, copied: Bool)
    case filed(jobID: Int64, shot: ShotRow)
    /// The file stays in the inbox and shows under Failed (it may still be retried).
    case failed(jobID: Int64, error: String)

    public var jobID: Int64 {
        switch self {
        case .landed(let jobID, _, _), .filed(let jobID, _), .failed(let jobID, _): jobID
        }
    }
}
