import SwiftUI
import UIKit

/// Full-screen interactive crop mask editor.
/// Shows the last captured screenshot; user drags a rectangle to define the
/// area that will be cropped from all future screenshots.
struct CropMaskEditorView: View {
    /// The reference image (last screenshot captured). May be nil if no test
    /// has been run yet.
    let image: UIImage?
    /// Crop rect in image-pixel coordinates. `.zero` means "no crop / full page".
    @Binding var cropRect: CGRect

    @Environment(\.dismiss) private var dismiss

    // View-space selection endpoints (in the GeometryReader coordinate space)
    @State private var selStart: CGPoint = .zero
    @State private var selEnd: CGPoint = .zero
    @State private var isDragging: Bool = false

    // Stored so toolbar action can convert back to image coords without geo
    @State private var geoSize: CGSize = .zero
    @State private var initialized: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let image {
                    GeometryReader { geo in
                        let imgFrame = computeImageFrame(image: image, in: geo.size)

                        ZStack {
                            // Reference screenshot
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: imgFrame.width, height: imgFrame.height)
                                .position(x: imgFrame.midX, y: imgFrame.midY)

                            // Crop selection overlay
                            selectionOverlay(containerSize: geo.size)

                            // "No selection" instruction label
                            if !hasSelection && !isDragging {
                                drawInstruction
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .contentShape(Rectangle())
                        .gesture(dragGesture(imageFrame: imgFrame))
                        .onAppear {
                            geoSize = geo.size
                            if !initialized {
                                initialized = true
                                initFromCropRect(image: image, imageFrame: imgFrame)
                            }
                        }
                        .onChange(of: geo.size) { _, newSize in
                            geoSize = newSize
                        }
                    }
                } else {
                    noImageView
                }

                // HUD bar pinned to the bottom
                VStack {
                    Spacer()
                    hudBar
                }
            }
            .navigationTitle("Mask Crop Region")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color.black.opacity(0.9), for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.cyan)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        commitCrop()
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .foregroundStyle(hasSelection ? Color.cyan : Color.secondary)
                    .disabled(!hasSelection)
                }
            }
        }
    }

    // MARK: - Derived state

    private var hasSelection: Bool {
        selStart != .zero && selEnd != .zero
            && abs(selEnd.x - selStart.x) > 8
            && abs(selEnd.y - selStart.y) > 8
    }

    private var normalizedSelection: CGRect {
        CGRect(
            x: min(selStart.x, selEnd.x),
            y: min(selStart.y, selEnd.y),
            width: abs(selEnd.x - selStart.x),
            height: abs(selEnd.y - selStart.y)
        )
    }

    // MARK: - Coordinate helpers

    private func computeImageFrame(image: UIImage, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let ia = image.size.width / image.size.height
        let ca = size.width / size.height
        let ds: CGSize = ia > ca
            ? CGSize(width: size.width, height: size.width / ia)
            : CGSize(width: size.height * ia, height: size.height)
        return CGRect(
            x: (size.width - ds.width) / 2,
            y: (size.height - ds.height) / 2,
            width: ds.width, height: ds.height
        )
    }

    /// Seeds the view-space selection from an existing crop rect on appear.
    private func initFromCropRect(image: UIImage, imageFrame: CGRect) {
        guard cropRect != .zero, imageFrame.width > 0 else { return }
        let sx = imageFrame.width / image.size.width
        let sy = imageFrame.height / image.size.height
        selStart = CGPoint(x: imageFrame.minX + cropRect.minX * sx,
                           y: imageFrame.minY + cropRect.minY * sy)
        selEnd = CGPoint(x: imageFrame.minX + cropRect.maxX * sx,
                         y: imageFrame.minY + cropRect.maxY * sy)
    }

    /// Converts the current view-space selection into image-pixel coordinates
    /// and writes to the `cropRect` binding.
    private func commitCrop() {
        guard hasSelection, let image else { cropRect = .zero; return }
        let imgFrame = computeImageFrame(image: image, in: geoSize)
        guard imgFrame.width > 0 else { return }
        let sel = normalizedSelection
        let clamped = sel.intersection(imgFrame)
        guard !clamped.isNull else { return }
        let sx = image.size.width / imgFrame.width
        let sy = image.size.height / imgFrame.height
        cropRect = CGRect(
            x: (clamped.minX - imgFrame.minX) * sx,
            y: (clamped.minY - imgFrame.minY) * sy,
            width: clamped.width * sx,
            height: clamped.height * sy
        )
    }

    /// Converts a view-space rect back to image-pixel coords (for the HUD readout).
    private func selectionToImageRect(sel: CGRect, image: UIImage, imageFrame: CGRect) -> CGRect {
        guard imageFrame.width > 0 else { return .zero }
        let clamped = sel.intersection(imageFrame)
        guard !clamped.isNull else { return .zero }
        let sx = image.size.width / imageFrame.width
        let sy = image.size.height / imageFrame.height
        return CGRect(
            x: (clamped.minX - imageFrame.minX) * sx,
            y: (clamped.minY - imageFrame.minY) * sy,
            width: clamped.width * sx,
            height: clamped.height * sy
        )
    }

    // MARK: - Gesture

    private func dragGesture(imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                isDragging = true
                selStart = CGPoint(
                    x: max(imageFrame.minX, min(value.startLocation.x, imageFrame.maxX)),
                    y: max(imageFrame.minY, min(value.startLocation.y, imageFrame.maxY))
                )
                selEnd = CGPoint(
                    x: max(imageFrame.minX, min(value.location.x, imageFrame.maxX)),
                    y: max(imageFrame.minY, min(value.location.y, imageFrame.maxY))
                )
            }
            .onEnded { _ in isDragging = false }
    }

    // MARK: - Selection overlay (high-tech graphics)

    @ViewBuilder
    private func selectionOverlay(containerSize: CGSize) -> some View {
        if hasSelection {
            let sel = normalizedSelection

            // 1. Dark dimming mask with transparent "hole" for the selection
            Rectangle()
                .fill(.black.opacity(0.6))
                .reverseMask {
                    Rectangle()
                        .frame(width: sel.width, height: sel.height)
                        .offset(
                            x: sel.midX - containerSize.width / 2,
                            y: sel.midY - containerSize.height / 2
                        )
                }
                .frame(width: containerSize.width, height: containerSize.height)
                .allowsHitTesting(false)

            // 2. Outer neon glow
            Rectangle()
                .stroke(Color.cyan.opacity(0.35), lineWidth: 8)
                .blur(radius: 5)
                .frame(width: sel.width, height: sel.height)
                .position(x: sel.midX, y: sel.midY)
                .allowsHitTesting(false)

            // 3. Sharp inner border
            Rectangle()
                .stroke(Color.cyan, lineWidth: 1.5)
                .frame(width: sel.width, height: sel.height)
                .position(x: sel.midX, y: sel.midY)
                .allowsHitTesting(false)

            // 4. Rule-of-thirds grid lines
            Canvas { ctx, _ in
                var path = Path()
                for t in [1.0 / 3.0, 2.0 / 3.0] {
                    // vertical
                    path.move(to: CGPoint(x: sel.minX + sel.width * t, y: sel.minY))
                    path.addLine(to: CGPoint(x: sel.minX + sel.width * t, y: sel.maxY))
                    // horizontal
                    path.move(to: CGPoint(x: sel.minX, y: sel.minY + sel.height * t))
                    path.addLine(to: CGPoint(x: sel.maxX, y: sel.minY + sel.height * t))
                }
                ctx.stroke(path, with: .color(.cyan.opacity(0.2)), lineWidth: 0.5)
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .allowsHitTesting(false)

            // 5. Animated scan line (tech HUD effect)
            TimelineView(.animation) { tl in
                let phase = tl.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 2.5) / 2.5
                Canvas { ctx, _ in
                    let y = sel.minY + sel.height * CGFloat(phase)
                    let opacity = sin(CGFloat(phase) * .pi) * 0.65
                    var p = Path()
                    p.move(to: CGPoint(x: sel.minX, y: y))
                    p.addLine(to: CGPoint(x: sel.maxX, y: y))
                    ctx.stroke(p, with: .color(.cyan.opacity(opacity)), lineWidth: 1.5)
                }
                .frame(width: containerSize.width, height: containerSize.height)
            }
            .allowsHitTesting(false)

            // 6. Corner L-handles
            Canvas { ctx, _ in
                let handleLen: CGFloat = 16
                let handleWidth: CGFloat = 2.5
                let corners: [(CGPoint, CGFloat, CGFloat)] = [
                    (sel.origin, 1, 1),
                    (CGPoint(x: sel.maxX, y: sel.minY), -1, 1),
                    (CGPoint(x: sel.minX, y: sel.maxY), 1, -1),
                    (CGPoint(x: sel.maxX, y: sel.maxY), -1, -1),
                ]
                for (pt, xd, yd) in corners {
                    var p = Path()
                    p.move(to: CGPoint(x: pt.x + xd * handleLen, y: pt.y))
                    p.addLine(to: pt)
                    p.addLine(to: CGPoint(x: pt.x, y: pt.y + yd * handleLen))
                    ctx.stroke(p, with: .color(.cyan),
                               style: StrokeStyle(lineWidth: handleWidth, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .allowsHitTesting(false)
        }
    }

    // MARK: - HUD bar

    private var hudBar: some View {
        Group {
            if hasSelection, let image {
                let imgFrame = computeImageFrame(image: image, in: geoSize)
                let imgRect = selectionToImageRect(sel: normalizedSelection, image: image, imageFrame: imgFrame)
                HStack(spacing: 10) {
                    Image(systemName: "viewfinder.rectangular")
                        .font(.caption)
                        .foregroundStyle(.cyan)
                    Text("X:\(Int(imgRect.minX)) Y:\(Int(imgRect.minY))  \(Int(imgRect.width))×\(Int(imgRect.height))")
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.green)
                    Spacer()
                    Button(role: .destructive) {
                        withAnimation(.snappy) { selStart = .zero; selEnd = .zero }
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .clipShape(.rect(cornerRadius: 10))
                .padding(.horizontal)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.dashed").foregroundStyle(.cyan)
                    Text("DRAG TO DRAW CROP MASK")
                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .clipShape(.rect(cornerRadius: 10))
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: - Placeholder views

    private var drawInstruction: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 36))
                .foregroundStyle(.cyan.opacity(0.5))
            Text("DRAG TO DRAW MASK")
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(.cyan.opacity(0.6))
        }
    }

    private var noImageView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.cyan.opacity(0.5))
            Text("NO SCREENSHOT AVAILABLE")
                .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                .foregroundStyle(.cyan.opacity(0.7))
            Text("Run at least one test to capture a reference screenshot.\nThe mask editor uses your last screenshot to define the crop area.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
    }
}

