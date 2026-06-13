import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

/// Finds screenshots in a folder so they can be batch-renamed from their
/// contents (OCR/labels via SmartRename). macOS stamps real captures with the
/// Spotlight `kMDItemIsScreenCapture` flag — that's the reliable signal; the
/// locale-specific name prefix ("Screenshot"/"스크린샷"/…) is the fallback when
/// Spotlight hasn't indexed the file.
enum ScreenshotTidy {

    /// Default capture name prefixes (lowercased), incl. Korean and CleanShot.
    static let namePrefixes = ["screenshot", "스크린샷", "스크린 샷", "cleanshot", "scr-", "스크린샷_"]

    static func isScreenshot(_ url: URL) -> Bool {
        guard OCRService.isImage(url) else { return false }
        // Cheap check first: a default capture name is a screenshot outright, so
        // we never pay for a Spotlight query on the common case.
        let lower = url.lastPathComponent.lowercased()
        if namePrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        // Renamed/custom captures: consult the Spotlight flag (slower).
        return screenCaptureFlag(url) ?? false
    }

    /// Spotlight's screen-capture flag, or nil if unavailable/unindexed.
    private static func screenCaptureFlag(_ url: URL) -> Bool? {
        #if canImport(CoreServices)
        guard let item = MDItemCreate(nil, url.path as CFString),
              let raw = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString)
        else { return nil }
        return (raw as? NSNumber)?.boolValue ?? (raw as? Bool)
        #else
        return nil
        #endif
    }

    /// Screenshots in `folder` (non-recursive), newest first by name.
    static func find(in folder: URL) -> [URL] {
        guard let entries = FastDirRead.list(path: folder.path) else { return [] }
        return entries
            .filter { !$0.isDir && !$0.isHidden }
            .map { folder.appendingPathComponent($0.name) }
            .filter { isScreenshot($0) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
