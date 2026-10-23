// Renders a library of made-up screenshots for demos and README images. Everything shown is
// fictional. Run it through scripts/demo/seed-inbox.sh, which also marks the files as screen
// captures so Shots files them instead of skipping them.
import AppKit
import SwiftUI

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// MARK: - Building blocks

struct WindowChrome<Content: View>: View {
    var title: String
    var dark = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                    Circle().fill($0).frame(width: 12, height: 12)
                }
                Spacer()
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(dark ? .white.opacity(0.7) : .black.opacity(0.6))
                Spacer()
                Color.clear.frame(width: 52, height: 1)
            }
            .padding(.horizontal, 14).frame(height: 36)
            .background(dark ? Color(white: 0.16) : Color(white: 0.94))
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(dark ? Color(white: 0.11) : .white)
    }
}

let mono = Font.system(size: 15, design: .monospaced)

// MARK: - Scenes

struct CodeEditor: View {
    let lines: [(String, Color)] = [
        ("import Foundation", .pink), ("", .white),
        ("/// Groups receipts by month for the budget view.", .gray),
        ("struct MonthlyTotals {", .pink),
        ("    let receipts: [Receipt]", .white), ("", .white),
        ("    func totals() -> [Date: Decimal] {", .white),
        ("        Dictionary(grouping: receipts, by: \\.month)", .cyan),
        ("            .mapValues { $0.reduce(0) { $0 + $1.amount } }", .cyan),
        ("    }", .white), ("}", .pink),
    ]
    var body: some View {
        WindowChrome(title: "MonthlyTotals.swift — Ledger", dark: true) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(1...lines.count, id: \.self) { Text("\($0)").font(mono).foregroundStyle(.gray) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { Text($0.element.0).font(mono).foregroundStyle($0.element.1) }
                }
            }
            .padding(24)
        }
    }
}

struct TerminalError: View {
    var body: some View {
        WindowChrome(title: "zsh — 120×32", dark: true) {
            VStack(alignment: .leading, spacing: 6) {
                Text("$ python3 sync_inventory.py --store north").foregroundStyle(.green)
                Text("Traceback (most recent call last):").foregroundStyle(.white)
                Text("  File \"sync_inventory.py\", line 48, in <module>").foregroundStyle(.white)
                Text("    main(args.store)").foregroundStyle(.white)
                Text("  File \"sync_inventory.py\", line 31, in main").foregroundStyle(.white)
                Text("    qty = int(row[\"quantity\"])").foregroundStyle(.white)
                Text("ValueError: invalid literal for int() with base 10: 'n/a'").foregroundStyle(.red)
                Text("$ ").foregroundStyle(.green)
            }
            .font(mono).padding(24)
        }
    }
}

struct ChatThread: View {
    let messages: [(String, String, Bool)] = [
        ("Maya", "Are we still on for the design review at 3?", false),
        ("You", "Yes! I'll bring the new onboarding flows", true),
        ("Maya", "Perfect. Can you also show the empty states?", false),
        ("You", "On it — sending the Figma link now", true),
    ]
    var body: some View {
        WindowChrome(title: "Maya Chen") {
            VStack(spacing: 14) {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, m in
                    HStack {
                        if m.2 { Spacer() }
                        Text(m.1).font(.system(size: 16)).padding(.horizontal, 14).padding(.vertical, 10)
                            .background(m.2 ? Color.blue : Color(white: 0.92), in: .rect(cornerRadius: 18))
                            .foregroundStyle(m.2 ? .white : .black)
                        if !m.2 { Spacer() }
                    }
                }
            }
            .padding(28)
        }
    }
}

struct Receipt: View {
    var body: some View {
        WindowChrome(title: "Receipt — Mail") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Northwind Coffee Roasters").font(.system(size: 24, weight: .bold))
                Text("Order #48213 · Oct 18").foregroundStyle(.secondary)
                Divider()
                ForEach([("Ethiopia Guji, 340g", "$18.00"), ("Oat latte", "$5.50"), ("Almond croissant", "$4.25")], id: \.0) { row in
                    HStack { Text(row.0); Spacer(); Text(row.1) }.font(.system(size: 16))
                }
                Divider()
                HStack { Text("Total").bold(); Spacer(); Text("$29.62").bold() }.font(.system(size: 18))
                Text("Paid with Visa ending 4242").foregroundStyle(.secondary)
            }
            .padding(32).frame(maxWidth: 520)
        }
    }
}

