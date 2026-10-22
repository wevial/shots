import ShotsKit
import SwiftUI

/// One row of the command palette: what it shows and what choosing it does.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var systemImage: String
    var tint: Color?
    /// Shown on the right, e.g. "⌘C" or "Space". Only for shortcuts that work outside the palette.
    var shortcut: String?
    /// A screenshot result shows its thumbnail and category instead of an icon and shortcut.
    var screenshot: (url: URL, category: String)?
    let run: @MainActor () -> Void
}

/// A titled group of commands, e.g. "Go to".
struct PaletteSection: Identifiable {
    let id: String
    let title: String
    var commands: [PaletteCommand]
}

extension [PaletteSection] {
    /// Keeps the commands whose title fuzzy-matches `query`, best first within each section,
    /// and puts the section with the best match on top so the first row is the likeliest pick.
    /// An empty query keeps everything in its original order.
    func matching(_ query: String) -> [PaletteSection] {
        let ranked = compactMap { section -> (section: PaletteSection, best: Int)? in
            let matches = FuzzyMatch.filter(section.commands, query: query, title: \.title)
            guard let best = matches.first?.score else { return nil }
            var section = section
            section.commands = matches.map(\.item)
            return (section, best)
        }
        // A stable sort, so sections with equal scores (all of them, for an empty query) keep their order.
        return ranked.enumerated()
            .sorted { $0.element.best != $1.element.best ? $0.element.best > $1.element.best : $0.offset < $1.offset }
            .map(\.element.section)
    }
}
