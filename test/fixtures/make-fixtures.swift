// Regenerates the fixture PNGs: swift test/fixtures/make-fixtures.swift test/fixtures
// Text is rendered large and high-contrast so Vision OCR reads it reliably.
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func render(_ name: String, lines: [String], size: NSSize = NSSize(width: 1200, height: 600), mono: Bool = false) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    let font = mono ? NSFont.monospacedSystemFont(ofSize: 34, weight: .regular) : NSFont.systemFont(ofSize: 38)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    var y = size.height - 80
    for line in lines {
        (line as NSString).draw(at: NSPoint(x: 40, y: y), withAttributes: attrs)
        y -= 56
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}

render("code", lines: [
    "import { readFileSync } from \"node:fs\";",
    "export function loadConfig(path: string) {",
    "  const raw = readFileSync(path, \"utf8\");",
    "  return JSON.parse(raw);",
    "}",
], mono: true)
render("error", lines: [
    "Traceback (most recent call last):",
    "  File \"app.py\", line 12, in <module>",
    "    main()",
    "ValueError: invalid literal for int()",
], mono: true)
render("receipt", lines: [
    "Receipt",
    "Order number 48213",
    "Blue Bottle Coffee",
    "Subtotal $12.50",
    "Amount paid $13.44",
])
render("blank", lines: [], size: NSSize(width: 400, height: 300))
