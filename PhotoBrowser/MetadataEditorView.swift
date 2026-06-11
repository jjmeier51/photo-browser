import SwiftUI
import MapKit
import CoreLocation

/// Edits the capture date and/or GPS location of one or more photos/videos
/// (writes it back into the files). Used from the long-press menu and selection bar.
struct MetadataEditorView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let urls: [URL]

    enum LocationMode: String, CaseIterable, Identifiable { case keep = "Keep", set = "Set", remove = "Remove"; var id: String { rawValue } }

    @State private var changeDate = true
    @State private var date = Date()
    @State private var locationMode: LocationMode = .keep
    @State private var coordinate = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    @State private var saving = false
    @State private var progress: Double = 0

    private var hasVideo: Bool { urls.contains { classify(url: $0, isDirectory: false) == .video } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Capture Date") {
                    Toggle("Change date & time", isOn: $changeDate)
                    if changeDate { DatePicker("Date", selection: $date) }
                }
                Section("Location") {
                    Picker("Location", selection: $locationMode) {
                        ForEach(LocationMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if locationMode == .set {
                        LocationPickerMap(coordinate: $coordinate).frame(height: 240)
                        Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text(urls.count == 1 ? urls[0].lastPathComponent : "Applies to \(urls.count) selected items.")
                        .foregroundStyle(.secondary)
                } footer: {
                    if hasVideo { Text("Videos are re-saved (no quality loss) to update their metadata, which can take a moment.") }
                }
            }
            .navigationTitle("Edit Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(saving || (!changeDate && locationMode == .keep))
                }
            }
            .overlay { if saving { savingOverlay } }
        }
        .presentationDetents([.large])
        .task {
            guard urls.count == 1 else { return }
            let url = urls[0]
            let entry = Entry(url: url, name: url.lastPathComponent,
                              kind: classify(url: url, isDirectory: false), size: 0, modified: Date())
            let info = await MetadataLoader.load(for: entry)
            if let d = info.date { date = d }
            if let c = info.coordinate { coordinate = c }
        }
    }

    private var savingOverlay: some View {
        VStack(spacing: 10) {
            if urls.count > 1 {
                ProgressView(value: progress).progressViewStyle(.linear).frame(width: 200)
            } else {
                ProgressView()
            }
            Text("Saving…").font(.subheadline)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func save() {
        saving = true
        let targets = urls
        let newDate: Date? = changeDate ? date : nil
        let newLocation: CLLocationCoordinate2D? = locationMode == .set ? coordinate : nil
        let remove = locationMode == .remove
        Task {
            _ = await FileActions.applyMetadata(date: newDate, location: newLocation, removeLocation: remove, to: targets) { p in
                Task { @MainActor in progress = p }
            }
            library.contentDidChange()       // reload folder, dates, ages
            saving = false
            dismiss()
        }
    }
}

/// A map with a fixed center marker; the visible center is the chosen coordinate.
private struct LocationPickerMap: View {
    @Binding var coordinate: CLLocationCoordinate2D
    @State private var position: MapCameraPosition

    init(coordinate: Binding<CLLocationCoordinate2D>) {
        _coordinate = coordinate
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: coordinate.wrappedValue,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))))
    }

    var body: some View {
        Map(position: $position)
            .overlay {
                Image(systemName: "mappin")
                    .font(.title).foregroundStyle(.red)
                    .shadow(radius: 2)
                    .offset(y: -11)            // pin tip sits on the center
            }
            .onMapCameraChange(frequency: .continuous) { context in
                coordinate = context.region.center
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
