import Foundation

/// An FTP server saved to the sidebar. NOTE: no password field — the password
/// lives in the Keychain (`FTPLocation.secretAccount`) and must never sit in
/// UserDefaults, which is plaintext on disk (same rule as CustomSSHHost).
struct FTPServer: Codable, Identifiable, Hashable {
    let scheme: String
    let host: String
    let port: Int?
    let user: String?
    /// Folder to open on connect — usually "/", since most servers chroot a login
    /// to its own home and there's no LIST-free way to ask where that is.
    var path: String

    init(_ loc: FTPLocation) {
        scheme = loc.scheme
        host = loc.host
        port = loc.port
        user = loc.user
        path = loc.path
    }

    var location: FTPLocation {
        FTPLocation(scheme: scheme, host: host, port: port, user: user, path: path)
    }

    var url: URL { location.url(path: path) }
    var label: String { location.label }
    /// Login identity, not the folder: re-adding the same server at another path
    /// updates the existing row instead of piling up duplicates.
    var id: String { location.serverURL.absoluteString }
}

/// FTP servers the user saved (the sidebar's FTP section), persisted to
/// UserDefaults. Shared across windows so two windows can't overwrite each
/// other's list (see FavoritesStore.shared / CustomSSHStore.shared).
@MainActor
@Observable
final class FTPServersStore {
    static let shared = FTPServersStore()

    private(set) var servers: [FTPServer]
    private let key = "anf.ftp.servers.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([FTPServer].self, from: data) {
            servers = decoded
        } else {
            servers = []
        }
    }

    /// Add, or update the path of an already-saved login.
    func add(_ server: FTPServer) {
        if let i = servers.firstIndex(where: { $0.id == server.id }) {
            servers[i] = server
        } else {
            servers.append(server)
        }
        persist()
    }

    /// Forget the server *and* its stored password — a removed bookmark must not
    /// leave a credential behind in the Keychain.
    func remove(id: String) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        Keychain.delete(servers[i].location.secretAccount)
        servers.remove(at: i)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
