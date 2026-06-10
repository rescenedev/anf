import Foundation
import UniformTypeIdentifiers

/// Immutable snapshot of a single file-system entry.
/// Sendable so it can be produced on a background task and handed to the main actor.
struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isApplication: Bool
    let isSymlink: Bool
    let isHidden: Bool
    let size: Int64
    let modified: Date
    let created: Date
    let contentType: UTType?
    /// An iCloud item whose content is not on disk yet (dataless placeholder).
    let isCloudPlaceholder: Bool

    var id: URL { url }

    /// A folder the user navigates *into* (not a bundle/app that opens).
    var isBrowsableContainer: Bool { isDirectory && !isPackage && !isApplication }

    var ext: String { url.pathExtension.lowercased() }

    var isImage: Bool { contentType?.conforms(to: .image) ?? false }
    var isMovie: Bool { contentType?.conforms(to: .movie) ?? false }
    var isPDF: Bool { contentType?.conforms(to: .pdf) ?? false }

    /// Scripts/source/plain text — previewed with our own readable text view
    /// (Quick Look renders these tiny). Rich text formats stay on Quick Look.
    var isPlainTextLike: Bool {
        guard let t = contentType else { return false }
        if t.conforms(to: .html) || t.conforms(to: .rtf) { return false }
        return t.conforms(to: .plainText) || t.conforms(to: .sourceCode)
            || t.conforms(to: .shellScript) || t.conforms(to: .yaml)
            || t.conforms(to: .json) || t.conforms(to: .xml)
    }

    /// Files Quick Look can render a rich thumbnail for. Everything else uses the system icon.
    var supportsThumbnail: Bool {
        guard let t = contentType else { return false }
        return t.conforms(to: .image) || t.conforms(to: .movie)
            || t.conforms(to: .pdf) || t.conforms(to: .audiovisualContent)
            || t.conforms(to: .presentation)
    }

    static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .isApplicationKey, .isSymbolicLinkKey,
        .isHiddenKey, .fileSizeKey, .totalFileAllocatedSizeKey,
        .contentModificationDateKey, .creationDateKey,
        .localizedNameKey, .contentTypeKey, .nameKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
    ]

    init?(url: URL) {
        guard let v = try? url.resourceValues(forKeys: FileItem.resourceKeys) else { return nil }
        self.url = url
        self.name = v.localizedName ?? v.name ?? url.lastPathComponent
        self.isDirectory = v.isDirectory ?? false
        self.isPackage = v.isPackage ?? false
        self.isApplication = v.isApplication ?? false
        self.isSymlink = v.isSymbolicLink ?? false
        self.isHidden = v.isHidden ?? false
        // Logical size first: dataless iCloud placeholders report 0 allocated
        // bytes even though the file's real size is known.
        self.size = Int64(v.fileSize ?? v.totalFileAllocatedSize ?? 0)
        self.modified = v.contentModificationDate ?? .distantPast
        self.created = v.creationDate ?? .distantPast
        self.contentType = v.contentType
        self.isCloudPlaceholder = (v.isUbiquitousItem ?? false)
            && v.ubiquitousItemDownloadingStatus == .notDownloaded
    }
}
