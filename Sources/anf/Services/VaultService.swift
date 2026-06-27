import Foundation

/// One snapshot in a vault's timeline.
struct VaultSnapshot: Identifiable, Hashable, Sendable {
    let id: String          // commit hash
    let date: Date
    let summary: String     // human label, e.g. "12 files changed"
}

/// The Vault engine: per-folder time-travel backup built on the system `git`
/// binary (every Mac with Command Line Tools has it). All operations run off
/// the main thread; auto-snapshots are debounced so disk stays idle. Git is an
/// implementation detail — nothing here leaks the word "commit" to the user.
///
/// We shell out to `git` rather than statically linking libgit2: in a
/// CLT-only / SwiftPM build, vendoring libgit2 + its transports (zlib, TLS,
/// libssh2) is a dependency swamp for zero user-visible gain on a
/// once-per-five-minutes workload. The boundary here (init/snapshot/log/
/// restore) is small enough to swap to libgit2 later without touching callers.
enum VaultService {
    static let snapshotPrefix = "anf-vault-snapshot-"

    /// Injected into every new vault's .gitignore. Deliberately ONLY OS metadata
    /// and incomplete downloads — NOT user content. Excluding things like *.log,
    /// *.tmp or node_modules/ would silently leave real user files unprotected,
    /// breaking the Vault promise (V-003). A vault therefore protects EVERYTHING,
    /// large binaries included — git-based versioning means a folder with big files
    /// grows a big repo; that's the cost of total recoverability, not silently
    /// dropped. (There is no size-based auto-bypass — none should exist, per V-003.)
    static let defaultIgnore = """
    # macOS system metadata (not user content)
    .DS_Store
    .AppleDouble
    .LSOverride
    ._*

    # incomplete downloads (not a finished file yet)
    *.crdownload
    """

    private static var git: String { "/usr/bin/git" }

    /// Nested-vault isolation folder used when the directory already has a
    /// user-owned `.git` (a real dev project) — we never touch their repo.
    static let isolatedDir = ".anf_vault"

    private static func hasUserGit(_ url: URL) -> Bool {
        // A vault we created in isolated mode is ours, not the user's.
        if FileManager.default.fileExists(
            atPath: url.appendingPathComponent("\(isolatedDir)/.anf_owned").path) { return false }
        // A `.git` right here is a real dev project.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path, isDirectory: &isDir),
           isDir.boolValue { return true }
        // …or this folder is NESTED inside a git work tree (parent repo). The old
        // top-level-only check missed that, so vaulting a subfolder of a user repo
        // would collide with their history (V-005). rev-parse detects it. Off-main.
        let out = ExternalTools.run(git, ["-C", url.path, "rev-parse", "--is-inside-work-tree"],
                                    maxLines: 5, timeout: 10)
        return out.contains("true")
    }

    /// Where this folder's vault store lives: the directory root for plain
    /// folders, or an isolated `.anf_vault/` work tree when the folder already
    /// has the user's own git repo (so we never collide with their history).
    static func storeURL(for folder: URL) -> URL {
        isVaultIsolated(folder) ? folder.appendingPathComponent(isolatedDir) : folder
    }

