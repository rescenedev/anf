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
        if let url = mounts[host], isMounted(url) { completion(.success(url)); return }

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
        // sshfs daemonizes by default; a short run + check.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = ExternalTools.run(sshfs, args, timeout: 20)
            Task { @MainActor in
                guard let self else { return }
                if self.isMounted(point) {
                    self.mounts[host] = point
                    completion(.success(point))
                } else {
                    completion(.failure(L("Couldn’t mount ‘\(host)’ over SFTP.\nCheck the host name and SSH access.", "‘\(host)’ SFTP 마운트에 실패했습니다.\n호스트 이름과 SSH 접속을 확인하세요.")))
                }
            }
        }
    }

    func unmount(host: String) {
        guard let url = mounts[host] else { return }
        _ = ExternalTools.run("/usr/sbin/diskutil", ["unmount", url.path], timeout: 10)
        _ = ExternalTools.run("/sbin/umount", [url.path], timeout: 10)
        mounts.removeValue(forKey: host)
    }

    private func isMounted(_ url: URL) -> Bool {
        // A mounted sshfs point has contents and a different device than its parent.
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: url.path) else { return false }
        return !contents.isEmpty
    }

    static func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L("SFTP Mount", "SFTP 마운트")
        alert.informativeText = message
        alert.addButton(withTitle: L("OK", "확인"))
        alert.runModal()
    }
}
