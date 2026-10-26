import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ShotsKit

/// A 3×2 image with a different pure color in each pixel, so every turn and flip is visible:
///   R G B
///   C M Y
private let source = makeImage(width: 3, rows: [[.red, .green, .blue], [.cyan, .magenta, .yellow]])

private enum Pixel: CaseIterable {
    case red, green, blue, cyan, magenta, yellow

    var rgba: [UInt8] {
        switch self {
        case .red: [255, 0, 0, 255]
        case .green: [0, 255, 0, 255]
        case .blue: [0, 0, 255, 255]
        case .cyan: [0, 255, 255, 255]
        case .magenta: [255, 0, 255, 255]
        case .yellow: [255, 255, 0, 255]
        }
    }
}

private func context(width: Int, height: Int) -> CGContext {
    CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

private func makeImage(width: Int, rows: [[Pixel]]) -> CGImage {
    let ctx = context(width: width, height: rows.count)
    let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
    for (y, row) in rows.enumerated() {
        for (x, pixel) in row.enumerated() {
            for (i, value) in pixel.rgba.enumerated() { bytes[(y * width + x) * 4 + i] = value }
        }
    }
    return ctx.makeImage()!
}

/// The image's pixels, top row first.
private func pixels(_ image: CGImage) -> [[Pixel]] {
    let ctx = context(width: image.width, height: image.height)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return (0..<image.height).map { y in
        (0..<image.width).map { x in
            let rgba = (0..<4).map { bytes[(y * image.width + x) * 4 + $0] }
            return Pixel.allCases.first { $0.rgba == rgba }!
        }
    }
}

private func edited(_ change: (inout ImageEdit) -> Void) -> [[Pixel]] {
    var edit = ImageEdit()
    change(&edit)
    return pixels(edit.apply(to: source)!)
}

struct ImageEditTests {
    @Test func turnsAndFlips() {
        #expect(edited { _ in } == [[.red, .green, .blue], [.cyan, .magenta, .yellow]])
        #expect(edited { $0.rotateClockwise() } == [[.cyan, .red], [.magenta, .green], [.yellow, .blue]])
        #expect(edited { $0.rotateCounterclockwise() } == [[.blue, .yellow], [.green, .magenta], [.red, .cyan]])
        #expect(edited { $0.flipHorizontally() } == [[.blue, .green, .red], [.yellow, .magenta, .cyan]])
        #expect(edited { $0.flipVertically() } == [[.cyan, .magenta, .yellow], [.red, .green, .blue]])
    }

    @Test func flipsActOnTheImageAsItLooksNow() {
        // Turned, then flipped left to right: the turned image mirrored.
        #expect(edited { $0.rotateClockwise(); $0.flipHorizontally() } == [[.red, .cyan], [.green, .magenta], [.blue, .yellow]])
        #expect(edited { $0.rotateClockwise(); $0.flipVertically() } == [[.yellow, .blue], [.magenta, .green], [.cyan, .red]])
    }

    @Test func undoingEveryStepIsTheIdentity() {
        var edit = ImageEdit()
        edit.crop = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let cropped = edit
        for _ in 0..<4 { edit.rotateClockwise() }
        edit.flipHorizontally(); edit.flipHorizontally()
        edit.flipVertically(); edit.flipVertically()
        edit.rotateClockwise(); edit.rotateCounterclockwise()
        #expect(edit.quarterTurns == cropped.quarterTurns && edit.isMirrored == cropped.isMirrored)
        #expect(abs(edit.crop.minX - 0.1) < 1e-9 && abs(edit.crop.minY - 0.2) < 1e-9)
        #expect(abs(edit.crop.width - 0.3) < 1e-9 && abs(edit.crop.height - 0.4) < 1e-9)
    }

    @Test func cropsInPixels() {
        #expect(edited { $0.crop = CGRect(x: 1.0 / 3, y: 0, width: 2.0 / 3, height: 0.5) } == [[.green, .blue]])
        #expect(edited { $0.crop = CGRect(x: 0, y: 0.5, width: 1.0 / 3, height: 0.5) } == [[.cyan]])
    }

    @Test func cropFollowsATurn() {
        // Keep the left column, then turn: it's the top row now.
        #expect(edited {
            $0.crop = CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1)
            $0.rotateClockwise()
        } == [[.cyan, .red]])
        var edit = ImageEdit()
        edit.crop = CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1)
        edit.rotateClockwise()
        #expect(edit.outputSize(for: CGSize(width: 3, height: 2)) == CGSize(width: 2, height: 1))
    }

    @Test func rewritesTheFileKeepingItsTagsAndCreationDate() throws {
        let url = URL.temporaryDirectory.appending(path: "edit-\(UUID().uuidString).png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, source, nil)
        #expect(CGImageDestinationFinalize(destination))
        defer { try? FileManager.default.removeItem(at: url) }
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        try (url as NSURL).setResourceValue(["code", "review"], forKey: .tagNamesKey)

        var edit = ImageEdit()
        edit.rotateClockwise()
        edit.crop = CGRect(x: 0, y: 0, width: 1, height: 2.0 / 3)
        try edit.apply(toFileAt: url)

        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
        #expect(pixels(image) == [[.cyan, .red], [.magenta, .green]])
        let values = try url.resourceValues(forKeys: [.tagNamesKey, .creationDateKey])
        #expect(values.tagNames == ["code", "review"])
        #expect(values.creationDate == created)
    }
}
