import ShotsCore

/// The classifiers a shot can be filed by.
public enum ClassifierBackend: String, CaseIterable, Identifiable, Sendable {
    case apple
    case claudeCode = "claude-code"
    case codex
    case rules
    /// Set when someone picked the category by hand (`recat --category`).
    case manual

    public var id: String { rawValue }

    /// The backends offered under "Re-run with".
    public static let rerunnable: [ClassifierBackend] = [.apple, .claudeCode, .codex]

    public var displayName: String {
        switch self {
        case .apple: "Apple"
        case .claudeCode: "Claude"
        case .codex: "Codex"
        case .rules: "Rules"
        case .manual: "Manual"
        }
    }

    /// Cloud backends take 5–30 seconds, so the UI can say so.
    public var isCloud: Bool { self == .claudeCode || self == .codex }
}

extension ClassifierBackend {
    /// The chain's name for this backend; nil for `manual`, which isn't a classifier.
    public var backendName: BackendName? { BackendName(rawValue: rawValue) }
}
