import Foundation
@testable import anf

/// Issue #42 (P1, FileOps): rename edge cases (folder / conflict / no-op),
/// the move self-drop filter, cross-directory move undo, the headless keep-both
/// conflict default, and naturalKey's leading-zero / clamp edges. All fixtures
/// live in a throwaway temp tree; the shared undo stack is drained of exactly
/// the records these groups push.
func runFileOpsEdgeTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("anffoe-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        func pump(until: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !until() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        T.group("rename: a folder renames from a trailing-slash URL; conflict and no-op stay put") {
            let alpha = root.appendingPathComponent("alpha")
            let beta = root.appendingPathComponent("beta")
            for d in [alpha, beta] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
            // Directory URLs from listings carry a trailing slash — the rename
            // destination must land as a SIBLING, not inside the folder itself.
            guard let item = FileItem(url: URL(fileURLWithPath: alpha.path, isDirectory: true)) else {
                T.expect(false, "FileItem for the folder fixture"); return
            }
            let renamed = FileOperations.rename(item, to: "gamma")
            T.equal(renamed?.lastPathComponent, "gamma", "rename returns the new URL")
            T.expect(fm.fileExists(atPath: root.appendingPathComponent("gamma").path),
                     "the folder now lives at parent/gamma (not alpha/gamma)")
            T.expect(!fm.fileExists(atPath: alpha.path), "the old name is gone")

            guard let gamma = FileItem(url: root.appendingPathComponent("gamma")) else {
                T.expect(false, "FileItem for gamma"); return
            }
            T.isNil(FileOperations.rename(gamma, to: "beta"),
                    "renaming ONTO an existing sibling fails instead of clobbering it")
            T.expect(fm.fileExists(atPath: root.appendingPathComponent("gamma").path),
                     "the source survives the failed conflict rename")
            T.isNil(FileOperations.rename(gamma, to: "gamma"), "same name → no-op, no undo record")
            T.isNil(FileOperations.rename(gamma, to: "  gamma  "), "whitespace-padded same name → no-op")
            T.isNil(FileOperations.rename(gamma, to: "   "), "blank name → refused")

            // The ONE successful rename above is the newest undo record.
            T.expect(FileUndo.shared.undo(), "undo of the rename reports success")
            T.expect(fm.fileExists(atPath: alpha.path), "undo restores the original folder name")
            try? fm.removeItem(at: beta)
            try? fm.removeItem(at: alpha)
        }

        T.group("moving a file into its own folder is filtered out (self-drop no-op)") {
            let dir = root.appendingPathComponent("selfdrop")
            let x = dir.appendingPathComponent("x.txt")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? "x".write(to: x, atomically: true, encoding: .utf8)
            var finished = false
            FileTransfer.shared.transfer([x], into: dir, move: true) { finished = true }
            pump { finished }
            T.expect(finished, "the transfer completes immediately")
            T.expect(fm.fileExists(atPath: x.path), "the file is untouched")
            T.equal((try? fm.contentsOfDirectory(atPath: dir.path))?.count, 1,
                    "no 'x 2.txt' ghost appears from a same-folder move")
        }

        T.group("cross-directory move: the undo record brings the file home") {
            let a = root.appendingPathComponent("mva")
            let b = root.appendingPathComponent("mvb")
            let x = a.appendingPathComponent("x.txt")
            for d in [a, b] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
            try? "payload".write(to: x, atomically: true, encoding: .utf8)
            var finished = false
            FileTransfer.shared.transfer([x], into: b, move: true) { finished = true }
            pump { finished }
            T.expect(fm.fileExists(atPath: b.appendingPathComponent("x.txt").path), "the file moved to b")
            T.expect(!fm.fileExists(atPath: x.path), "…and left a")
            T.expect(FileUndo.shared.undo(), "undo of the move reports success")
            T.equal((try? String(contentsOf: x, encoding: .utf8)), "payload",
                    "undo moved it back to a with its content intact")
            T.expect(!fm.fileExists(atPath: b.appendingPathComponent("x.txt").path),
                     "…and b no longer holds it")
        }

        T.group("copy conflict, headless: the keep-both default lands 'x 2.txt' (no data loss)") {
            let a = root.appendingPathComponent("kba")
            let b = root.appendingPathComponent("kbb")
            for d in [a, b] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
            try? "new".write(to: a.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
            try? "old".write(to: b.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
            var finished = false
            FileTransfer.shared.transfer([a.appendingPathComponent("x.txt")], into: b, move: false) {
                finished = true
            }
            pump { finished }
            T.equal((try? String(contentsOf: b.appendingPathComponent("x.txt"), encoding: .utf8)), "old",
                    "the existing file is NOT overwritten")
            T.equal((try? String(contentsOf: b.appendingPathComponent("x 2.txt"), encoding: .utf8)), "new",
                    "the incoming copy keeps both as 'x 2.txt'")
            T.expect(FileUndo.shared.undo(), "undo of the copy reports success")
            T.expect(!fm.fileExists(atPath: b.appendingPathComponent("x 2.txt").path),
                     "undo removes only the new copy")
            T.expect(fm.fileExists(atPath: b.appendingPathComponent("x.txt").path),
                     "the pre-existing file survives the undo")
        }

        T.group("naturalKey edges: numeric ordering, leading-zero tiebreak, huge-run clamp") {
            func cmp(_ a: String, _ b: String) -> Int {
                let ka = FileSystemService.naturalKey(a), kb = FileSystemService.naturalKey(b)
                for (x, y) in zip(ka, kb) where x != y { return x < y ? -1 : 1 }
                return ka.count == kb.count ? 0 : (ka.count < kb.count ? -1 : 1)
            }
            T.equal(cmp("2", "10"), -1, "numbers compare by value: 2 < 10")
            T.equal(cmp("a2b", "a10b"), -1, "…also mid-name: a2b < a10b")
            T.equal(cmp("1", "01"), -1, "equal value → shorter original first: 1 before 01")
            T.equal(cmp("01", "001"), -1, "…and 01 before 001 (the length tiebreak byte)")
            T.equal(cmp("07", "7"), 1, "the tiebreak is symmetric: 07 after 7")
            // A digit run longer than the 250 clamp must not trap on the UInt8
            // conversions — and identical names must still compare equal.
            let huge = "f" + String(repeating: "9", count: 300) + ".txt"
            T.equal(cmp(huge, huge), 0, "a 300-digit run survives the clamp and equals itself")
            let huge2 = "f" + String(repeating: "9", count: 301) + ".txt"
            T.equal(cmp(huge, huge2), -cmp(huge2, huge), "clamped comparisons stay antisymmetric")
        }
    }
}
