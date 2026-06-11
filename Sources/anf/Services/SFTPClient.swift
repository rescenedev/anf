import Foundation

/// One entry from a remote `ls -la` listing.
struct RemoteEntry: Sendable {
    let name: String
    let isDir: Bool
    let isSymlink: Bool
    let size: Int64
    let modified: Date
}

/// Lists and fetches remote files over SFTP without a terminal — the GUI pane
/// browses a host exactly like a local folder. Each operation drives a one-shot
/// `sftp -b -` batch process; an SSH ControlMaster connection is shared across
/// calls (`~/.anf/cm-*`) so navigation after the first hop is fast. Key/agent
/// auth only (BatchMode) — password-only hosts should connect once in a terminal.
enum SFTPClient {
    /// Shared options: reuse one multiplexed SSH connection, fail fast instead of
    /// hanging on a password prompt.
    private static func baseArgs(_ host: String) -> [String] {
        let cm = NSHomeDirectory() + "/.anf/cm-%r@%h:%p"
        try? FileManager.default.createDirectory(
            atPath: NSHomeDirectory() + "/.anf", withIntermediateDirectories: true)
        return [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=12",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(cm)",
            "-o", "ControlPersist=180",
            "-b", "-", host,
        ]
    }

    private static var sftpPath: String { ExternalTools.path("sftp") ?? "/usr/bin/sftp" }

    /// Absolute path of the remote home directory (resolves `.`).
    static func home(_ host: String) async -> String {
        await Task.detached(priority: .userInitiated) {
            let out = ExternalTools.run(sftpPath, baseArgs(host),
                                        stdin: "pwd\n", maxLines: 50, timeout: 20)
            for line in out {
                if let r = line.range(of: "Remote working directory: ") {
                    return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
            }
            return "/"
        }.value
    }

    /// Directory listing of `path` on `host`. Throws a user-facing message on
    /// connection/permission failure.
    static func list(host: String, path: String) async throws -> [RemoteEntry] {
        try await Task.detached(priority: .userInitiated) {
            let cmd = "ls -la \(shq(path))\n"
            let out = ExternalTools.run(sftpPath, baseArgs(host),
                                        stdin: cmd, maxLines: 100_000, timeout: 30)
            var entries: [RemoteEntry] = []
            var sawListing = false
            for line in out {
                if line.hasPrefix("ls ") || line.hasPrefix("sftp>") { continue }
                if let e = parse(line) {
                    sawListing = true
                    if e.name == "." || e.name == ".." { continue }
                    entries.append(e)
                }
            }
            if !sawListing {
                let err = out.first(where: { $0.lowercased().contains("not found")
                    || $0.lowercased().contains("permission denied")
                    || $0.lowercased().contains("connection")
                    || $0.lowercased().contains("could not") })
                throw SFTPError.message(err ?? L("Couldn’t connect to ‘\(host)’. Check that key authentication works.", "‘\(host)’에 연결하지 못했습니다. 키 인증이 가능한지 확인하세요."))
            }
            return entries
        }.value
    }

    /// Download `remotePath` from `host` to a temp file and return its local URL.
    static func download(host: String, remotePath: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let name = (remotePath as NSString).lastPathComponent
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("anf-sftp", isDirectory: true)
                .appendingPathComponent(host, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let local = dir.appendingPathComponent(name)
            let cmd = "get \(shq(remotePath)) \(shq(local.path))\n"
            _ = ExternalTools.run(sftpPath, baseArgs(host),
                                  stdin: cmd, maxLines: 200, timeout: 120)
            guard FileManager.default.fileExists(atPath: local.path) else {
                throw SFTPError.message(L("Couldn’t download ‘\(name)’.", "‘\(name)’ 다운로드에 실패했습니다."))
            }
            return local
        }.value
    }

    // MARK: - Parsing

    private static let dateTime: DateFormatter = formatter("MMM d HH:mm")
    private static let dateYear: DateFormatter = formatter("MMM d yyyy")

    private static func formatter(_ fmt: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = fmt
        return f
    }

    /// Parse one OpenSSH `ls -la` line:
    /// `drwxr-xr-x    2 user  group      4096 Jun  3 04:54 name with spaces`
    /// Internal (not private) so unit tests can exercise the parser directly.
    static func parse(_ line: String) -> RemoteEntry? {
        let pattern = #"^([dlbcps\-])[rwxXsStT\-]{9}[@+\.]?\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\w{3}\s+\d+\s+[\d:]+)\s+(.+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let typeR = Range(m.range(at: 1), in: line),
              let sizeR = Range(m.range(at: 2), in: line),
              let dateR = Range(m.range(at: 3), in: line),
              let nameR = Range(m.range(at: 4), in: line) else { return nil }
        let type = String(line[typeR])
        let size = Int64(line[sizeR]) ?? 0
        let dateStr = line[dateR].replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        var name = String(line[nameR])
        let isSymlink = type == "l"
        if isSymlink, let arrow = name.range(of: " -> ") {   // strip "link -> target"
            name = String(name[..<arrow.lowerBound])
        }
        let modified = dateTime.date(from: dateStr) ?? dateYear.date(from: dateStr) ?? .distantPast
        return RemoteEntry(name: name, isDir: type == "d", isSymlink: isSymlink,
                           size: size, modified: modified)
    }

    private static func shq(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

enum SFTPError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}
