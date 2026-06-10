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

    /// ZIP+XML office documents whose body text anf can extract and preview as
    /// text (hwpx/docx/pptx/xlsx) — no QuickLook generator needed.
    var isExtractableDocument: Bool { ["hwpx", "docx", "pptx", "xlsx"].contains(ext) }

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

    /// Designated memberwise init (used by the remote/SFTP factory).
    private init(url: URL, name: String, isDirectory: Bool, isPackage: Bool,
                 isApplication: Bool, isSymlink: Bool, isHidden: Bool, size: Int64,
                 modified: Date, created: Date, contentType: UTType?,
                 isCloudPlaceholder: Bool) {
        self.url = url; self.name = name; self.isDirectory = isDirectory
        self.isPackage = isPackage; self.isApplication = isApplication
        self.isSymlink = isSymlink; self.isHidden = isHidden; self.size = size
        self.modified = modified; self.created = created; self.contentType = contentType
        self.isCloudPlaceholder = isCloudPlaceholder
    }

    /// Build an item from a remote SFTP listing. `url` is the synthetic
    /// `sftp://host/abs/path` address; type is inferred from the extension.
    static func remote(url: URL, name: String, isDir: Bool, isSymlink: Bool,
                       size: Int64, modified: Date) -> FileItem {
        let type: UTType? = isDir ? .folder
            : UTType(filenameExtension: (name as NSString).pathExtension.lowercased())
        return FileItem(
            url: url, name: name, isDirectory: isDir, isPackage: false,
            isApplication: false, isSymlink: isSymlink, isHidden: name.hasPrefix("."),
            size: size, modified: modified, created: modified,
            contentType: type, isCloudPlaceholder: false)
    }

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