    private static func isVaultIsolated(_ url: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: url.appendingPathComponent("\(isolatedDir)/.git").path)
    }

    /// A folder is a vault when anf has a store for it — either a root `.git`
    /// we own, or an isolated `.anf_vault/.git`.
    static func isVault(_ url: URL) -> Bool {
        if isVaultIsolated(url) { return true }
        var isDir: ObjCBool = false
        let dotGit = url.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir),
              isDir.boolValue else { return false }
        // A root `.git` counts as OUR vault only if we marked it (so a plain dev
        // repo isn't mistaken for a vault).
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent(".anf_owned").path)
    }

    // MARK: - Lifecycle

    /// Turn `folder` into a vault: `git init`, write the smart .gitignore, set a
    /// local identity (so commits work without global git config), and take the
    /// first snapshot. Returns true on success. Runs synchronously — callers
    /// should dispatch off the main thread.
    @discardableResult
    static func initVault(at folder: URL) -> Bool {
        guard !isVault(folder) else { return true }
        let fm = FileManager.default

        let isolated = hasUserGit(folder)
        if isolated {
            // The folder is a real git project — never touch the user's repo.
            // The store lives in .anf_vault/.git with the folder as work tree.
            let store = folder.appendingPathComponent(isolatedDir)
            try? fm.createDirectory(at: store, withIntermediateDirectories: true)
            let gitDir = store.appendingPathComponent(".git").path
            guard ExternalTools.run(git, ["--git-dir", gitDir, "--work-tree", folder.path,
                                          "init"], maxLines: 100, timeout: 60) != nil,
                  fm.fileExists(atPath: gitDir) else { return false }
            appendToUserGitignore(folder)
        } else {
            guard run(["init"], folder: folder) != nil else { return false }
            // Mark this root .git as ours so a plain dev repo isn't seen as a vault.
            try? "".write(to: folder.appendingPathComponent(".anf_owned"),
                          atomically: true, encoding: .utf8)
        }

        _ = run(["config", "user.name", "anf vault"], folder: folder)
        _ = run(["config", "user.email", "vault@anf.local"], folder: folder)
        let ignore = folder.appendingPathComponent(".gitignore")
        if !isVaultIsolated(folder), !fm.fileExists(atPath: ignore.path) {
            try? defaultIgnore.write(to: ignore, atomically: true, encoding: .utf8)
        }
        return snapshot(at: folder, label: "initial")
    }

    /// Append the isolated-vault exclusion to the user's existing .gitignore so
    /// our store never pollutes their `git status`.
    private static func appendToUserGitignore(_ folder: URL) {
        let ignore = folder.appendingPathComponent(".gitignore")
        let marker = "\n# anf Vault\n\(isolatedDir)/\n"
        if let existing = try? String(contentsOf: ignore, encoding: .utf8) {
            if !existing.contains("\(isolatedDir)/") {
                try? (existing + marker).write(to: ignore, atomically: true, encoding: .utf8)
            }
        } else {
            try? marker.write(to: ignore, atomically: true, encoding: .utf8)
        }
    }

    /// Stop protecting a folder: remove our store (and the marker / ignore line).
    /// The user's files — and their own `.git` — are untouched.
    static func disableVault(at folder: URL) {
        // Under gitLock so we never delete the store while a snapshot/restore is
        // mid-commit on it (V-004 completeness — disable() cancels the debounce, but
        // an already-in-flight snapshot could still be running).
        gitLock.sync {
            let fm = FileManager.default
            if isVaultIsolated(folder) {
                try? fm.removeItem(at: folder.appendingPathComponent(isolatedDir))
            } else {
                try? fm.removeItem(at: folder.appendingPathComponent(".git"))
                try? fm.removeItem(at: folder.appendingPathComponent(".anf_owned"))
            }
        }
    }

    // MARK: - Snapshots

    /// Serializes ALL git index mutations (snapshot/restore) across every vault:
    /// two `git add`+`commit` racing on one repo corrupts the index / hits
    /// index.lock. VaultWatcher fires snapshots from concurrent detached tasks, so
    /// this is required (V-004). Snapshots are infrequent → one global lock is fine.
    private static let gitLock = DispatchQueue(label: "anf.vault.git")

    /// True if the work tree has changes not yet in any snapshot — i.e. files a
    /// failed snapshot would leave with no recovery point. Lets callers tell a
    /// "nothing to commit" snapshot (safe) from a real failure (V-002-A).
    /// If git can't confirm a healthy repo we can't prove the tree is clean, so
    /// report `true` (unsafe) — callers must not destroy data on an unverifiable
    /// repo. (`run` returns empty stdout, never nil, on failure, so detect failure
    /// via the exit code of rev-parse — V-002-B.)
    static func hasUncommittedChanges(at folder: URL) -> Bool {
        guard runStatus(["rev-parse", "--git-dir"], folder: folder) == 0 else { return true }
        return !(run(["status", "--porcelain"], folder: folder) ?? []).isEmpty
    }

    /// Stage everything and commit, but ONLY if there are changes (an empty
    /// commit would bloat the log). Returns true if a snapshot was taken.
    @discardableResult
    static func snapshot(at folder: URL, label: String = "") -> Bool {
        gitLock.sync { snapshotLocked(at: folder, label: label) }
    }

    /// Snapshot body without taking `gitLock` — for callers already holding it.
    private static func snapshotLocked(at folder: URL, label: String) -> Bool {
        _ = run(["add", "--all"], folder: folder)
        // `git diff --cached --quiet` exits 1 when there's something staged.
        if runStatus(["diff", "--cached", "--quiet"], folder: folder) == 0 {
            return false   // nothing changed
        }
        let stamp = ISO8601Stamp.now()
        let msg = "\(snapshotPrefix)\(stamp)\(label.isEmpty ? "" : " (\(label))")"
        return run(["commit", "-m", msg], folder: folder) != nil
    }

    /// The timeline, newest first.
    static func snapshots(at folder: URL, limit: Int = 200) -> [VaultSnapshot] {
        let out = run(["log", "--pretty=format:%H\u{1f}%ct\u{1f}%s",
                       "-n", "\(limit)"], folder: folder) ?? []
        return out.compactMap { line in
            let f = line.components(separatedBy: "\u{1f}")
            guard f.count == 3, let secs = Double(f[1]) else { return nil }
            return VaultSnapshot(id: f[0], date: Date(timeIntervalSince1970: secs),
                                 summary: humanSummary(f[2]))
        }
    }

    /// Files present in a snapshot but missing from the working tree now —
    /// candidates for "recover a deleted file".
    static func deletedSince(_ snapshot: VaultSnapshot, at folder: URL) -> [String] {
        let inSnap = run(["ls-tree", "-r", "--name-only", snapshot.id], folder: folder) ?? []
        let fm = FileManager.default
        return inSnap.filter { !fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Restore one file from a snapshot back to its original path (overwrites if
    /// it exists). Returns true on success.
    @discardableResult
    static func restore(_ relativePath: String, from snapshot: VaultSnapshot, at folder: URL) -> Bool {
        // Preserve the CURRENT state first: `git checkout` overwrites in place, so
        // restoring an old snapshot over a file edited since would silently clobber
        // those edits. Snapshotting now keeps the pre-restore version in the vault
        // timeline, so it's always recoverable (no data loss).
        // Whole sequence under gitLock so a background snapshot can't race the
        // checkout on the index (V-004); use snapshotLocked to avoid re-entrancy.
        return gitLock.sync {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(relativePath).path) {
                let snapped = snapshotLocked(at: folder, label: L("Before restoring \(relativePath)",
                                                                  "\(relativePath) 복원 전 자동 저장"))
                // If the pre-restore snapshot DIDN'T take and the file still has
                // uncommitted changes, checkout would clobber them with no recovery —
                // refuse instead of risking data loss (V-001-A). A clean file is
                // already safe in HEAD, so proceed.
                if !snapped {
                    // Can't confirm a healthy repo → can't prove the file is safely
                    // captured → refuse rather than clobber (V-001-A/V-002-B). `run`
                    // returns empty stdout (not nil) on failure, so gate on rev-parse.
                    guard runStatus(["rev-parse", "--git-dir"], folder: folder) == 0 else { return false }
                    let dirty = !(run(["status", "--porcelain", "--", relativePath], folder: folder) ?? []).isEmpty
                    if dirty { return false }
                }
            }
            // `git checkout <hash> -- <path>` writes the file back to the work tree.
            return runStatus(["checkout", snapshot.id, "--", relativePath], folder: folder) == 0
        }
    }

    // MARK: - Maintenance

    /// Compact loose objects + prune unreachable ones (the debloat pass).
    static func compact(at folder: URL) {
        _ = run(["gc", "--auto", "--quiet"], folder: folder)
    }

    // MARK: - git plumbing

    /// Base args that point git at the right store. For an isolated vault the
    /// store lives in `.anf_vault/.git` but tracks the parent folder as its work
    /// tree; for a plain vault `-C folder` is enough.
    private static func base(_ folder: URL) -> [String] {
        // `core.quotePath=false`: by default git C-quotes any path byte >0x7F
        // (octal escapes wrapped in quotes), so `ls-tree`/`status` emit
        // `"\355\225\234…"` for a Korean/accented/emoji filename. deletedSince then
        // can't match it on disk (every non-ASCII file looked "deleted") and
        // restore checked out a quoted path that doesn't exist — recovery was
        // broken for every non-ASCII name. Emitting paths verbatim fixes both.
        let quoting = ["-c", "core.quotePath=false"]
        if isVaultIsolated(folder) {
            return quoting + ["--git-dir", folder.appendingPathComponent("\(isolatedDir)/.git").path,
                              "--work-tree", folder.path, "-C", folder.path]
        }
        return quoting + ["-C", folder.path]
    }

    private static func run(_ args: [String], folder: URL) -> [String]? {
        ExternalTools.run(git, base(folder) + args, maxLines: 100_000, timeout: 60)
    }

    /// Run for the EXIT CODE (used for `diff --quiet`, `checkout`).
    private static func runStatus(_ args: [String], folder: URL) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = base(folder) + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus }
        catch { return -1 }
    }
}

/// Compact ISO-ish timestamp safe for a commit subject (no spaces/colons).
enum ISO8601Stamp {
    static func now() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = .current
        return f.string(from: Date())
    }
}

private func humanSummary(_ subject: String) -> String {
    // Hide the internal prefix; show the readable tail or a generic label.
    if let r = subject.range(of: "(") { return String(subject[r.lowerBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "()")) }
    return L("Snapshot", "스냅샷")
}
