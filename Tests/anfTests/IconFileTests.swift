import Foundation
@testable import anf

/// Regression guards for the legacy `Icon\r` custom-folder-icon file:
/// 1. Finder always hides it (Finder-invisible flag), but the bulk-read path
///    only saw dot-prefixes — so anf listed it.
/// 2. Its trailing carriage return made single-line labels two lines tall,
///    shoving the visible "Icon" text out of its row.
func runIconFileTests() {
    T.group("Icon\\r is treated as hidden") {
        T.expect(FileItem.isCustomIconFile("Icon\r"), "exact Icon\\r name is the custom-icon file")
        T.expect(!FileItem.isCustomIconFile("Icon"), "plain 'Icon' is a normal file")
        T.expect(!FileItem.isCustomIconFile("Icon\r2"), "Icon\\r2 is a normal file")

        let sftp = FileItem.remote(url: URL(string: "sftp://h/x/Icon%0D")!,
                                   name: "Icon\r", isDir: false, isSymlink: false,
                                   size: 0, modified: .distantPast)
        T.expect(sftp.isHidden, "remote factory hides Icon\\r")

        let entry = FastDirEntry(name: "Icon\r", isDir: false, isSymlink: false,
                                 isHidden: true, size: 0,
                                 modified: .distantPast, created: .distantPast)
        let local = FileItem.fast(parentPath: "/tmp", entry: entry)
        T.expect(local.isHidden, "bulk-read factory hides Icon\\r")
    }

    T.group("bulk read marks a real Icon\\r file hidden") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anf-iconfile-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.path + "/Icon\r", contents: nil)
        FileManager.default.createFile(atPath: dir.path + "/normal.txt", contents: nil)

        let entries = FastDirRead.list(path: dir.path) ?? []
        let icon = entries.first { $0.name == "Icon\r" }
        let normal = entries.first { $0.name == "normal.txt" }
        T.notNil(icon, "bulk read returns the Icon\\r entry")
        T.expect(icon?.isHidden == true, "Icon\\r entry is flagged hidden")
        T.expect(normal?.isHidden == false, "normal file stays visible")
    }

    T.group("displayName strips control characters for labels") {
        let entry = FastDirEntry(name: "Icon\r", isDir: false, isSymlink: false,
                                 isHidden: true, size: 0,
                                 modified: .distantPast, created: .distantPast)
        let item = FileItem.fast(parentPath: "/tmp", entry: entry)
        T.equal(item.displayName, "Icon", "trailing \\r is stripped from the label text")

        let plain = FastDirEntry(name: "réport 2024.txt", isDir: false, isSymlink: false,
                                 isHidden: false, size: 0,
                                 modified: .distantPast, created: .distantPast)
        T.equal(FileItem.fast(parentPath: "/tmp", entry: plain).displayName, "réport 2024.txt",
                "names without control characters pass through untouched")
    }
}
