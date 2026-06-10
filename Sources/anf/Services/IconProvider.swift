import AppKit
import UniformTypeIdentifiers

/// System icons, cached aggressively. Generic file types share one cached icon
/// (keyed by UTType / extension) so a folder of 5,000 `.swift` files only hits
/// the workspace once. Bundles/apps are resolved per-path for their custom icon.
@MainActor
final class IconProvider {
    static let shared = IconProvider()
    private let cache = NSCache<NSString, NSImage>()
    private let workspace = NSWorkspace.shared

    private init() { cache.countLimit = 2048 }

    func icon(for item: FileItem) -> NSImage {
        let key: NSString
        if item.isApplication || item.isPackage || item.isSymlink {
            key = item.url.path as NSString          // unique per bundle
        } else if item.isBrowsableContainer {
            key = "dir" as NSString                   // every folder shares one icon
        } else if let t = item.contentType {
            key = ("ut:" + t.identifier) as NSString  // one per content type
        } else {
            key = ("ext:" + item.ext) as NSString
        }

        if let hit = cache.object(forKey: key) { return hit }

        let image: NSImage
        if item.isApplication || item.isPackage || item.isSymlink {
            image = workspace.icon(forFile: item.url.path)
        } else if let t = item.contentType {
            image = workspace.icon(for: t)
        } else if item.isBrowsableContainer {
            image = workspace.icon(for: .folder)
        } else {
            image = workspace.icon(for: .data)
        }
        image.size = NSSize(width: 128, height: 128)
        cache.setObject(image, forKey: key)
        return image
    }
}
