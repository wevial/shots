import ShotsKit
import SwiftUI

/// Crop, rotate and flip a shot, then save over its file. A sheet on the main window.
struct ImageEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    let shot: Shot

    @State private var edit = ImageEdit()
    /// The file as loaded, downsampled for the screen; nil while loading.
    @State private var source: (image: CGImage, pixelSize: CGSize)?
    @State private var didFailToLoad = false
    /// `source` turned and flipped as `edit` says, without the crop.
    @State private var oriented: CGImage?
    @State private var isSaving = false

    /// Plenty for a sharp preview on a 5K display, without decoding huge images in full.
    private static let previewPixels = 3000

    var body: some View {
        VStack(spacing: 0) {
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
                // A backdrop the image's edges show against, white screenshots included.
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            toolbar
                .padding(12)
        }
        .frame(minWidth: 640, idealWidth: 980, minHeight: 480, idealHeight: 700)
        .task {
            let url = shot.fileURL, maxPixels = Self.previewPixels
            let loaded = await Task.detached { ImageEdit.displayImage(at: url, maxPixelSize: maxPixels) }.value
            source = loaded
            oriented = loaded?.image
            didFailToLoad = loaded == nil
        }
    }

    // MARK: Canvas

    @ViewBuilder
    private var canvas: some View {
        if let oriented, let source {
            Image(decorative: oriented, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                // Never bigger than the screenshot itself.
                .frame(maxWidth: turned(source.pixelSize).width / displayScale, maxHeight: turned(source.pixelSize).height / displayScale)
                .overlay { CropOverlay(crop: $edit.crop) }
                .padding(8) // Room for the handles on the image's edges.
        } else if didFailToLoad {
            ContentUnavailableView("Can't Open Image", systemImage: "photo.badge.exclamationmark")
        } else {
            ProgressView()
        }
    }

    private func turned(_ size: CGSize) -> CGSize {
        edit.swapsAxes ? CGSize(width: size.height, height: size.width) : size
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            tool("Rotate Left", "rotate.left") { $0.rotateCounterclockwise() }
            tool("Rotate Right", "rotate.right") { $0.rotateClockwise() }
            tool("Flip Horizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right") { $0.flipHorizontally() }
            tool("Flip Vertical", "arrow.up.and.down.righttriangle.up.righttriangle.down") { $0.flipVertically() }

            Spacer()

            Button("Reset") { change { $0 = ImageEdit() } }
                .disabled(edit.isIdentity || isSaving)
                .clickable()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .clickable()
            Button("Save", action: save)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(edit.isIdentity || isSaving)
                .clickable()
                // ⌘S saves too. A button has one shortcut, so this one is an invisible twin.
                .background {
                    Button("Save", action: save)
                        .keyboardShortcut("s")
                        .disabled(edit.isIdentity || isSaving)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
        }
        // The size the saved image will have, centered under the canvas.
        .overlay {
            if let source {
                let size = edit.outputSize(for: source.pixelSize)
                Text("\(Int(size.width)) × \(Int(size.height))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.large)
        .disabled(source == nil)
    }

    private func tool(_ title: String, _ systemImage: String, _ apply: @escaping (inout ImageEdit) -> Void) -> some View {
        Button(title, systemImage: systemImage) { change(apply) }
            .labelStyle(.iconOnly)
            .help(title)
            .disabled(isSaving)
            .clickable()
    }

    /// Applies a change, re-turning the preview only when the orientation changed (not the crop).
    private func change(_ apply: (inout ImageEdit) -> Void) {
        let before = edit
        apply(&edit)
        guard edit.quarterTurns != before.quarterTurns || edit.isMirrored != before.isMirrored, let source else { return }
        oriented = edit.oriented(source.image)
    }

    private func save() {
        isSaving = true
        Task {
            await model.save(edit, to: shot)
            // A failure shows the window's error alert, which needs the sheet out of the way.
            dismiss()
        }
    }
}

/// The crop rectangle over the image: drag a corner or edge to resize it, inside it to move
/// it, or anywhere outside it to draw a new one. `crop` is in fractions of the image.
private struct CropOverlay: View {
    @Binding var crop: CGRect
    /// The crop when the current drag began.
    @State private var dragStart: CGRect?

    /// The smallest crop, in points on screen.
    private static let minSide: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let frame = CGRect(
                x: crop.minX * size.width, y: crop.minY * size.height,
                width: crop.width * size.width, height: crop.height * size.height)

            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(frame)
                }
                .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                .contentShape(.rect)
                .gesture(drawGesture(in: size))
                .pointerStyle(.rectSelection)

                Rectangle()
                    .fill(.clear)
                    .contentShape(.rect)
                    .overlay { grid }
                    .overlay {
                        // White with a dark hairline, so the frame shows on light and dark images.
                        Rectangle().strokeBorder(.white, lineWidth: 1.5)
                            .overlay { Rectangle().strokeBorder(.black.opacity(0.35), lineWidth: 0.5) }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .gesture(dragGesture(in: size) { start, dx, dy in
                        start.offsetBy(
                            dx: min(max(dx, -start.minX), 1 - start.maxX),
                            dy: min(max(dy, -start.minY), 1 - start.maxY))
                    })
                    .pointerStyle(dragStart == nil ? .grabIdle : .grabActive)

                ForEach(Handle.allCases, id: \.self) { handle in
                    handle.view
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                        .position(handle.point(in: frame))
                        .gesture(dragGesture(in: size) { start, dx, dy in
                            handle.resize(start, dx: dx, dy: dy, min: Self.minSide / size.width, Self.minSide / size.height)
                        })
                        .pointerStyle(.frameResize(position: handle.position))
                }
            }
        }
    }

    /// Rule-of-thirds lines while dragging.
    @ViewBuilder
    private var grid: some View {
        if dragStart != nil {
            GeometryReader { proxy in
                Path { path in
                    for third in [1.0 / 3, 2.0 / 3] {
                        path.move(to: CGPoint(x: proxy.size.width * third, y: 0))
                        path.addLine(to: CGPoint(x: proxy.size.width * third, y: proxy.size.height))
                        path.move(to: CGPoint(x: 0, y: proxy.size.height * third))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height * third))
                    }
                }
                .stroke(.white.opacity(0.5), lineWidth: 0.5)
            }
        }
    }

    /// A drag that updates the crop from where it was when the drag began, by the distance
    /// moved in fractions of the image.
    private func dragGesture(in size: CGSize, _ update: @escaping (CGRect, CGFloat, CGFloat) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? crop
                dragStart = start
                crop = update(start, value.translation.width / size.width, value.translation.height / size.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Dragging outside the crop draws a new one from that point.
    private func drawGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                dragStart = crop
                func clamp(_ point: CGPoint) -> CGPoint {
                    CGPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
                }
                let a = clamp(value.startLocation), b = clamp(value.location)
                crop = CGRect(
                    x: min(a.x, b.x), y: min(a.y, b.y),
                    width: max(abs(a.x - b.x), Self.minSide / size.width),
                    height: max(abs(a.y - b.y), Self.minSide / size.height)
                ).intersection(ImageEdit.fullFrame)
            }
            .onEnded { _ in dragStart = nil }
    }
}

