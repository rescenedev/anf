import Foundation
@testable import anf

func runFastDirReadTests() {
    T.group("FastDirRead") {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("anftest-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            try "hello".write(to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try "x".write(to: dir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)

            guard let entries = FastDirRead.list(path: dir.path) else {
                T.expect(false, "list returned non-nil"); return
            }
            let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
            T.equal(byName.count, 3, "reads 3 entries (no . / ..)")
            T.equal(byName["file.txt"]?.isDir, false, "file is not dir")
            T.equal(byName["file.txt"]?.size, 5, "file size = 5")
            T.equal(byName["sub"]?.isDir, true, "sub is dir")
            T.equal(byName[".hidden"]?.isHidden, true, "dotfile is hidden")
            T.expect(!entries.contains { $0.name == "." || $0.name == ".." }, "no . or ..")
        } catch { T.expect(false, "temp dir setup threw: \(error)") }

        T.isNil(FastDirRead.list(path: "/no/such/path/anf-\(UUID().uuidString)"), "missing dir → nil")
    }
}
