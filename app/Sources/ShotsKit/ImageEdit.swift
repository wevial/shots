import CoreGraphics
import Foundation
import ImageIO
import ShotsCore
import UniformTypeIdentifiers

/// A crop, rotation and flip for one image. The source is mirrored (`isMirrored`), then turned
/// clockwise by `quarterTurns`, then cropped; `crop` is in the turned image's coordinates.
/// The editing methods act on the image as it looks now, so the crop follows a turn or flip.
public struct ImageEdit: Equatable, Sendable {
    /// Clockwise quarter turns, 0–3.
    public private(set) var quarterTurns = 0
    /// Mirrored left to right before turning.
    public private(set) var isMirrored = false
    /// The part to keep, as fractions of the turned image, origin top-left.
    public var crop = ImageEdit.fullFrame

    public static let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)

    public init() {}

    public var isIdentity: Bool { quarterTurns == 0 && !isMirrored && crop == Self.fullFrame }

    /// Whether the turned image is the source on its side.
    public var swapsAxes: Bool { quarterTurns % 2 == 1 }

    public mutating func rotateClockwise() {
        quarterTurns = (quarterTurns + 1) % 4
        crop = CGRect(x: 1 - crop.maxY, y: crop.minX, width: crop.height, height: crop.width)
    }

    public mutating func rotateCounterclockwise() {
        quarterTurns = (quarterTurns + 3) % 4
        crop = CGRect(x: crop.minY, y: 1 - crop.maxX, width: crop.height, height: crop.width)
    }

    public mutating func flipHorizontally() {
        // Mirroring after a turn is the same as mirroring first and turning the other way.
        isMirrored.toggle()
        quarterTurns = (4 - quarterTurns) % 4
        crop.origin.x = 1 - crop.maxX
    }

    public mutating func flipVertically() {
        // A vertical flip is a horizontal one plus a half turn.
        isMirrored.toggle()
        quarterTurns = (6 - quarterTurns) % 4
        crop.origin.y = 1 - crop.maxY
    }

    /// The pixel size of the result for a source of `size`.
    public func outputSize(for size: CGSize) -> CGSize {
        let turned = swapsAxes ? CGSize(width: size.height, height: size.width) : size
        return pixelRect(in: turned).size
    }

    /// `crop` in pixels of an image of `size`, rounded to whole pixels and at least one.
    func pixelRect(in size: CGSize) -> CGRect {
        let minX = (crop.minX * size.width).rounded(), minY = (crop.minY * size.height).rounded()
        let maxX = (crop.maxX * size.width).rounded(), maxY = (crop.maxY * size.height).rounded()
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    // MARK: Rendering

    /// `image` mirrored and turned, without the crop. The image itself when there's nothing to do.
    public func oriented(_ image: CGImage) -> CGImage? {
        guard quarterTurns != 0 || isMirrored else { return image }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let size = swapsAxes ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let space = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none // Quarter turns land exactly on pixels.
        // Applied bottom-up: mirror, then turn (negative is clockwise with y up), then center.
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: -CGFloat(quarterTurns) * .pi / 2)
        if isMirrored { context.scaleBy(x: -1, y: 1) }
        context.draw(image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        return context.makeImage()
    }

    /// The whole edit applied to `image`.
    public func apply(to image: CGImage) -> CGImage? {
        guard let turned = oriented(image) else { return nil }
        guard crop != Self.fullFrame else { return turned }
        return turned.cropping(to: pixelRect(in: CGSize(width: turned.width, height: turned.height)))
    }

    /// The image at `url` the way it's displayed (its orientation tag applied), at most
    /// `maxPixelSize` on its longer side, plus its full size in pixels. For showing it while
    /// editing; nil when it can't be read.
    public static func displayImage(at url: URL, maxPixelSize: Int) -> (image: CGImage, pixelSize: CGSize)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary)
        else { return nil }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return (image, CGSize(width: image.width, height: image.height)) }
        // Orientations 5–8 are on their side.
        let sideways = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
        return (image, sideways ? CGSize(width: height, height: width) : CGSize(width: width, height: height))
    }

    /// Rewrites the image file at `url` with the edit applied, in its own format and keeping
    /// its metadata, Finder tags and creation date. The previous content goes into the file's
    /// version history first (File ▸ Revert To in Preview), so an edit can be undone.
    public func apply(toFileAt url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source)
        else { throw ShotsError("Couldn't read \(url.lastPathComponent).") }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        // Screenshots have no orientation tag. Anything that does is edited as it's displayed.
        let image: CGImage? =
            if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation != 1,
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int {
                CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                ] as CFDictionary)
            } else {
                CGImageSourceCreateImageAtIndex(source, 0, nil)
            }
        guard let image else { throw ShotsError("Couldn't read \(url.lastPathComponent).") }
        guard let edited = apply(to: image) else { throw ShotsError("Couldn't edit \(url.lastPathComponent).") }

        // The pixels are turned already; a stale orientation tag would turn them again.
        properties[kCGImagePropertyOrientation] = nil
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }

        let scratch = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let output = scratch.appending(path: url.lastPathComponent)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
            throw ShotsError("Can't write \(UTType(type as String)?.localizedDescription ?? "this kind of") images.")
        }
        CGImageDestinationAddImage(destination, edited, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ShotsError("Couldn't save \(url.lastPathComponent).") }

        // Best effort: not every volume keeps versions.
        _ = try? NSFileVersion.addOfItem(at: url, withContentsOf: url)
        // Swaps the new file in, keeping the original's creation date and extended attributes.
        _ = try FileManager.default.replaceItemAt(url, withItemAt: output)
    }
}
