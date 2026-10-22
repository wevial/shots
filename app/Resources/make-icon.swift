// Renders the app icon: swift app/Resources/make-icon.swift app/Resources
// Writes AppIcon-1024.png and AppIcon.icns (via iconutil). Re-run after changing the drawing.
import AppKit
import SwiftUI

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

/// One screenshot "card": a little window with a title bar and content lines.
struct Card: View {
    var tint: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 34, style: .continuous)
            .fill(.white)
            .overlay(alignment: .top) {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(spacing: 14) {
                        ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                            Circle().fill($0).frame(width: 22, height: 22)
                        }
                    }
                    RoundedRectangle(cornerRadius: 12).fill(tint).frame(height: 120)
                    RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.12)).frame(width: 300, height: 26)
                    RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.08)).frame(width: 220, height: 26)
                }
                .padding(40)
            }
            .frame(width: 470, height: 360)
            .shadow(color: .black.opacity(0.25), radius: 24, y: 14)
    }
}

/// Screenshot-selection corner brackets around the front card.
struct Brackets: View {
    var body: some View {
        let l: CGFloat = 70, w: CGFloat = 16
        ZStack {
            ForEach(0..<4) { i in
                Path { p in
                    p.move(to: CGPoint(x: 0, y: l)); p.addLine(to: .zero); p.addLine(to: CGPoint(x: l, y: 0))
                }
                .stroke(.white, style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
                .frame(width: l, height: l)
                .rotationEffect(.degrees(Double(i) * 90))
                .frame(width: 600, height: 480, alignment: [.topLeading, .topTrailing, .bottomTrailing, .bottomLeading][i])
            }
        }
        .frame(width: 600, height: 480)
    }
}

struct Icon: View {
    var body: some View {
        ZStack {
            // macOS icon grid: an 824 pt body centered on a 1024 canvas.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.98), Color(red: 0.55, green: 0.29, blue: 0.86)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center))
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            Card(tint: Color(red: 0.98, green: 0.62, blue: 0.27)).rotationEffect(.degrees(-9)).offset(x: -34, y: -38)
            Card(tint: Color(red: 0.2, green: 0.78, blue: 0.62)).rotationEffect(.degrees(5)).offset(x: 22, y: 30)
            Brackets().offset(x: 22, y: 30).rotationEffect(.degrees(5))
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func png(_ size: CGFloat) -> Data {
    let renderer = ImageRenderer(content: Icon().frame(width: 1024, height: 1024))
    renderer.scale = size / 1024
    let rep = NSBitmapImageRep(data: renderer.nsImage!.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let fm = FileManager.default
    let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
    try? fm.removeItem(at: iconset)
    try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try! png(CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        try! png(CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    try! png(1024).write(to: URL(fileURLWithPath: "\(outDir)/AppIcon-1024.png"))
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset.path, "-o", "\(outDir)/AppIcon.icns"]
    try! task.run()
    task.waitUntilExit()
    precondition(task.terminationStatus == 0, "iconutil failed")
}
