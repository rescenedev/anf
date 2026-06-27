import Foundation
@testable import anf

/// End-to-end vault lifecycle against the real `git` binary: init → snapshot →
/// delete a file → recover it from the timeline.
func runVaultTests() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("anfvault-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let fileA = dir.appendingPathComponent("notes.txt")
    let fileB = dir.appendingPathComponent("keep.txt")
    try? "version one".write(to: fileA, atomically: true, encoding: .utf8)
    try? "stays".write(to: fileB, atomically: true, encoding: .utf8)

    T.group("Vault lifecycle") {
        T.expect(!VaultService.isVault(dir), "not a vault before init")
        T.expect(VaultService.initVault(at: dir), "initVault succeeds")
        T.expect(VaultService.isVault(dir), "is a vault after init")
        T.expect(fm.fileExists(atPath: dir.appendingPathComponent(".gitignore").path),
                 "smart .gitignore was written")

        let first = VaultService.snapshots(at: dir)
        T.expect(first.count >= 1, "initial snapshot exists (\(first.count))")

        // Change + new file → a second snapshot.
        try? "version two".write(to: fileA, atomically: true, encoding: .utf8)
        try? "new file".write(to: dir.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
        T.expect(VaultService.snapshot(at: dir, label: "edit"), "snapshot taken when changed")
        T.expect(VaultService.snapshots(at: dir).count >= 2, "timeline grew")

        // No change → no empty snapshot.
        T.expect(!VaultService.snapshot(at: dir), "no snapshot when nothing changed")
    }

    T.group("Vault nested policy (existing .git is never touched)") {
        let proj = fm.temporaryDirectory.appendingPathComponent("anfproj-\(UUID().uuidString)")
        try? fm.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: proj) }
        // Simulate a real dev project: the user's own git repo + a file.
        _ = ExternalTools.run("/usr/bin/git", ["-C", proj.path, "init"], maxLines: 50, timeout: 30)
        let userHead = proj.appendingPathComponent(".git/HEAD")
        let userHeadBefore = try? String(contentsOf: userHead, encoding: .utf8)
        try? "src".write(to: proj.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try? "node_modules/\n".write(to: proj.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        T.expect(VaultService.initVault(at: proj), "vault initialises on a git project")
        T.expect(VaultService.isVault(proj), "folder is a vault")
        T.expect(fm.fileExists(atPath: proj.appendingPathComponent(".anf_vault/.git").path),
                 "store is isolated in .anf_vault/, not the root .git")
        // The user's repo is untouched.
        T.equal(try? String(contentsOf: userHead, encoding: .utf8), userHeadBefore,
                "user's own .git/HEAD is unchanged")
        let ignore = (try? String(contentsOf: proj.appendingPathComponent(".gitignore"), encoding: .utf8)) ?? ""
        T.expect(ignore.contains("node_modules/"), "user's .gitignore is preserved")
        T.expect(ignore.contains(".anf_vault/"), "vault excluded from the user's repo")

        // Snapshots still work in the isolated store.
        try? "edit".write(to: proj.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        T.expect(VaultService.snapshot(at: proj, label: "x"), "isolated snapshot works")
        try? fm.removeItem(at: proj.appendingPathComponent("main.swift"))
        let snap = VaultService.snapshots(at: proj).first!
        T.expect(VaultService.restore("main.swift", from: snap, at: proj), "isolated restore works")
        T.expect(fm.fileExists(atPath: proj.appendingPathComponent("main.swift").path), "file recovered")
    }

    T.group("Vault recovery (trash-proof)") {
        let snapBeforeDelete = VaultService.snapshots(at: dir).first!
        // User deletes the file AND empties trash → gone from the work tree.
        try? fm.removeItem(at: fileA)
        T.expect(!fm.fileExists(atPath: fileA.path), "file is gone from disk")

        let deleted = VaultService.deletedSince(snapBeforeDelete, at: dir)
        T.expect(deleted.contains("notes.txt"), "deleted file shows in the timeline")

        T.expect(VaultService.restore("notes.txt", from: snapBeforeDelete, at: dir),
                 "restore reports success")
        T.expect(fm.fileExists(atPath: fileA.path), "file is back on disk")
        T.equal(try? String(contentsOf: fileA, encoding: .utf8), "version two",
                "restored content matches the snapshot")
    }

    T.group("Vault recovery for non-ASCII filenames (Korean / accented / emoji)") {
        // Regression: git C-quotes any path byte >0x7F by default, so ls-tree
        // emitted "\355\225\234…" for these names — deletedSince never matched them
        // on disk and restore checked out a quoted path that didn't exist, so
        // recovery was BROKEN for every non-ASCII filename (the Korean audience).
        let names = ["한글파일.txt", "café.txt", "résumé.txt", "사진📷.txt"]
        for n in names { try? "keepme".write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        T.expect(VaultService.snapshot(at: dir, label: "i18n"), "snapshot captures non-ASCII files")
        let snap = VaultService.snapshots(at: dir).first!

        for n in names { try? fm.removeItem(at: dir.appendingPathComponent(n)) }
        let deleted = VaultService.deletedSince(snap, at: dir)
        // git's own path bytes round-trip through Swift's canonical String compare.
        for n in names {
            T.expect(deleted.contains(n), "deletedSince lists non-ASCII file \(n)")
        }
        // Restore using the exact name git reported, then confirm it's back.
        for n in names {
            let gitName = deleted.first { $0 == n } ?? n
            T.expect(VaultService.restore(gitName, from: snap, at: dir), "restore non-ASCII \(n)")
            T.expect(fm.fileExists(atPath: dir.appendingPathComponent(n).path), "\(n) is back on disk")
        }
    }
}
