import AppKit
import Foundation

// Sample data for SwiftUI previews and tests. The sample images are drawn once into a temp
// folder, so previews show real thumbnails without depending on anyone's ~/Screenshots.

extension Shot {
    public static let samples: [Shot] = {
        let now = Date.now
        return [
            Shot(
                id: 1, path: SampleImages.path("2026-10-21_1816_queued-task-status-panel.png", color: .systemIndigo),
                originalName: "Screenshot 2026-10-21 at 6.16.04\u{202F}PM.png",
                capturedAt: now.addingTimeInterval(-60 * 12), processedAt: now.addingTimeInterval(-60 * 12 + 7),
                appBundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Factory — Queue",
                pageURL: URL(string: "https://example.com/factory/queue"), pageTitle: "Factory — Queue",
                captureType: "selection", width: 1440, height: 900,
                ocrText: "Queued tasks\nworker-3  idle\nworker-4  running  build #812\nRetry failed jobs",
                category: "ui-reference", tags: ["dashboard", "job-queue", "workers"],
                title: "Queued task status panel", confidence: 0.86, backend: "claude-code"
            ),
            Shot(
                id: 2, path: SampleImages.path("2026-10-21_1502_typeerror-in-checkout.png", color: .systemRed),
                originalName: "Screenshot 2026-10-21 at 3.02.11\u{202F}PM.png",
                capturedAt: now.addingTimeInterval(-60 * 60 * 3), processedAt: now.addingTimeInterval(-60 * 60 * 3 + 4),
                appBundleID: "com.apple.Terminal", appName: "Terminal", windowTitle: "bun test — 120×40",
                captureType: "window", width: 1200, height: 760,
                ocrText: "TypeError: Cannot read properties of undefined (reading 'total')\n    at checkout.ts:42:17",
                category: "errors", tags: ["typeerror", "stack-trace", "bun"],
                title: "TypeError in checkout", confidence: 0.93, backend: "apple", isScratch: true
            ),
            Shot(
                id: 3, path: SampleImages.path("2026-10-20_0940_untitled.png", color: .systemOrange),
                originalName: "Screenshot 2026-10-20 at 9.40.55\u{202F}AM.png",
                capturedAt: now.addingTimeInterval(-60 * 60 * 26), processedAt: now.addingTimeInterval(-60 * 60 * 26 + 9),
                appName: "Preview", captureType: "selection", width: 640, height: 480,
                ocrText: "Total 42.00",
                category: "misc", suggestedCategory: "receipts", tags: ["receipt"],
                title: "Possible receipt", confidence: 0.41, backend: "apple", needsReview: true
            ),
            Shot(
                id: 4, path: SampleImages.path("2026-10-18_1730_figma-color-tokens.png", color: .systemTeal),
                originalName: "Screenshot 2026-10-18 at 5.30.02\u{202F}PM.png",
                capturedAt: now.addingTimeInterval(-60 * 60 * 24 * 3), processedAt: now.addingTimeInterval(-60 * 60 * 24 * 3 + 6),
                appBundleID: "com.figma.Desktop", appName: "Figma", windowTitle: "Tokens — Design System",
                captureType: "display", width: 3024, height: 1964,
                ocrText: "Primary / 500  #4F46E5\nSurface / 50  #F8FAFC",
                category: "design", tags: ["figma", "color", "tokens"],
                title: "Figma color tokens", confidence: 0.9, backend: "manual"
            ),
        ]
    }()

    /// A shot whose file was moved away outside the app, for "File missing" states.
    public static let missingFileSample = Shot(
        id: 99, path: "/nonexistent/2026-10-01_1200_gone.png", originalName: "Screenshot 2026-10-01 at 12.00.00\u{202F}PM.png",
        capturedAt: .now.addingTimeInterval(-60 * 60 * 24 * 20), processedAt: .now.addingTimeInterval(-60 * 60 * 24 * 20),
        category: "docs", title: "Moved somewhere else", confidence: 0.7, backend: "codex"
    )

    public static var sample: Shot { samples[0] }
}

extension FailedJob {
    public static let samples: [FailedJob] = [
        FailedJob(
            id: 7, inboxPath: SampleImages.path("Screenshot 2026-10-21 at 11.15.40\u{202F}AM.png", color: .systemGray),
            originalName: "Screenshot 2026-10-21 at 11.15.40\u{202F}AM.png",
            detectedAt: .now.addingTimeInterval(-60 * 50), attempts: 3,
            lastError: "every backend failed: apple: unavailable: model assets not ready; claude-code: timeout after 30000ms",
            updatedAt: .now.addingTimeInterval(-60 * 20)
        ),
    ]
}

extension ShotsConfig {
    public static let sample = ShotsConfig(
        configPath: "~/.config/shots/config.json",
        dbPath: "~/.local/share/shots/shots.db",
        categories: ShotsConfig.defaults.categories,
        categoryHints: ["errors": "an error message, crash, stack trace, failing build"],
        outputRoot: "~/Screenshots",
        inbox: "~/Screenshots/_inbox"
    )
}

extension AppModel {
    /// A model filled with sample data that never touches the index or the CLI.
    public static func preview(scope: SidebarScope = .all, selecting shot: Shot? = nil) -> AppModel {
        let model = AppModel(config: .sample)
        model.shots = Shot.samples.filter { shot in
            switch scope {
            case .all: true
            case .review: shot.needsReview
            case .failed, .deleted: false
            case .cleanup: shot.isScratch
            case .category(let name): shot.category == name
            }
        }
        model.recentShots = Shot.samples
        model.failedJobs = FailedJob.samples
        model.counts = ScopeCounts(
            all: Shot.samples.count,
            review: Shot.samples.filter(\.needsReview).count,
            failed: FailedJob.samples.count,
            cleanup: Shot.samples.filter(\.isScratch).count,
            byCategory: Dictionary(Shot.samples.map { ($0.category, 1) }, uniquingKeysWith: +)
        )
        model.isLoading = false
        // Assigning `scope` normally triggers a reload; there's no store here, so it's a no-op.
        model.scope = scope
        model.selectedShotID = shot?.id
        return model
    }

    /// Marks a shot as having a recat in flight, to preview the spinner.
    public func previewRecategorizing(_ shot: Shot) {
        recategorizing.insert(shot.id)
    }
}

enum SampleImages {
    /// Draws a placeholder "screenshot" in `color` the first time it's asked for.
    static func path(_ name: String, color: NSColor) -> String {
        let url = URL.temporaryDirectory.appending(path: "ShotsSamples", directoryHint: .isDirectory).appending(path: name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return url.path }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let size = NSSize(width: 480, height: 300)
        let image = NSImage(size: size, flipped: true) { rect in
            color.withAlphaComponent(0.25).setFill()
            rect.fill()
            color.setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 28).fill()
            NSColor.white.withAlphaComponent(0.8).setFill()
            for row in 0..<6 {
                NSRect(x: 24, y: 52 + CGFloat(row) * 34, width: rect.width * (row.isMultiple(of: 2) ? 0.7 : 0.5), height: 14).fill()
            }
            return true
        }
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        return url.path
    }
}
