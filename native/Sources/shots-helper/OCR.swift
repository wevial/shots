import AppKit
import ImageIO
import Vision

func recognizeText(path: String, languages: [String]) throws -> [String: Any] {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw NSError(domain: "shots", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot decode image"])
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
    let observations = request.results ?? []
    // Vision's origin is bottom-left; sort top-to-bottom, then left-to-right, to keep reading order.
    let lines = observations
        .sorted { a, b in
            abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 ? a.boundingBox.midY > b.boundingBox.midY : a.boundingBox.minX < b.boundingBox.minX
        }
        .compactMap { $0.topCandidates(1).first?.string }
    return ["text": lines.joined(separator: "\n"), "width": image.width, "height": image.height, "lineCount": lines.count]
}

func copyImageToClipboard(path: String) throws -> [String: Any] {
    guard let image = NSImage(contentsOfFile: path) else {
        throw NSError(domain: "shots", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot load image"])
    }
    let pb = NSPasteboard.general
    pb.clearContents()
    guard pb.writeObjects([image]) else {
        throw NSError(domain: "shots", code: 2, userInfo: [NSLocalizedDescriptionKey: "pasteboard write failed"])
    }
    return ["copied": true]
}
