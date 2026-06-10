import Foundation

struct SSHHost: Identifiable, Hashable {
    let alias: String
    let hostName: String?
    var id: String { alias }
    var subtitle: String { hostName ?? alias }
}

/// A user-added SSH connection with full credentials.
struct CustomSSHHost: Codable, Identifiable, Hashable {
    let id: String
    let host: String      // hostname or IP
    let user: String?     // login user (optional — may be in ssh config)
    let password: String? // stored for reference; direct ssh uses key auth
    let keyFile: String?  // path to private key

    init(host: String, user: String? = nil, password: String? = nil, keyFile: String? = nil) {
        self.id = UUID().uuidString
        self.host = host
        self.user = user
        self.password = password
        self.keyFile = keyFile
    }

    /// What appears in the sidebar and gets passed to `ssh`.
    var target: String {
        if let user, !user.isEmpty { return "\(user)@\(host)" }
        return host
    }

    var sshArgs: [String] {
        var args: [String] = []
        if let key = keyFile, !key.isEmpty {
            args += ["-i", (key as NSString).expandingTildeInPath]
        }
        args.append(target)
        return args
    }
}

/// User-added SSH targets (the sidebar's "+" button), persisted to UserDefaults.
/// These complement the hosts auto-read from `~/.ssh/config`.
@MainActor
@Observable
final class CustomSSHStore {
    private(set) var hosts: [CustomSSHHost]
    private let key = "anf.ssh.custom.v2"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([CustomSSHHost].self, from: data) {
            hosts = decoded
        } else {
            hosts = []
        }
    }

    func add(_ host: CustomSSHHost) {
        guard !hosts.contains(where: { $0.target == host.target }) else { return }
        hosts.append(host)
        persist()
    }

    func remove(target: String) {
        hosts.removeAll { $0.target == target }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Parses `~/.ssh/config` for connectable host aliases (skipping wildcard patterns).
enum SSHConfig {
    static func hosts() -> [SSHHost] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var result: [SSHHost] = []
        var pendingAliases: [String] = []
        var hostName: String?

        func flush() {
            for alias in pendingAliases where !alias.contains("*") && !alias.contains("?") {
                result.append(SSHHost(alias: alias, hostName: hostName))
            }
            pendingAliases = []; hostName = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let keyword = parts.first else { continue }
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

            switch keyword.lowercased() {
            case "host":
                flush()
                pendingAliases = value.split(separator: " ").map(String.init)
            case "hostname":
                hostName = value
            default:
                break
            }
        }
        flush()
        var seen = Set<String>()
        return result.filter { seen.insert($0.alias).inserted }
    }
}
