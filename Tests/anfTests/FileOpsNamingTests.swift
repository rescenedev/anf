import Foundation
@testable import anf

/// Naming/URL-identity coverage for create/duplicate — the exact string-surgery
/// and trailing-slash classes behind #36 and FO-002. All pure FileManager work,
/// trivially testable with temp dirs.
func runFileOpsNamingTests() {
  MainActor.assumeIsolated {
    let fm = FileManager.default

    T.group("uniqueURL collision numbering keeps the extension") {
        let dir = fm.temporaryDirectory.appendingPathComponent("anfuniq-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        // Free name → unchanged.
        T.equal(FileOperations.uniqueURL(for: "a.txt", in: dir).lastPathComponent, "a.txt", "free name unchanged")
        // One collision → "a 2.txt" (not "a.txt 2", not "a 2").
        try? "x".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        T.equal(FileOperations.uniqueURL(for: "a.txt", in: dir).lastPathComponent, "a 2.txt", "ext preserved on collision")
        // Two collisions → "a 3.txt".
        try? "x".write(to: dir.appendingPathComponent("a 2.txt"), atomically: true, encoding: .utf8)
        T.equal(FileOperations.uniqueURL(for: "a.txt", in: dir).lastPathComponent, "a 3.txt", "numbering advances")
        // Extension-less name (e.g. Makefile) → "Makefile 2", no trailing dot (FO-002).
        try? "x".write(to: dir.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        T.equal(FileOperations.uniqueURL(for: "Makefile", in: dir).lastPathComponent, "Makefile 2", "no-ext name, no trailing dot")
    }

    T.group("newFolder collision → 'untitled folder 2'") {
        let dir = fm.temporaryDirectory.appendingPathComponent("anfnf-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let first = FileOperations.newFolder(in: dir)
        T.equal(first?.lastPathComponent, "untitled folder", "first new folder")
        let second = FileOperations.newFolder(in: dir)
        T.equal(second?.lastPathComponent, "untitled folder 2", "second avoids the collision")
        T.expect(second.map { fm.fileExists(atPath: $0.path) } == true, "the second folder really exists on disk")
    }

    T.group("duplicate keeps the extension and numbers copies") {
        let dir = fm.temporaryDirectory.appendingPathComponent("anfdupn-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let src = dir.appendingPathComponent("photo.jpg")
        try? "img".write(to: src, atomically: true, encoding: .utf8)
        guard let item = FileItem(url: src) else { T.expect(false, "FileItem for photo.jpg"); return }
        let c1 = FileOperations.duplicate([item])
        T.equal(c1.first?.lastPathComponent, "photo copy.jpg", "first duplicate is 'photo copy.jpg'")
        let c2 = FileOperations.duplicate([item])
        T.equal(c2.first?.lastPathComponent, "photo copy 2.jpg", "second duplicate is 'photo copy 2.jpg'")
    }

    T.group("created dir URL matches its FastDirRead listing entry by path (#36 root cause)") {
        let dir = fm.temporaryDirectory.appendingPathComponent("anfid-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        guard let created = FileOperations.newFolder(in: dir) else {
            T.expect(false, "folder created"); return
        }
        // The listing path (FastDirRead builds dir URLs WITH a trailing slash;
        // newFolder builds via appendingPathComponent, WITHOUT). They must still
        // compare equal once standardized — that equality is what selectWhenLoaded
        // relies on, and its absence was #36.
        guard let entries = FastDirRead.list(path: dir.path),
              let entry = entries.first(where: { $0.name == "untitled folder" }) else {
            T.expect(false, "FastDirRead saw the new folder"); return
        }
        let listed = FileItem.fast(parentPath: dir.path, entry: entry)
        T.equal(listed.url.standardizedFileURL.path, created.standardizedFileURL.path,
                "created URL and listed URL resolve to the same path")
        T.expect(listed.isBrowsableContainer, "the listed entry is a browsable folder")
    }
  }
}
