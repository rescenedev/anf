import Foundation
@testable import anf

/// A reachable-but-empty folder must read as empty, while a folder whose path
/// vanished mid-session (the local stand-in for a dropped network mount) must
/// HOLD its last listing and flag a stall — never blank to a misleading
/// "permission denied". This is the fix for "the network drive is unstable".
func runNetworkStallTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        func pump(_ m: BrowserModel, until: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !until() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        T.group("reachable empty folder is not a stall") {
            let empty = fm.temporaryDirectory.appendingPathComponent("anfempty-\(UUID().uuidString)")
            try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: empty) }
            let m = BrowserModel(start: empty)
            pump(m) { !m.isLoading }
            T.expect(!m.networkStalled, "empty reachable folder is not flagged as a network stall")
            T.expect(!m.accessDenied, "empty reachable folder is not flagged access-denied")
            T.equal(m.fileItems.count, 0, "empty folder shows empty")
        }

        T.group("vanished path holds the listing and flags a stall") {
            let dir = fm.temporaryDirectory.appendingPathComponent("anfstall-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? "x".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            let m = BrowserModel(start: dir)
            pump(m) { m.fileItems.count == 1 }
            T.equal(m.fileItems.count, 1, "file loaded before the drop")
            try? fm.removeItem(at: dir)   // stand-in for the volume going unreachable
            m.reload()
            pump(m) { m.networkStalled }
            T.expect(m.networkStalled, "a vanished path flags a network stall")
            T.equal(m.fileItems.count, 1, "the stall holds the last listing instead of blanking")
            T.expect(!m.accessDenied, "a stall is not surfaced as a permission error")
        }
    }
}