struct Dashboard: View {
    var body: some View {
        WindowChrome(title: "Acme Analytics") {
            VStack(alignment: .leading, spacing: 18) {
                Text("Weekly overview").font(.system(size: 22, weight: .semibold))
                HStack(spacing: 14) {
                    ForEach([("Active users", "12,480", Color.blue), ("Conversion", "3.8%", .green), ("Churn", "1.2%", .orange)], id: \.0) { card in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(card.0).foregroundStyle(.secondary)
                            Text(card.1).font(.system(size: 28, weight: .bold)).foregroundStyle(card.2)
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(white: 0.96), in: .rect(cornerRadius: 12))
                    }
                }
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach([40, 65, 52, 80, 74, 96, 88], id: \.self) { h in
                        RoundedRectangle(cornerRadius: 6).fill(Color.blue.gradient).frame(height: CGFloat(h) * 2)
                    }
                }
                .frame(height: 200, alignment: .bottom)
            }
            .padding(28)
        }
    }
}

struct BoardingPass: View {
    var body: some View {
        WindowChrome(title: "Wallet") {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("SKYLINE AIR").font(.system(size: 16, weight: .heavy)).foregroundStyle(.white); Spacer(); Text("Boarding pass").foregroundStyle(.white.opacity(0.8)) }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading) { Text("SFO").font(.system(size: 44, weight: .bold)); Text("San Francisco") }
                    Spacer(); Image(systemName: "airplane").font(.system(size: 30)); Spacer()
                    VStack(alignment: .trailing) { Text("JFK").font(.system(size: 44, weight: .bold)); Text("New York") }
                }
                .foregroundStyle(.white)
                HStack(spacing: 32) {
                    ForEach([("Flight", "SK 214"), ("Gate", "B12"), ("Seat", "14A"), ("Boards", "8:05 AM")], id: \.0) { f in
                        VStack(alignment: .leading) { Text(f.0).font(.caption).foregroundStyle(.white.opacity(0.7)); Text(f.1).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white) }
                    }
                }
            }
            .padding(28)
            .background(LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 20))
            .padding(28)
        }
    }
}

struct DocsPage: View {
    var body: some View {
        WindowChrome(title: "Getting started — Fieldnotes Docs") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Getting started").font(.system(size: 30, weight: .bold))
                Text("Fieldnotes syncs your notes across devices. Install the CLI, sign in once, and every folder you add is kept up to date in the background.")
                    .font(.system(size: 17)).foregroundStyle(.secondary)
                Text("Install").font(.system(size: 20, weight: .semibold))
                Text("brew install fieldnotes").font(mono).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.95), in: .rect(cornerRadius: 8))
                Text("Then run fieldnotes init in the folder you want to sync.").font(.system(size: 17))
            }
            .padding(32)
        }
    }
}

struct Palette: View {
    let colors: [(String, Color)] = [("Ink", Color(red: 0.12, green: 0.13, blue: 0.2)), ("Sky", Color(red: 0.36, green: 0.55, blue: 0.98)),
                                     ("Mint", Color(red: 0.35, green: 0.83, blue: 0.67)), ("Coral", Color(red: 0.98, green: 0.47, blue: 0.4)), ("Sand", Color(red: 0.96, green: 0.89, blue: 0.76))]
    var body: some View {
        WindowChrome(title: "Brand palette — Design") {
            VStack(alignment: .leading, spacing: 18) {
                Text("Color tokens").font(.system(size: 24, weight: .bold))
                HStack(spacing: 14) {
                    ForEach(colors, id: \.0) { c in
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 14).fill(c.1).frame(height: 120)
                            Text(c.0).font(.system(size: 15, weight: .semibold))
                        }
                    }
                }
                Text("Aa  Display 48 / Body 17 / Caption 13").font(.system(size: 26, weight: .medium))
            }
            .padding(28)
        }
    }
}

