/// What the sidebar has selected, which decides what the content column shows.
public enum SidebarScope: Hashable, Sendable {
    case all
    case review
    case failed
    case category(String)

    public var title: String {
        switch self {
        case .all: "All Screenshots"
        case .review: "Needs Review"
        case .failed: "Failed"
        case .category(let name): name
        }
    }

    public var systemImage: String {
        switch self {
        case .all: "photo.on.rectangle"
        case .review: "exclamationmark.circle"
        case .failed: "xmark.octagon"
        case .category: "folder"
        }
    }
}

/// Sidebar badge numbers. Read in one go so they stay consistent with each other.
public struct ScopeCounts: Equatable, Sendable {
    public var all: Int
    public var review: Int
    public var failed: Int
    public var byCategory: [String: Int]

    public init(all: Int = 0, review: Int = 0, failed: Int = 0, byCategory: [String: Int] = [:]) {
        self.all = all
        self.review = review
        self.failed = failed
        self.byCategory = byCategory
    }

    public func count(for scope: SidebarScope) -> Int {
        switch scope {
        case .all: all
        case .review: review
        case .failed: failed
        case .category(let name): byCategory[name] ?? 0
        }
    }
}
