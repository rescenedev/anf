import Foundation
@testable import anf

func runSafetyTests() {
    MainActor.assumeIsolated {
        T.group("UpdateChecker.isNewer") {
            T.expect(UpdateChecker.isNewer("1.1", than: "1.0"), "1.1 > 1.0")
            T.expect(UpdateChecker.isNewer("1.10.0", than: "1.9"), "numeric not lexicographic")
            T.expect(!UpdateChecker.isNewer("1.0", than: "1.0"), "equal is not newer")
            T.expect(!UpdateChecker.isNewer("0.9.9", than: "1.0"), "older is not newer")
            // Manual "Check for Updates…" (#38) relies on the same comparison to
            // decide between the update banner and the "up to date" alert.
            T.expect(UpdateChecker.isNewer("1.5.17", than: "1.5.16"), "patch bump is newer (#38)")
            T.expect(!UpdateChecker.isNewer("1.5.17", than: "1.5.17"), "same patch → up to date (#38)")
            T.expect(!UpdateChecker.currentVersion.isEmpty, "currentVersion resolves (#38)")
        }

        T.group("FileUndo move round-trip") {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("anfundo-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: dir) }
                let a = dir.appendingPathComponent("a.txt")
                let b = dir.appendingPathComponent("b.txt")
                try "x".write(to: a, atomically: true, encoding: .utf8)
                try fm.moveItem(at: a, to: b)
                FileUndo.shared.record(.move([(from: a, to: b)]))

                T.expect(FileUndo.shared.undo(), "undo reports success")
                T.expect(fm.fileExists(atPath: a.path), "undo restored original name")
                T.expect(!fm.fileExists(atPath: b.path), "renamed file gone after undo")

                T.expect(FileUndo.shared.redo(), "redo reports success")
                T.expect(fm.fileExists(atPath: b.path), "redo re-applied the move")
            } catch { T.expect(false, "setup threw: \(error)") }
        }
    }
}