struct Product: View {
    var body: some View {
        WindowChrome(title: "Trail Runner 2 — Outfitters") {
            HStack(spacing: 28) {
                RoundedRectangle(cornerRadius: 18).fill(LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
                    .overlay(Image(systemName: "shoe.fill").font(.system(size: 90)).foregroundStyle(.white))
                    .frame(width: 320)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Trail Runner 2").font(.system(size: 30, weight: .bold))
                    Text("$129.00").font(.system(size: 24, weight: .semibold))
                    Text("Lightweight, grippy, and ready for wet trails.").foregroundStyle(.secondary)
                    Text("Add to cart").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 22).padding(.vertical, 12).background(.black, in: .capsule)
                }
                Spacer()
            }
            .padding(28)
        }
    }
}

struct Budget: View {
    var body: some View {
        WindowChrome(title: "Household budget — Numbers") {
            VStack(alignment: .leading, spacing: 0) {
                Text("October budget").font(.system(size: 22, weight: .bold)).padding(.bottom, 14)
                ForEach([("Category", "Planned", "Spent"), ("Rent", "$2,100", "$2,100"), ("Groceries", "$600", "$482"), ("Transport", "$180", "$212"), ("Fun", "$250", "$190")], id: \.0) { r in
                    HStack { Text(r.0).frame(width: 220, alignment: .leading); Text(r.1).frame(width: 140, alignment: .trailing); Text(r.2).frame(width: 140, alignment: .trailing) }
                        .font(.system(size: 16, weight: r.0 == "Category" ? .semibold : .regular))
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.9)).frame(height: 1) }
                }
            }
            .padding(32)
        }
    }
}

struct SocialPost: View {
    var body: some View {
        WindowChrome(title: "Home — Pixelfed") {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Circle().fill(Color.teal).frame(width: 44, height: 44); VStack(alignment: .leading) { Text("Jordan Lee").bold(); Text("@jordanshoots · 2h").foregroundStyle(.secondary) } }
                Text("Golden hour over the bay last night. Shot on a 35mm, no edits 🌅").font(.system(size: 17))
                RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [.orange, .purple, .indigo], startPoint: .top, endPoint: .bottom)).frame(height: 260)
                HStack(spacing: 24) { Label("1.2k", systemImage: "heart"); Label("84", systemImage: "bubble.right"); Label("Share", systemImage: "square.and.arrow.up") }.foregroundStyle(.secondary)
            }
            .padding(28).frame(maxWidth: 620)
        }
    }
}

struct Landing: View {
    var body: some View {
        WindowChrome(title: "Orbit — Ship faster") {
            VStack(spacing: 18) {
                Text("Ship faster with Orbit").font(.system(size: 40, weight: .heavy))
                Text("Previews for every branch, in seconds.").font(.system(size: 20)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Text("Start free").foregroundStyle(.white).padding(.horizontal, 22).padding(.vertical, 12).background(Color.indigo, in: .capsule)
                    Text("Read the docs").padding(.horizontal, 22).padding(.vertical, 12).overlay(Capsule().strokeBorder(Color.indigo))
                }
                .font(.system(size: 17, weight: .semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LinearGradient(colors: [Color(red: 0.93, green: 0.94, blue: 1), .white], startPoint: .top, endPoint: .bottom))
        }
    }
}

// MARK: - Render

@MainActor func save<V: View>(_ name: String, _ view: V, size: CGSize = CGSize(width: 960, height: 600)) {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
    renderer.scale = 2
    let rep = NSBitmapImageRep(data: renderer.nsImage!.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    save("code-editor", CodeEditor())
    save("terminal-error", TerminalError(), size: CGSize(width: 960, height: 420))
    save("chat", ChatThread(), size: CGSize(width: 720, height: 480))
    save("receipt", Receipt(), size: CGSize(width: 600, height: 520))
    save("dashboard", Dashboard())
    save("boarding-pass", BoardingPass(), size: CGSize(width: 820, height: 380))
    save("docs", DocsPage(), size: CGSize(width: 900, height: 520))
    save("palette", Palette(), size: CGSize(width: 900, height: 400))
    save("product", Product(), size: CGSize(width: 900, height: 440))
    save("budget", Budget(), size: CGSize(width: 640, height: 420))
    save("social-post", SocialPost(), size: CGSize(width: 680, height: 520))
    save("landing", Landing(), size: CGSize(width: 960, height: 520))
}
