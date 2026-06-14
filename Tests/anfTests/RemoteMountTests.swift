import Foundation
@testable import anf

/// `RemoteMount.isMountPoint` (st_dev vs parent) decides sshfs mount reuse and is
/// the same primitive `FileTransfer.volumeID` relies on. Test the deterministic
/// local cases (a real mount point is environment-dependent, so not asserted).
func runRemoteMountTests() {
    let fm = FileManager.default

    T.group("a regular subdirectory is not a mount point") {
        let dir = fm.temporaryDirectory.appendingPathComponent("anfmount-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        T.expect(!RemoteMount.isMountPoint(dir.path), "subdir shares its parent's device → not a mount")
    }

    T.group("a nonexistent path is not a mount point") {
        T.expect(!RemoteMount.isMountPoint("/no/such/path-\(UUID().uuidString)"), "missing path → false, no crash")
    }

    T.group("volumeID is stable and equal within one volume") {
        let a = fm.temporaryDirectory.appendingPathComponent("v-\(UUID().uuidString)")
        let b = fm.temporaryDirectory.appendingPathComponent("v-\(UUID().uuidString)")
        let ida = FileTransfer.volumeID(of: a)   // nonexistent → resolves to existing ancestor
        let idb = FileTransfer.volumeID(of: b)
        T.expect(ida != nil && ida == idb, "two temp paths share the temp volume's id (ancestor resolution)")
    }
}
