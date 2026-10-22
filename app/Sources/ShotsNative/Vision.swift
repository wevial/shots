import AppKit
import ImageIO
import ShotsCore
import Vision

/// Vision OCR. Blocking, so SystemNative calls it from a background queue.
func recognizeText(path: String, languages: [String]) throws -> OcrResult {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ShotsError("ocr: cannot decode image")
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    if languages.isEmpty {
        request.automaticallyDetectsLanguage = true
    } else {
        request.recognitionLanguages = languages
    }
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    // Vision's origin is bottom-left; sort top to bottom, then left to right.
    let lines = (request.results ?? [])
        .sorted { a, b in
            abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01
                ? a.boundingBox.midY > b.boundingBox.midY
                : a.boundingBox.minX < b.boundingBox.minX
        }
        .compactMap { $0.topCandidates(1).first?.string }
    return OcrResult(text: lines.joined(separator: "\n"), width: image.width, height: image.height)
}

@MainActor
func copyImageToPasteboard(path: String) throws {
    guard let image = NSImage(contentsOfFile: path) else { throw ShotsError("clipboard: cannot load image") }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.writeObjects([image]) else { throw ShotsError("clipboard: pasteboard write failed") }
    // NSImage only offers TIFF; many apps (browsers, Slack) paste PNG better, as macOS's own
    // copy-screenshot does.
    if path.lowercased().hasSuffix(".png"), let png = FileManager.default.contents(atPath: path) {
        pasteboard.setData(png, forType: .png)
    }
}
