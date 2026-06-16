import Foundation
@testable import anf

/// Live folder watching: FSEvents on local volumes, polling on network mounts.
/// onChange is delivered on a background queue, so these wait on a semaphore
/// (bounded timeout — never hangs) rather than pumping the main runloop.
func runDirectoryWatcherTests() {
    let fm = FileManager.default

    T.group("PollingDirectoryWatcher.signature changes with contents") {
        let dir = fm.temporaryDirectory.appendingPathComponent("anfsig-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let before = PollingDirectoryWatcher.signature(of: dir)
        try? "x".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let afterAdd = PollingDirectoryWatcher.signature(of: dir)
        T.expect(before != afterAdd, "signature differs after adding a file")
        try? fm.removeItem(at: dir.appendingPathComponent("a.txt"))
        T.equal(PollingDirectoryWatcher.signature(of: dir), before, "signature returns to baseline after removal")
    }

    T.group("PollingDirectoryWatcher fires onChange when contents change") {
        let dir = fm.temporaryDirectory.appendingPathComponent("anfpoll-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let w = PollingDirectoryWatcher(interval: 0.2)
        let sem = DispatchSemaphore(value: 0)
        w.start(dir) { sem.signal() }
        try? "x".write(to: dir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let fired = sem.wait(timeout: .now() + 3) == .success
        w.stop()
        T.expect(fired, "polling watcher detected the new file within 3s")
    }

    T.group("FSEventDirectoryWatcher fires on a local change") {
        let dir = fm.temporaryDirectory.appendingPathComponent("anffse-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let w = FSEventDirectoryWatcher()
        let sem = DispatchSemaphore(value: 0)
        w.start(dir) { sem.signal() }
        Thread.sleep(forTimeInterval: 0.4)   // let the stream arm before we change anything
        try? "x".write(to: dir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let fired = sem.wait(timeout: .now() + 10) == .success
        w.stop()
        T.expect(fired, "FSEvents watcher detected the new file")
    }

    T.group("factory picks FSEvents for a local volume") {
        let dir = fm.temporaryDirectory
        T.expect(DirectoryWatcherFactory.isLocalVolume(dir), "temp dir is a local volume")
        T.expect(DirectoryWatcherFactory.make(for: dir) is FSEventDirectoryWatcher, "local volume → FSEvents watcher")
    }
}
