import SwiftUI
import UIKit

/// TL-8 Crop: a full-screen frame over the clip's current picture with presets, draggable corners,
/// a straighten dial (−45°…+45°) and Reset. The crop is stored as fractions of the oriented source
/// frame and applied before any transform, so keyframed motion later operates on the cropped picture.
struct VECropScreen: View {
    let session: VEEditorSession
    let clip: VEClip
    let source: VEMediaSource
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)   // fractions, y from top
    @State private var straighten: Double = 0
    @State private var preset = "free"
    @State private var dragStartRect: CGRect?

    private let presets: [(String, Double?)] = [("Free", nil), ("9:16", 9.0 / 16), ("16:9", 16.0 / 9), ("1:1", 1), ("4:3", 4.0 / 3), ("3:4", 3.0 / 4)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GeometryReader { geo in
                    let imageRect = fitRect(in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Color.black
                        if let image {
                            Image(uiImage: image).resizable()
                                .frame(width: imageRect.width, height: imageRect.height)
                                .scaleEffect(VELayerMath.coverScale(width: imageRect.width * rect.width, height: imageRect.height * rect.height, degrees: straighten),
                                             anchor: UnitPoint(x: rect.midX, y: rect.midY))
                                .rotationEffect(.degrees(-straighten), anchor: UnitPoint(x: rect.midX, y: rect.midY))
                                .offset(x: imageRect.minX, y: imageRect.minY)
                                .clipped()
                        } else {
                            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        cropOverlay(imageRect: imageRect)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                controls
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        var c = VECrop()
                        c.preset = preset
                        c.rect = VERect(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height)
                        c.straighten = straighten
                        session.setCrop(c)
                        dismiss()
                    }
                }
            }
            .task { await load() }
        }
        .preferredColorScheme(.dark)
    }

    private func load() async {
        rect = clip.crop.rect.cgRect
        straighten = clip.crop.straighten
        preset = clip.crop.preset
        let url = session.document.resolve(source)
        switch source.kind {
        case .video:
            let t = clip.sourceTime(atOffset: max(0, session.playback.currentTime - (session.project.mainStart(of: clip.id) ?? 0)))
            image = await VEMediaService.shared.frame(of: url, at: t, maxPixel: 1600)
        default:
            image = await Task.detached { VEMediaService.downsampledImage(url, maxPixel: 1600) }.value
        }
    }

    /// Where the full (uncropped) picture sits in the available area.
    private func fitRect(in size: CGSize) -> CGRect {
        let s = source.displaySize
        let aspect = CGFloat(max(1, s.width)) / CGFloat(max(1, s.height))
        let inset: CGFloat = 24
        let avail = CGSize(width: size.width - inset * 2, height: size.height - inset * 2)
        var w = avail.width, h = w / aspect
        if h > avail.height { h = avail.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    // MARK: Crop frame

    private func cropOverlay(imageRect: CGRect) -> some View {
        let frame = CGRect(x: imageRect.minX + rect.minX * imageRect.width, y: imageRect.minY + rect.minY * imageRect.height,
                           width: rect.width * imageRect.width, height: rect.height * imageRect.height)
        return ZStack(alignment: .topLeading) {
            // Dim everything outside the crop.
            Path { p in
                p.addRect(CGRect(origin: .zero, size: CGSize(width: imageRect.maxX + imageRect.minX, height: imageRect.maxY + imageRect.minY)))
                p.addRect(frame)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            // Grid + border
            Path { p in
                p.addRect(frame)
                for i in 1...2 {
                    let x = frame.minX + frame.width * CGFloat(i) / 3, y = frame.minY + frame.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: frame.minY)); p.addLine(to: CGPoint(x: x, y: frame.maxY))
                    p.move(to: CGPoint(x: frame.minX, y: y)); p.addLine(to: CGPoint(x: frame.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.9), lineWidth: 1)
            .allowsHitTesting(false)
            // Move gesture on the interior
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .gesture(DragGesture().onChanged { v in
                    if dragStartRect == nil { dragStartRect = rect }
                    guard let s = dragStartRect else { return }
                    var r = s
                    r.origin.x = min(max(0, s.minX + v.translation.width / imageRect.width), 1 - s.width)
                    r.origin.y = min(max(0, s.minY + v.translation.height / imageRect.height), 1 - s.height)
                    rect = r
                }.onEnded { _ in dragStartRect = nil })
            // Corner handles
            ForEach(0..<4, id: \.self) { corner in
                let pt = cornerPoint(corner, frame)
                Circle().fill(Color.white).frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
                    .position(pt)
                    .gesture(DragGesture().onChanged { v in
                        if dragStartRect == nil { dragStartRect = rect }
                        guard let s = dragStartRect else { return }
                        rect = resized(from: s, corner: corner, dx: v.translation.width / imageRect.width, dy: v.translation.height / imageRect.height,
                                       imageAspect: imageRect.width / imageRect.height)
                    }.onEnded { _ in dragStartRect = nil })
            }
        }
    }

    private func cornerPoint(_ i: Int, _ f: CGRect) -> CGPoint {
        switch i {
        case 0: return CGPoint(x: f.minX, y: f.minY)
        case 1: return CGPoint(x: f.maxX, y: f.minY)
        case 2: return CGPoint(x: f.maxX, y: f.maxY)
        default: return CGPoint(x: f.minX, y: f.maxY)
        }
    }

    /// Drag a corner; keeps the preset aspect (in picture pixels) and a 10 % minimum size.
    private func resized(from s: CGRect, corner: Int, dx: CGFloat, dy: CGFloat, imageAspect: CGFloat) -> CGRect {
        var minX = s.minX, minY = s.minY, maxX = s.maxX, maxY = s.maxY
        switch corner {
        case 0: minX += dx; minY += dy
        case 1: maxX += dx; minY += dy
        case 2: maxX += dx; maxY += dy
        default: minX += dx; maxY += dy
        }
        minX = max(0, minX); minY = max(0, minY); maxX = min(1, maxX); maxY = min(1, maxY)
        var w = max(0.1, maxX - minX), h = max(0.1, maxY - minY)
        if let a = presets.first(where: { $0.0.lowercased() == preset })?.1 {
            // Target aspect in fraction space: (w·W)/(h·H) = a  →  w/h = a / imageAspect.
            let target = CGFloat(a) / imageAspect
            if w / h > target { w = h * target } else { h = w / target }
        }
        switch corner {
        case 0: minX = maxX - w; minY = maxY - h
        case 1: maxX = minX + w; minY = maxY - h
        case 2: maxX = minX + w; maxY = minY + h
        default: minX = maxX - w; maxY = minY + h
        }
        // Keep inside the picture.
        if minX < 0 { maxX -= minX; minX = 0 }
        if minY < 0 { maxY -= minY; minY = 0 }
        if maxX > 1 { minX -= maxX - 1; maxX = 1 }
        if maxY > 1 { minY -= maxY - 1; maxY = 1 }
        return CGRect(x: max(0, minX), y: max(0, minY), width: min(1, maxX - minX), height: min(1, maxY - minY))
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Text(String(format: "%+.1f°", straighten)).font(.caption.monospacedDigit()).frame(width: 56)
                Slider(value: $straighten, in: -45...45, step: 0.1)
                Button("Reset") { rect = CGRect(x: 0, y: 0, width: 1, height: 1); straighten = 0; preset = "free" }.font(.caption)
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets.indices, id: \.self) { i in
                        let p = presets[i]
                        let on = preset == p.0.lowercased()
                        Button(p.0) { applyPreset(p.0.lowercased(), aspect: p.1) }
                            .font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 8)
                            .background(on ? Color.accentColor : Color(white: 0.2), in: Capsule()).foregroundStyle(.white)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 12)
    }

    private func applyPreset(_ name: String, aspect: Double?) {
        preset = name
        guard let a = aspect else { return }
        let s = source.displaySize
        let imageAspect = CGFloat(max(1, s.width)) / CGFloat(max(1, s.height))
        let target = CGFloat(a) / imageAspect     // w/h in fraction space
        var w: CGFloat = 1, h: CGFloat = 1
        if target >= 1 { h = 1 / target } else { w = target }
        rect = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }
}
