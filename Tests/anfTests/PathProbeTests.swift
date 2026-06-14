import Foundation
@testable import anf

/// `PathProbe` backs network-stall detection (N-004/N-006 era). The timeout-bounded
/// probes must answer correctly for the local cases.
func runPathProbeTests() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("anfprobe-\(UUID().uuidString)")
    let file = dir.appendingPathComponent("f.txt")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try? "x".write(to: file, atomically: true, encoding: .utf8)
    defer { try? fm.removeItem(at: dir) }
    let missing = dir.appendingPathComponent("nope-\(UUID().uuidString)")

    T.group("isDirectory (stat-based)") {
        T.expect(PathProbe.isDirectory(dir.path), "existing dir → true")
        T.expect(!PathProbe.isDirectory(file.path), "a file is not a directory")
        T.expect(!PathProbe.isDirectory(missing.path), "missing path → false")
    }

    T.group("canListDirectory (opendir-based)") {
        T.expect(PathProbe.canListDirectory(dir.path), "existing dir is listable")
        T.expect(!PathProbe.canListDirectory(file.path), "a file can't be opendir'd")
        T.expect(!PathProbe.canListDirectory(missing.path), "missing path → false")
    }
}
