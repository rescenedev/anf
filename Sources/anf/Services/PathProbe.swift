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
