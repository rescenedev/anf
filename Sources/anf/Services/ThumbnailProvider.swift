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

    private init() { cache.countLimit = 1024 }

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
        if let image { cache.setObject(image, forKey: k) }
        return image
    }
}