/// The crop's eight handles: four corners and four edges.
private enum Handle: CaseIterable {
    case topLeading, top, topTrailing, trailing, bottomTrailing, bottom, bottomLeading, leading

    var position: FrameResizePosition {
        switch self {
        case .topLeading: .topLeading
        case .top: .top
        case .topTrailing: .topTrailing
        case .trailing: .trailing
        case .bottomTrailing: .bottomTrailing
        case .bottom: .bottom
        case .bottomLeading: .bottomLeading
        case .leading: .leading
        }
    }

    private var movesLeading: Bool { [.topLeading, .leading, .bottomLeading].contains(self) }
    private var movesTrailing: Bool { [.topTrailing, .trailing, .bottomTrailing].contains(self) }
    private var movesTop: Bool { [.topLeading, .top, .topTrailing].contains(self) }
    private var movesBottom: Bool { [.bottomLeading, .bottom, .bottomTrailing].contains(self) }

    func point(in frame: CGRect) -> CGPoint {
        CGPoint(
            x: movesLeading ? frame.minX : movesTrailing ? frame.maxX : frame.midX,
            y: movesTop ? frame.minY : movesBottom ? frame.maxY : frame.midY)
    }

    /// `start` with this handle's edges moved, kept inside the image and at least `minWidth` × `minHeight`.
    func resize(_ start: CGRect, dx: CGFloat, dy: CGFloat, min minWidth: CGFloat, _ minHeight: CGFloat) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if movesLeading { minX = min(max(start.minX + dx, 0), maxX - minWidth) }
        if movesTrailing { maxX = max(min(start.maxX + dx, 1), minX + minWidth) }
        if movesTop { minY = min(max(start.minY + dy, 0), maxY - minHeight) }
        if movesBottom { maxY = max(min(start.maxY + dy, 1), minY + minHeight) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    @ViewBuilder
    var view: some View {
        let isCorner = (movesLeading || movesTrailing) && (movesTop || movesBottom)
        let isVertical = !isCorner && (movesLeading || movesTrailing)
        if isCorner {
            Circle()
                .fill(.white)
                .frame(width: 11, height: 11)
                .shadow(color: .black.opacity(0.4), radius: 1.5)
        } else {
            Capsule()
                .fill(.white)
                .frame(width: isVertical ? 5 : 20, height: isVertical ? 20 : 5)
                .shadow(color: .black.opacity(0.4), radius: 1.5)
        }
    }
}

#Preview {
    ImageEditorView(shot: .sample)
        .environment(AppModel.preview())
}
