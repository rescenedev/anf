import Foundation
@testable import anf

/// A reachable-but-empty folder reads as empty. A NETWORK volume that goes
/// unreachable holds its last listing and flags a stall (the "reconnecting to
/// network drive" card). A LOCAL path that won't list (a deleted folder or the
/// Trash) is NOT a network stall — that false card on the Trash was reported.
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

        T.group("vanished LOCAL path is not a network stall (Trash fix)") {
            // A dropped LOCAL folder (or ~/.Trash that won't list) must NOT show the
            // "reconnecting to network drive" card — that card is only for network
            // volumes. Reported: clicking the Trash falsely showed the reconnect card.
            let dir = fm.temporaryDirectory.appendingPathComponent("anfstall-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? "x".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            let m = BrowserModel(start: dir)
            pump(m) { m.fileItems.count == 1 }
            try? fm.removeItem(at: dir)   // a LOCAL folder vanishes
            m.reload()
            pump(m) { !m.isLoading }
            T.expect(!m.networkStalled, "a vanished LOCAL path is not flagged as a network stall")
        }

        T.group("network-stall decision is gated on a non-local volume") {
            T.expect(BrowserModel.shouldNetworkStall(reachable: false, isLocal: false),
                     "unreachable network volume → stall")
            T.expect(!BrowserModel.shouldNetworkStall(reachable: false, isLocal: true),
                     "unreachable LOCAL path (Trash / deleted folder) → NOT a stall")
            T.expect(!BrowserModel.shouldNetworkStall(reachable: true, isLocal: false),
                     "reachable network volume → not a stall")
            T.expect(!BrowserModel.shouldNetworkStall(reachable: true, isLocal: true),
                     "reachable local → not a stall")
        }
    }
}
