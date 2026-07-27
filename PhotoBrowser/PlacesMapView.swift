import SwiftUI
import MapKit
import CoreLocation

/// A map of every geotagged photo under a folder (recursive). Photos collapse into ~1 km GPS bins —
/// the same bins the location index uses — so a whole event becomes one pin with a count instead of
/// thousands of overlapping markers. Tapping a pin opens that location's photos in the viewer.
///
/// Coordinates come from `MetadataLoader.gpsBin`: cached from the "Index Locations" pass, and read on
/// demand (ImageIO only, off the main actor, bounded 8-wide) for anything not yet indexed — the same
/// approach `Library.buildLocationIndex` uses, so this reuses proven, non-blocking I/O and only the
/// resulting annotations touch the main actor.
struct PlacesMapView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let root: URL

    @State private var pins: [PlacePin] = []
    @State private var loading = true
    @State private var scanned = 0
    @State private var total = 0
    @State private var position: MapCameraPosition = .automatic
    @State private var viewer: ViewerPresentation?

    /// One ~1 km GPS bin: a coordinate plus the photos taken there.
    struct PlacePin: Identifiable {
        let id: String                 // the bin key "lat|lng"
        let coordinate: CLLocationCoordinate2D
        let items: [Entry]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $position) {
                    ForEach(pins) { pin in
                        Annotation(pin.items.first?.name ?? "", coordinate: pin.coordinate) {
                            Button { open(pin) } label: { pinLabel(pin.items.count) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat))
                .ignoresSafeArea(edges: .bottom)

                if loading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(total > 0 ? "Reading photo locations… \(scanned)/\(total)"
                                       : "Finding geotagged photos…")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                } else if pins.isEmpty {
                    ContentUnavailableView("No Places", systemImage: "mappin.slash",
                        description: Text("No geotagged photos found under “\(root.lastPathComponent)”. Photos need GPS data (location) in their metadata."))
                }
            }
            .navigationTitle("Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .fullScreenCover(item: $viewer) { p in
                ViewerView(items: p.items, startIndex: p.startIndex)
                    .environment(library)
            }
            .task { await load() }
        }
    }

    /// A circular count badge used as the map pin.
    private func pinLabel(_ count: Int) -> some View {
        ZStack {
            Circle().fill(.tint)
            Circle().strokeBorder(.white, lineWidth: 2)
            Text("\(count)").font(.caption.bold()).foregroundStyle(.white)
        }
        .frame(width: 36, height: 36)
        .shadow(radius: 3)
    }

    private func open(_ pin: PlacePin) {
        Haptics.light()
        viewer = ViewerPresentation(items: pin.items, startIndex: 0)
    }

    /// Enumerate the subtree, read each image's GPS bin concurrently, group by bin, and build pins.
    private func load() async {
        let images = await Library.enumerateAll(root).filter { $0.kind == .image }
        total = images.count
        guard !images.isEmpty else { loading = false; return }

        var byBin: [String: [Entry]] = [:]
        var i = 0, done = 0
        await withTaskGroup(of: (Entry, String).self) { group in
            func addNext() {
                guard i < images.count else { return }
                let e = images[i]; i += 1
                group.addTask { (e, await MetadataLoader.gpsBin(for: e)) }
            }
            for _ in 0..<min(8, images.count) { addNext() }
            while let (e, bin) = await group.next() {
                done += 1
                if !bin.isEmpty { byBin[bin, default: []].append(e) }
                if done % 25 == 0 { scanned = done }        // throttle UI updates
                addNext()
            }
        }
        scanned = done

        var built: [PlacePin] = []
        for (bin, items) in byBin {
            let parts = bin.split(separator: "|")
            guard parts.count == 2, let lat = Double(parts[0]), let lng = Double(parts[1]) else { continue }
            let c = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            guard CLLocationCoordinate2DIsValid(c) else { continue }
            built.append(PlacePin(id: bin, coordinate: c,
                                  items: items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }))
        }
        pins = built.sorted { $0.items.count > $1.items.count }
        if !built.isEmpty { position = .region(regionThatFits(built.map(\.coordinate))) }
        loading = false
    }

    /// A region that frames all pins with a little padding.
    private func regionThatFits(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coords.first else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                      span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60))
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLng = first.longitude, maxLng = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLng = min(minLng, c.longitude); maxLng = max(maxLng, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.02, (maxLat - minLat) * 1.4),
                                    longitudeDelta: max(0.02, (maxLng - minLng) * 1.4))
        return MKCoordinateRegion(center: center, span: span)
    }
}
