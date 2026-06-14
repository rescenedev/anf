import AppKit

/// Mounts a remote host over SFTP using `sshfs`, so the remote filesystem can be
/// browsed in a pane exactly like a local folder. Requires `sshfs` (macFUSE);
/// when it isn't installed `mount` reports a friendly error with an install hint.
@MainActor
final class RemoteMount {
    static let shared = RemoteMount()

    enum MountResult {
        case success(URL)
        case failure(String)
    }

    private(set) var mounts: [String: URL] = [:]   // host → local mount point

    private var baseDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".anf/mounts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Mount `host:` at `~/.anf/mounts/<host>`. Reuses an existing mount.
    func mount(host: String, completion: @escaping (MountResult) -> Void) {
        // (The reuse check moved off-main below — `isMountPoint` can block on a
        // stale FUSE mount and must not run on the main actor.)
        guard let sshfs = ExternalTools.path("sshfs") else {
            completion(.failure(
                L("sshfs is not installed.\n\nMounting needs macFUSE + sshfs:\n  brew install --cask macfuse\n  brew install gromgit/fuse/sshfs-mac\n\nOr use ‘SFTP (Terminal)’ from the sidebar instead.", "sshfs가 설치되어 있지 않습니다.\n\n그래픽 탐색을 하려면 macFUSE + sshfs가 필요합니다:\n  brew install --cask macfuse\n  brew install gromgit/fuse/sshfs-mac\n\n설치가 어렵다면 사이드바에서 'SFTP (터미널)'을 쓰세요.")))
            return
        }

        let safe = host.replacingOccurrences(of: "/", with: "_")
        let point = baseDir.appendingPathComponent(safe, isDirectory: true)
        try? FileManager.default.createDirectory(at: point, withIntermediateDirectories: true)

        // Mount the remote home. -f/blocking would hang us; run detached.
        let args = [
            "\(host):", point.path,
            "-o", "volname=\(host)",
            "-o", "reconnect",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "defer_permissions",
        ]
        // EVERYTHING that can touch the (possibly stale) mount runs off-main: both
        // the reuse check and the sshfs spawn block on a hung FUSE mount, which
        // would beachball if done on the main actor.
        let existing = mounts[host]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Reuse only if the existing point is genuinely still a live mount.
            if let existing, Self.isMountPoint(existing.path) {
                Task { @MainActor in completion(.success(existing)) }
                return
            }
            _ = ExternalTools.run(sshfs, args, timeout: 20)   // sshfs daemonizes
            let ok = Self.isMountPoint(point.path)
            if !ok {
                // Don't leave the empty mount-point dir behind to accumulate (N-008).
                // Only remove it when genuinely empty — never recursively delete data.
                let fm = FileManager.default
                if (try? fm.contentsOfDirectory(atPath: point.path))?.isEmpty == true {
                    try? fm.removeItem(at: point)
                }
            }
            Task { @MainActor in
                guard let self else { return }
                if ok {
                    self.mounts[host] = point
                    completion(.success(point))
                } else {
                    completion(.failure(L("Couldn’t mount ‘\(host)’ over SFTP.\nCheck the host name and SSH access.", "‘\(host)’ SFTP 마운트에 실패했습니다.\n호스트 이름과 SSH 접속을 확인하세요.")))
                }
            }
        }
    }

    func unmount(host: String) {
        guard let url = mounts.removeValue(forKey: host) else { return }
        // Force-unmount off-main: a hung sshfs mount makes diskutil/umount block for
        // the timeout, which would freeze the UI if run on the main actor.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = ExternalTools.run("/usr/sbin/diskutil", ["unmount", "force", url.path], timeout: 10)
            _ = ExternalTools.run("/sbin/umount", ["-f", url.path], timeout: 10)
        }
    }

    /// A real mount point sits on a different device than its parent directory —
    /// the reliable test (vs "has any contents", which an empty or just-mounted
    /// share fails). `stat` can block on a dead mount, so call this OFF the main
    /// thread only.
    nonisolated static func isMountPoint(_ path: String) -> Bool {
        var here = stat(), parent = stat()
        guard stat(path, &here) == 0 else { return false }
        let parentPath = (path as NSString).deletingLastPathComponent
        guard stat(parentPath, &parent) == 0 else { return false }
        return here.st_dev != parent.st_dev
    }

    static func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L("SFTP Mount", "SFTP 마운트")
        alert.informativeText = message
        alert.addButton(withTitle: L("OK", "확인"))
        alert.runModal()
    }
}
