import AppKit
import QuickLookThumbnailing

/// Rich Quick Look thumbnails for images/movies/pdf, generated asynchronously and
/// cached by (path + size bucket). Views ask once per appearance; the icon shows
/// instantly and the real thumbnail fades in when ready.
@MainActor
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()
    private let cache = NSCache<NSString, NSImage>()
    private let generator = QLThumbnailGenerator.shared

    private init() {
        // Count alone is not a memory bound — 1,024 retina thumbnails at 168pt
        // can exceed 400MB. Cost-account by bitmap bytes and cap the total.
        cache.countLimit = 1_024
        cache.totalCostLimit = 64 * 1024 * 1024   // 64 MB of pixels
    }

    private static func cost(of image: NSImage) -> Int {
        Int(image.size.width * image.size.height) * 4 * 4   // RGBA × ~2x scale²
    }

    /// Bounds concurrent QL generation. Scrolling an image-heavy folder used to
    /// fire one `generateBestRepresentation` PER visible cell with no ceiling —
    /// hundreds in flight, none cancelled as they scrolled off. A small pool
    /// keeps the generator (and CPU/IO) from being flooded; off-screen cells
    /// just wait their turn or get superseded by `currentID` on arrival.
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrent = 6

    private func acquire() async {
        if running < maxConcurrent { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
        running += 1
    }
    private func release() {
        running -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    private func key(_ url: URL, _ side: CGFloat) -> NSString {
        "\(url.path)@\(Int(side))" as NSString
    }

    func cached(for item: FileItem, side: CGFloat) -> NSImage? {
        cache.object(forKey: key(item.url, side))
    }

    /// Returns a thumbnail, generating it if needed. `nil` means "use the icon".
    func thumbnail(for item: FileItem, side: CGFloat) async -> NSImage? {
        guard item.supportsThumbnail else { return nil }
        let k = key(item.url, side)
        if let hit = cache.object(forKey: k) { return hit }

        await acquire()
        defer { release() }
        // Re-check the cache: while we waited for a slot another request for the
        // same file may have finished.
        if let hit = cache.object(forKey: k) { return hit }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail
        )

        let image: NSImage? = await withCheckedContinuation { cont in
            generator.generateBestRepresentation(for: req) { rep, _ in
                cont.resume(returning: rep?.nsImage)
            }
        }
        if let image { cache.setObject(image, forKey: k, cost: Self.cost(of: image)) }
        return image
    }
}
