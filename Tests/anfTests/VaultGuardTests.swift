import Foundation
@testable import anf

/// Data-loss guard primitive (TC-1 / V-002-B): when git status can't be run the
/// tree is treated as unsafe (true), so restore/trash refuse rather than risk an
/// unrecoverable op. A plain non-git folder exercises the "status fails" path.
func runVaultGuardTests() {
    let fm = FileManager.default
    T.group("hasUncommittedChanges treats a non-repo as unsafe") {
        let dir = fm.temporaryDirectory.appendingPathComponent("anfvault-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        // Not a git repo → `git status` fails → must report unsafe (true), never
        // 'clean', so a failed snapshot can't green-light a destructive op.
        T.expect(VaultService.hasUncommittedChanges(at: dir),
                 "non-git folder → unsafe (true), not silently 'clean'")
    }
}
