import SwiftUI
import UIKit

/// "Change Size" — resize a photo by **percentage** or to exact **pixel dimensions** (always
/// aspect-preserving), saved in place at high quality (Lanczos) with the original's metadata kept. Handles
/// both down- and up-scaling. The pixel fields stay locked to the image's proportions.
struct ChangeSizeView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let entry: Entry

    @State private var original: (width: Int, height: Int)?
    @State private var mode: Mode = .percent
    @State private var percent: Double = 100
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var busy = false
    @FocusState private var focus: Field?

    enum Mode: String, CaseIterable, Identifiable { case percent = "Percentage", pixels = "Pixels"; var id: String { rawValue } }
    enum Field { case width, height }

    private var aspect: Double {
        guard let o = original, o.height > 0 else { return 1 }
        return Double(o.width) / Double(o.height)
    }

    /// Target dimensions from the current inputs (aspect-preserving).
    private var target: (w: Int, h: Int)? {
        guard let o = original else { return nil }
        switch mode {
        case .percent:
            let f = max(1, percent) / 100
            return (max(1, Int((Double(o.width) * f).rounded())), max(1, Int((Double(o.height) * f).rounded())))
        case .pixels:
            let w = Int(widthText) ?? 0, h = Int(heightText) ?? 0
            guard w > 0 || h > 0 else { return nil }
            if w > 0 { return (w, max(1, Int((Double(w) / aspect).rounded()))) }
            return (max(1, Int((Double(h) * aspect).rounded())), h)
        }
    }

    private var unchanged: Bool { target?.w == original?.width && target?.h == original?.height }

    var body: some View {
        NavigationStack {
            Form {
                if let o = original {
                    Section("Original") {
                        LabeledContent("Dimensions", value: "\(o.width) × \(o.height) px")
                    }

                    Section {
                        Picker("Resize by", selection: $mode) {
                            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    if mode == .percent {
                        Section {
                            HStack {
                                Text("Scale"); Spacer()
                                Text("\(Int(percent))%").monospacedDigit().foregroundStyle(.secondary)
                            }
                            Slider(value: $percent, in: 10...400, step: 1)
                            HStack {
                                ForEach([25, 50, 100, 200], id: \.self) { p in
                                    Button("\(p)%") { percent = Double(p) }.buttonStyle(.bordered).font(.caption)
                                }
                            }
                        }
                    } else {
                        Section {
                            HStack {
                                Text("Width"); Spacer()
                                TextField("px", text: $widthText)
                                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 100)
                                    .focused($focus, equals: .width)
                                    .onChange(of: widthText) { if focus == .width { syncFromWidth() } }
                            }
                            HStack {
                                Text("Height"); Spacer()
                                TextField("px", text: $heightText)
                                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 100)
                                    .focused($focus, equals: .height)
                                    .onChange(of: heightText) { if focus == .height { syncFromHeight() } }
                            }
                        } footer: {
                            Text("Width and height stay proportional to the original.")
                        }
                    }

                    if let t = target {
                        Section("New size") {
                            LabeledContent("Dimensions", value: "\(t.w) × \(t.h) px")
                            if t.w > o.width {
                                Text("Enlarging past the original size won't add real detail.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("Couldn't read this image's size.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Change Size")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(busy)
            .task { load() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() }
                    else { Button("Resize") { resize() }.disabled(target == nil || unchanged) }
                }
            }
        }
    }

    private func load() {
        original = MediaEditing.pixelSize(of: entry.url)
        if let o = original { widthText = String(o.width); heightText = String(o.height) }
    }
    private func syncFromWidth() {
        guard aspect > 0, let w = Int(widthText), w > 0 else { return }
        heightText = String(max(1, Int((Double(w) / aspect).rounded())))
    }
    private func syncFromHeight() {
        guard let h = Int(heightText), h > 0 else { return }
        widthText = String(max(1, Int((Double(h) * aspect).rounded())))
    }

    private func resize() {
        guard let t = target else { return }
        busy = true
        let url = entry.url
        Task.detached(priority: .userInitiated) {
            let ok = MediaEditing.resizePhotoInPlace(url: url, targetWidth: t.w, targetHeight: t.h)
            await MainActor.run {
                busy = false
                if ok { library.contentDidChange() }
                dismiss()
            }
        }
    }
}
