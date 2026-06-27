import Foundation

/// Filesystem checks that won't freeze the UI on a stale network mount.
///
/// `FileManager.fileExists` / volume `resourceValues` block the *calling* thread
/// for the mount's full TCP timeout (tens of seconds) when an SMB/AFP/NFS share
/// has gone away. Run on the main thread — as session restore does on relaunch —
/// that beachballs the whole app when the last folder lived on a now-unreachable
/// share. These run the blocking call on a background queue and give up after a
/// short timeout, treating "no answer in time" as unreachable.
enum PathProbe {
    /// True only if `path` is an existing directory that answered within `timeout`.
    /// A stale mount that never answers is reported unreachable (`false`) rather
    /// than hanging the caller.
    static func isDirectory(_ path: String, timeout: TimeInterval = 1.5) -> Bool {
        run(timeout: timeout) {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                && isDir.boolValue
        } ?? false
    }

    /// True only if `path` can actually be OPENED as a directory within `timeout`.
    /// Unlike `isDirectory` (a `stat`, which the kernel serves from cache for a
    /// disconnected mount's *root*), `opendir` contacts the server — so this is the
    /// reliable "is the volume actually reachable" test, even at the mount root.
    static func canListDirectory(_ path: String, timeout: TimeInterval = 1.5) -> Bool {
        run(timeout: timeout) {
            guard let dir = opendir(path) else { return false }
            closedir(dir)
            return true
        } ?? false
    }

    /// Concurrently test many paths, returning the subset that are existing
    /// directories answering within a SINGLE `timeout` window. Session restore on
    /// relaunch validates every saved tab; probing them one-at-a-time summed a
    /// blocking 1.5s per dead-mount tab (a quad Workspace parked on an offline NAS
    /// froze launch for seconds). Probing concurrently bounds the whole restore to
    /// one timeout, and a deleted LOCAL folder still resolves instantly.
    static func existingDirectories(_ paths: [String], timeout: TimeInterval = 1.5) -> Set<String> {
        let unique = Set(paths)
        guard !unique.isEmpty else { return [] }
        let box = SetBox()
        let group = DispatchGroup()
        let q = DispatchQueue.global(qos: .userInitiated)
        for path in unique {
            group.enter()
            q.async {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    box.insert(path)
                }
                group.leave()
            }
        }
        // Abandon any still-blocked (dead-mount) probes after the window, like run().
        _ = group.wait(timeout: .now() + timeout)
        return box.snapshot()
    }

    private final class SetBox: @unchecked Sendable {
        private let lock = NSLock()
        private var set = Set<String>()
        func insert(_ s: String) { lock.lock(); set.insert(s); lock.unlock() }
        func snapshot() -> Set<String> { lock.lock(); defer { lock.unlock() }; return set }
    }

    /// Run `work` on a background queue, returning its result, or `nil` if it
    /// didn't finish within `timeout`. On timeout the worker thread is abandoned
    /// (not cancelled) — it unblocks on its own when the mount finally times out,
    /// which is far cheaper than a frozen UI.
    static func run<T: Sendable>(timeout: TimeInterval, _ work: @escaping @Sendable () -> T) -> T? {
        let box = Box<T>()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = work()
            sem.signal()
        }
        return sem.wait(timeout: .now() + timeout) == .success ? box.value : nil
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }
}
