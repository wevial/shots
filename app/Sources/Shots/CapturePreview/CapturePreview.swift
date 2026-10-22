import Foundation
import Observation
import ShotsKit

/// One screenshot in the "just captured" stack, from the moment it lands until its panel hides.
@MainActor
@Observable
final class CapturePreview: Identifiable {
    enum Phase: Equatable {
        /// Classifying; the file is still in the inbox.
        case filing
        case filed(Shot)
        case failed(String)
    }

    /// The pipeline's job ID.
    let id: Int64
    let inboxPath: String
    /// Whether the pipeline put it on the clipboard.
    let copied: Bool
    var phase: Phase
    /// Set by the panel, which tracks the pointer itself (see `CapturePreviewPanel`).
    var isHovered = false

    init(id: Int64, inboxPath: String, copied: Bool, phase: Phase = .filing, isHovered: Bool = false) {
        self.id = id
        self.inboxPath = inboxPath
        self.copied = copied
        self.phase = phase
        self.isHovered = isHovered
    }

    var shot: Shot? {
        if case .filed(let shot) = phase { shot } else { nil }
    }

    /// Where the file is right now: the inbox until it's filed, then wherever the shot lives
    /// (a category change moves it again).
    var fileURL: URL {
        shot?.fileURL ?? URL(filePath: inboxPath)
    }
}
