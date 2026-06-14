import Foundation
import ImageIO
import CoreLocation

/// Find photos by WHERE they were taken. A photo's GPS is read locally from its
/// EXIF (no network); turning a place name like "파리" into coordinates needs one
/// reverse lookup, so this is OPT-IN ("locationSearch": true in the ⌘, settings
/// file). With it off, nothing here runs and the telemetry-0 promise holds.
enum GeoSearch {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "anf.locationSearch") }

    /// ~25 km — generous enough that "Paris" catches the whole metro area.
    static let radiusMeters: CLLocationDistance = 25_000

    /// Local EXIF GPS for an image, or nil.
    static func coordinate(of url: URL) -> CLLocation? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
        return CLLocation(latitude: latRef == "S" ? -lat : lat,
                          longitude: lonRef == "W" ? -lon : lon)
    }

    /// Forward-geocode a place name → coordinate (the one network call), cached.
    private nonisolated(unsafe) static var cache: [String: CLLocation] = [:]
    private static let cacheLock = NSLock()

    static func place(_ query: String) async -> CLLocation? {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        cacheLock.lock(); let hit = cache[key]; cacheLock.unlock()
        if let hit { return hit }
        guard let placemarks = try? await CLGeocoder().geocodeAddressString(query),
              let loc = placemarks.first?.location else { return nil }
        cacheLock.lock(); cache[key] = loc; cacheLock.unlock()
        return loc
    }

    /// Images under `root` taken within `radiusMeters` of the named place. Empty
    /// when location search is off or the place can't be resolved.
    static func imagesNear(place query: String, root: URL, cap: Int) async -> [URL] {
        guard enabled, let target = await place(query) else { return [] }
        let radius = radiusMeters
        // The EXIF scan is CPU/IO — keep it off the (main-actor) caller.
        return await Task.detached(priority: .utility) {
            let files = PaletteSearch.imageFiles(under: root, limit: 4000)
            var hits: [URL] = []
            for url in files {
                guard let loc = coordinate(of: url) else { continue }
                if loc.distance(from: target) <= radius {
                    hits.append(url)
                    if hits.count >= cap { break }
                }
            }
            return hits
        }.value
    }
}
