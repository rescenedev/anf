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

    /// The synthetic ".." row at the top of a folder listing (issue #12). It is a
    /// navigation affordance only: `selectedItems` excludes it, so NO file
    /// operation can ever act on it, and opening it calls `goUp()`.
    let isParentRef: Bool

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

    /// True for any archive anf can offer to extract. Compound extensions
    /// (tar.gz / tar.bz2 / tar.xz / tgz) are matched on the full suffix.
    var isArchive: Bool { ArchiveService.kind(for: url) != nil }

    /// Markdown gets its own rendered preview (headers, lists, code blocks) —
    /// checked BEFORE isPlainTextLike, which also matches .md as plain text.
    var isMarkdown: Bool { ["md", "markdown", "mdown", "mkd"].contains(ext) }

    /// JSON gets jq-style pretty-printed + colorized preview — checked BEFORE
    /// isPlainTextLike, which also matches .json as plain text.
    var isJSON: Bool { ext == "json" || contentType?.conforms(to: .json) == true }

    /// Has a text body the on-device LLM can summarize (documents, markdown,
    /// json, source/plain text). Drives the inspector's summarize button.
    var hasSummarizableText: Bool {
        isExtractableDocument || isPDF || isMarkdown || isJSON || isPlainTextLike
    }

    /// Types Quick Look renders something genuinely useful for. Anything else
    /// that reaches the inspector's fallback gets content-sniffed: text shows in
    /// the text preview, binary shows an instant placeholder — QL never grinds
    /// through an unreadable blob just to draw a "?" page.
    var isQuickLookFriendly: Bool {
        if isDirectory { return true }
        guard let t = contentType else { return false }
        return t.conforms(to: .image) || t.conforms(to: .movie)
            || t.conforms(to: .audiovisualContent) || t.conforms(to: .pdf)
            || t.conforms(to: .rtf) || t.conforms(to: .html)
            || t.conforms(to: .presentation) || t.conforms(to: .spreadsheet)
            || t.conforms(to: .archive) || t.conforms(to: .font)
    }

    /// Content sniff for the unknown-type fallback: a NUL byte in the head is
    /// the classic "this is binary" signal (same heuristic git uses).
    nonisolated static func looksBinary(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 8192) else { return false }
        try? handle.close()
        return head.contains(0)
    }

    /// Compiled/opaque binaries Quick Look can't render anything useful for —
    /// it still grinds through the file just to draw a "?" page. The inspector
    /// shows an instant lightweight placeholder instead, so arrowing past a
    /// 15MB .so never stalls.
    var isOpaqueBinary: Bool {
        if ["so", "dylib", "a", "o", "bin", "dat", "class", "pyc", "wasm",
            "dill", "node"].contains(ext) { return true }
        guard let t = contentType else { return false }
        return t.conforms(to: .unixExecutable) && !isDirectory
    }

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
                 isCloudPlaceholder: Bool, isParentRef: Bool = false) {
        self.url = url; self.name = name; self.isDirectory = isDirectory
        self.isPackage = isPackage; self.isApplication = isApplication
        self.isSymlink = isSymlink; self.isHidden = isHidden; self.size = size
        self.modified = modified; self.created = created; self.contentType = contentType
        self.isCloudPlaceholder = isCloudPlaceholder; self.isParentRef = isParentRef
    }

    /// The synthetic ".." parent row for `dir`. Opening it routes to `goUp()`, so
    /// its URL is only an identity (unique per folder), never acted upon.
    static func parent(of dir: URL) -> FileItem {
        FileItem(url: dir.appendingPathComponent(".."), name: "..", isDirectory: true,
                 isPackage: false, isApplication: false, isSymlink: false, isHidden: false,
                 size: 0, modified: .distantPast, created: .distantPast,
                 contentType: .folder, isCloudPlaceholder: false, isParentRef: true)
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

    /// Minimal keys for the instant first-pass listing (name + folder-ness only).
    /// Building these for tens of thousands of entries is far cheaper than the full
    /// stat (no size/date/UTType), so a huge directory paints immediately.
    static let fastKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
        .localizedNameKey, .nameKey,
    ]

    /// Build a first-paint item straight from a bulk-read entry — no syscall at
    /// all. Packages/apps are treated as plain folders until the full pass refines
    /// them (brief, and only affects bundles).
    /// Directory extensions that are really opaque bundles (open, not browse).
    private static let bundleExts: Set<String> = [
        "app", "bundle", "framework", "kext", "plugin", "rtfd", "xcodeproj",
        "playground", "photoslibrary", "pkg",
    ]
    /// Cache ext → UTType so a folder of thousands of like files resolves once.
    private static let typeCacheLock = NSLock()
    private nonisolated(unsafe) static var typeCache: [String: UTType?] = [:]

    private static func cachedType(forExt ext: String) -> UTType? {
        typeCacheLock.lock(); defer { typeCacheLock.unlock() }
        if let hit = typeCache[ext] { return hit }
        let t = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        typeCache[ext] = t
        return t
    }

    /// Build a fully-populated item straight from a bulk-read entry — no syscall.
    /// `contentType` is derived from the extension (cached), so the whole listing,
    /// including size/date/kind columns, comes from one bulk pass with no stat.
    static func fast(parentPath: String, entry: FastDirEntry) -> FileItem {
        // Build the child URL WITHOUT `appendingPathComponent` (RFC parsing) or a
        // bare `URL(fileURLWithPath:)` (which stats to decide directory-ness) —
        // both cost hundreds of µs each and dominate on huge directories. Passing
        // `isDirectory:` skips the stat; string concat skips the parser.
        let full = parentPath.hasSuffix("/") ? parentPath + entry.name
                                             : parentPath + "/" + entry.name
        let url = URL(fileURLWithPath: full, isDirectory: entry.isDir)
        let ext = (entry.name as NSString).pathExtension.lowercased()
        let isPackage = entry.isDir && bundleExts.contains(ext)
        let type: UTType? = entry.isDir
            ? (isPackage ? UTType(filenameExtension: ext) : .folder)
            : cachedType(forExt: ext)
        return FileItem(
            url: url, name: entry.name, isDirectory: entry.isDir, isPackage: isPackage,
            isApplication: ext == "app", isSymlink: entry.isSymlink, isHidden: entry.isHidden,
            size: entry.size, modified: entry.modified, created: entry.created,
            contentType: type, isCloudPlaceholder: false)
    }

    /// Lightweight item for the first paint. Metadata columns (size/date/kind) fill
    /// in when the full `FileItem(url:)` pass replaces it.
    init?(fastURL url: URL) {
        guard let v = try? url.resourceValues(forKeys: FileItem.fastKeys) else { return nil }
        self.url = url
        self.name = v.localizedName ?? v.name ?? url.lastPathComponent
        self.isDirectory = v.isDirectory ?? false
        self.isPackage = v.isPackage ?? false
        self.isApplication = false
        self.isSymlink = v.isSymbolicLink ?? false
        self.isHidden = v.isHidden ?? false
        self.size = 0
        self.modified = .distantPast
        self.created = .distantPast
        self.contentType = nil
        self.isCloudPlaceholder = false
        self.isParentRef = false
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
        self.isParentRef = false
    }
}
