// The geocoder for Safe Finder's Location filter (mac/places.py) — names places exactly as the Photo Browser app
// does on the iPhone (`MetadataLoader.geocodeBins` / `shortLabel` / `searchText`): CLGeocoder, one request every
// 1.2 s so a run never trips its limit, 4 s each at most; "Hauppauge, NY" in the US, "City, UK", otherwise
// "City, Country". Only coordinates go to Apple's geocoder (as from the iPhone), and only when the Location
// filter is opened. Its own helper, so nothing here can keep video_helper (frames, upscales) from building.
// Built once with `swiftc` into ~/Library/Caches/PhotoBrowser/.
//
//   geocode_helper     reads "<lat> <lng>" lines on stdin; for each prints "ok\t<label>\t<search>",
//                      "none" (the geocoder has no name for it) or "error <why>" (try again later)
import CoreLocation
import Foundation

func say(_ line: String) {
    print(line)
    fflush(stdout)
}

/// "City, ST" in the US ("Hauppauge, NY"), "City, UK", otherwise "City, Country" — `MetadataLoader.shortLabel`.
func shortLabel(_ p: CLPlacemark) -> String {
    let city = p.locality ?? p.subAdministrativeArea ?? p.administrativeArea ?? p.country ?? ""
    let region: String
    switch p.isoCountryCode {
    case "US": region = p.administrativeArea ?? "USA"
    case "GB": region = "UK"
    case "AE": region = "UAE"
    default:   region = p.country ?? ""
    }
    if city.isEmpty { return region }
    if region.isEmpty || region == city { return city }
    return "\(city), \(region)"
}

/// Everything the placemark names, for search ("hauppauge, ny, united states") — `MetadataLoader.searchText`.
func searchText(_ p: CLPlacemark) -> String {
    [p.locality, p.administrativeArea, p.country].compactMap { $0 }.joined(separator: ", ")
}

/// One place's names. Awaited, never waited for: the geocoder answers on the main queue, which the async main's
/// run loop only serves while this is suspended.
@MainActor
func reverseName(_ lat: Double, _ lng: Double) async -> String {
    let c = CLLocationCoordinate2D(latitude: lat, longitude: lng)
    // An invalid coordinate crashes CoreLocation (CLAUDE.md #5): never ask about one.
    guard lat.isFinite, lng.isFinite, CLLocationCoordinate2DIsValid(c), !(lat == 0 && lng == 0) else { return "none" }
    let geocoder = CLGeocoder()
    let timer = Task { @MainActor in                       // 4 s at most, as the iPhone's withTimeout(4)
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        if !Task.isCancelled { geocoder.cancelGeocode() }
    }
    defer { timer.cancel() }
    do {
        let marks = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lng))
        guard let p = marks.first else { return "none" }
        let label = shortLabel(p).replacingOccurrences(of: "\t", with: " ")
        return "ok\t\(label)\t\(searchText(p).lowercased().replacingOccurrences(of: "\t", with: " "))"
    } catch let e as CLError where e.code == .geocodeFoundNoResult || e.code == .geocodeFoundPartialResult {
        return "none"
    } catch let e as CLError where e.code == .geocodeCanceled {
        return "error timed out"
    } catch {
        return "error \(error.localizedDescription)"
    }
}

@MainActor
func geocodeLines() async -> Int32 {
    var first = true
    while let line = readLine() {
        let parts = line.split(separator: " ")
        guard parts.count == 2, let lat = Double(parts[0]), let lng = Double(parts[1]) else {
            say("error not a place")
            continue
        }
        if !first {                                        // one every 1.2 s: under the geocoder's limit
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
        first = false
        say(await reverseName(lat, lng))
    }
    return 0
}

@main
struct GeocodeHelper {
    static func main() async {
        exit(await geocodeLines())
    }
}
