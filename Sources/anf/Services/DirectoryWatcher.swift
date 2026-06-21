import Foundation
import CoreServices

/// Watches a SINGLE directory for changes and fires `onChange` (coalesced), so an
/// open tab refreshes when another app creates/moves/deletes a file in the folder
/// you're looking at.
///
/// Two implementations, chosen by volume:
/// - `FSEventDirectoryWatcher` for LOCAL volumes — `FSEventStreamCreate`, no file
///   descriptors, kernel-coalesced.
/// - `PollingDirectoryWatcher` for NETWORK mounts (SMB/AFP/NFS), where no kernel
///   notification API fires at all — the limitation is in the protocol, not the
///   API (Finder itself doesn't live-update a network share either). We re-list
///   on a low-frequency timer and diff a cheap signature.
///
/// Pick one with `DirectoryWatcherFactory.make(for:)`. `onChange` is delivered on
/// a background queue — hop to the main actor before touching the model.
protocol DirectoryWatcher: AnyObject {
    func start(_ url: URL, onChange: @escaping @Sendable () -> Void)
    func stop()
}

enum DirectoryWatcherFactory {
    /// Local volume → FSEvents; network/unknown → polling. NOTE: `isLocalVolume`
    /// calls `resourceValues`, which can block on a stalled mount — call it
    /// OFF the main thread (the caller does).
    static func make(for url: URL) -> DirectoryWatcher {
        isLocalVolume(url) ? FSEventDirectoryWatcher() : PollingDirectoryWatcher()
    }

    static func isLocalVolume(_ url: URL) -> Bool {
        // Default to `true` (FSEvents) only for genuinely local volumes; anything
        // unknown is treated as local since the temp/most paths are local. A
        // stalled mount answers `false`/throws → polling, which is the safe choice.
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? true
    }
}

/// FSEvents-backed watcher for local volumes.
final class FSEventDirectoryWatcher: DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "anf.fswatch", qos: .utility)

    /// Boxes the Swift closure so it can ride through the C `info` pointer.
    private final class Box { let fn: @Sendable () -> Void; init(_ f: @escaping @Sendable () -> Void) { fn = f } }
    /// Last seen content signature — mutated only on `queue` (single-threaded),
    /// so a content-preserving FSEvent burst doesn't reload the UI forever.
    private final class SigHolder: @unchecked Sendable { var value = 0 }

    func start(_ url: URL, onChange: @escaping @Sendable () -> Void) {
        stop()
        // FSEvents fire for metadata/atime/.DS_Store touches and other background
        // activity that doesn't change the visible listing. Without a guard, a
        // folder the system keeps touching (e.g. Desktop) reloads the UI every
        // 0.2s forever, which cancels in-flight interactions like drag (#76).
        // Re-list and compare a content signature; only notify on a real change —
        // the same dedup the polling watcher already does.
        let sig = SigHolder()
        sig.value = PollingDirectoryWatcher.signature(of: url)
        let gate: @Sendable () -> Void = {
            let now = PollingDirectoryWatcher.signature(of: url)
            guard now != sig.value else { return }
            sig.value = now
            onChange()
        }
        let info = Unmanaged.passRetained(Box(gate)).toOpaque()
        var ctx = FSEventStreamContext(
            version: 0, info: info, retain: nil,
            release: { ptr in if let ptr { Unmanaged<Box>.fromOpaque(ptr).release() } },
            copyDescription: nil)
        // No captures → converts to a C function pointer. We re-list the whole
        // folder on any event, so the event paths are ignored.
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().fn()
        }
        let flags = UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,                      // latency: coalesces bursts for free
            flags) else {
            Unmanaged<Box>.fromOpaque(info).release()
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)   // fires ctx.release → frees the Box
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}

/// Timer-polling watcher for network mounts (and any volume FSEvents can't serve).
final class PollingDirectoryWatcher: DirectoryWatcher {
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "anf.pollwatch", qos: .utility)
    private var signature = 0
    private let interval: TimeInterval

    init(interval: TimeInterval = 4) { self.interval = interval }

    func start(_ url: URL, onChange: @escaping @Sendable () -> Void) {
        stop()
        signature = Self.signature(of: url)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let sig = Self.signature(of: url)
            if sig != self.signature {
                self.signature = sig
                onChange()
            }
        }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit { stop() }

    /// A cheap content fingerprint: entry count plus each name/size/mtime. Uses
    /// the same `getattrlistbulk` bulk read the listing does (works over SMB).
    static func signature(of url: URL) -> Int {
        guard let entries = FastDirRead.list(path: url.path) else { return 0 }
        var h = Hasher()
        h.combine(entries.count)
        for e in entries {
            h.combine(e.name)
            h.combine(e.size)
            h.combine(e.modified)
        }
        return h.finalize()
    }
}
