import CoreGraphics
import Foundation
import QuickLookThumbnailing

/// Makes thumbnails with Quick Look and keeps them in memory.
///
/// The cache key includes the file's modification date, so a file replaced at the same path
/// gets a fresh thumbnail, and a file that `recat` moved is simply a new key.
public final class Thumbnails: Sendable {
    public static let shared = Thumbnails()

    // NSCache is thread-safe and evicts under memory pressure, but isn't marked Sendable.
    private nonisolated(unsafe) let cache = NSCache<NSString, CGImage>()

    public init() {
        cache.countLimit = 600
    }

    /// A thumbnail that fits in `size` points, or nil when the file is missing or unreadable.
    public func image(for url: URL, size: CGSize, scale: CGFloat) async -> CGImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let modified else { return nil } // No modification date means no file.
        let key = "\(url.path)|\(modified.timeIntervalSince1970)|\(Int(size.width))x\(Int(size.height))@\(scale)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = representation.cgImage
        cache.setObject(image, forKey: key)
        return image
    }
}
