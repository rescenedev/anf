import Foundation
@testable import anf

/// Window-state persistence: a pinned (locked) tab and the terminal drawer height
/// must survive a relaunch. Both were dropped before (issue #29) — TabState had no
/// lock field and `terminalHeight` was saved on drag but never put in the State or
/// read back. This test is NON-DESTRUCTIVE: it backs up and restores the real
/// `anf.workspace.v1` UserDefaults key so it can't clobber the user's window state.
func runWorkspacePersistenceTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let key = "anf.workspace.v1"
        let backup = UserDefaults.standard.data(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)   // clean slate for the test
        defer {
            if let backup { UserDefaults.standard.set(backup, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        T.group("a pinned tab and the terminal height survive save → restore (#29)") {
            let dir = fm.temporaryDirectory.appendingPathComponent("anfws-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }

            let ws = WorkspaceModel()
            ws.active.navigate(to: dir)     // currentURL is set synchronously by navigate
            ws.active.toggleLock()          // pin the tab to `dir`
            T.expect(ws.active.isLocked, "tab is pinned before saving")
            ws.terminalHeight = 420
            ws.terminalHeightUserSet = true
            ws.save()

            // A fresh model reads the same key in init → restore.
            let ws2 = WorkspaceModel()
            T.equal(Int(ws2.terminalHeight), 420, "terminal drawer height is restored (was reset to default)")
            T.expect(ws2.terminalHeightUserSet, "the user-set flag is restored")
            guard let restored = ws2.panes.first?.tabs.first else {
                T.expect(false, "a tab was restored"); return
            }
            T.expect(restored.isLocked, "the tab pin is restored (was lost every launch)")
            T.equal(restored.lockedURL?.standardizedFileURL.path, dir.standardizedFileURL.path,
                    "pinned to the right folder")
        }

        T.group("an unpinned tab restores without a lock") {
            let dir = fm.temporaryDirectory.appendingPathComponent("anfws2-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            let ws = WorkspaceModel()
            ws.active.navigate(to: dir)
            ws.save()
            let ws2 = WorkspaceModel()
            T.expect(ws2.panes.first?.tabs.first?.isLocked == false, "no spurious pin on a normal tab")
        }
    }
}
