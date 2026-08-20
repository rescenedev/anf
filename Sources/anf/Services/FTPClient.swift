import Foundation

/// A parsed `ftp://` / `ftps://` address — everything needed to talk to one server
/// except the password, which lives only in the Keychain under `secretAccount`.
struct FTPLocation: Hashable, Sendable {
    /// "ftp" = plain, "ftps" = explicit TLS (AUTH TLS on the normal FTP port,
    /// which is what nearly every "FTPS" server means).
    let scheme: String
    let host: String
    let port: Int?
    let user: String?      // nil → anonymous login
    let path: String       // absolute, always starts with "/"

    var isTLS: Bool { scheme == "ftps" }

    /// Keychain account holding this server's password. Deliberately path-free so
    /// one saved login serves every folder on the host.
    var secretAccount: String {
        "ftp:\(user ?? "anonymous")@\(host)\(port.map { ":\($0)" } ?? "")"
    }

    /// "user@host:port" — what prompts and the sidebar show.
    var label: String {
        let hostPort = port.map { "\(host):\($0)" } ?? host
        return user.map { "\($0)@\(hostPort)" } ?? hostPort
    }

    /// The server root. Two bookmarks to the same login are the same server
    /// regardless of which folder they point at, so this is the identity key.
    var serverURL: URL { url(path: "/") }

    /// Parse an `ftp://user@host:port/path` URL. Returns nil for any other scheme
    /// so callers can use it as the "is this an FTP location?" test.
    static func parse(_ url: URL) -> FTPLocation? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = c.scheme?.lowercased(), scheme == "ftp" || scheme == "ftps",
              let host = c.host, !host.isEmpty else { return nil }
        let user = (c.user?.isEmpty == false) ? c.user : nil
        return FTPLocation(scheme: scheme, host: host, port: c.port, user: user,
                           path: c.path.isEmpty ? "/" : c.path)
    }

    /// The same server at another path. URLComponents percent-encodes for us, so
    /// names with spaces or `#` survive the round-trip through the address.
    func url(path: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.user = user
        c.host = host
        c.port = port
        c.path = path.hasPrefix("/") ? path : "/" + path
        return c.url ?? URL(string: "\(scheme)://\(host)/")!
    }
}

/// Browses an FTP/FTPS server in a pane like a local folder, driving the `curl`
/// that ships with macOS — no FUSE mount and nothing to install (contrast
/// RemoteMount, which needs macFUSE). Each call is one short-lived process.
///
/// Credentials are handed to curl as a config file **on stdin**, never in argv:
/// process arguments are world-readable through `ps`, so `--user u:p` would leak
/// the password to every local user.
enum FTPClient {
    private static var curlPath: String { ExternalTools.path("curl") ?? "/usr/bin/curl" }

    /// Directory listing of `loc.path`. An empty result is a legitimately empty
    /// folder; a connection/login failure throws a message meant for the user.
    static func list(_ loc: FTPLocation) async throws -> [RemoteEntry] {
        let password = Keychain.get(loc.secretAccount)
        return try await Task.detached(priority: .userInitiated) {
            // The trailing slash is what makes curl issue LIST instead of RETR.
            let dir = loc.path.hasSuffix("/") ? loc.path : loc.path + "/"
            let maxLines = 100_000
            let out = runCurl(loc, path: dir, password: password,
                              maxTime: 30, output: nil, maxLines: maxLines)
            // Don't truncate silently (N-007): surface a capped listing in the trace.
            if out.count >= maxLines {
                Trace.log("FTP: \(loc.label):\(dir) listing hit the \(maxLines)-line cap — directory may be truncated")
            }
            if let err = out.first(where: { $0.hasPrefix("curl:") }) {
                throw FTPError.message(friendlyError(err, host: loc.host))
            }
            var entries: [RemoteEntry] = []
            for line in out {
                guard let e = parse(line), e.name != ".", e.name != ".." else { continue }
                entries.append(e)
            }
            // Lines we couldn't parse mean an unknown LIST dialect, not an empty
            // folder — the user would just see "no items", so leave a breadcrumb.
            if entries.isEmpty, !out.isEmpty {
                Trace.log("FTP: \(loc.label):\(dir) returned \(out.count) LIST lines none of which parsed")
            }
            return entries
        }.value
    }

    /// Download `loc.path` to a temp file and return its local URL.
    static func download(_ loc: FTPLocation) async throws -> URL {
        let password = Keychain.get(loc.secretAccount)
        return try await Task.detached(priority: .userInitiated) {
            let name = (loc.path as NSString).lastPathComponent
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("anf-ftp", isDirectory: true)
                .appendingPathComponent(loc.host, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let local = dir.appendingPathComponent(name.isEmpty ? "download" : name)
            // Drop a copy from a previous open: curl would happily leave a stale
            // file in place if this transfer dies, and we'd then "succeed" on it.
            try? FileManager.default.removeItem(at: local)
            let out = runCurl(loc, path: loc.path, password: password,
                              maxTime: 300, output: local.path, maxLines: 200)
            if let err = out.first(where: { $0.hasPrefix("curl:") }) {
                throw FTPError.message(friendlyError(err, host: loc.host))
            }
            guard FileManager.default.fileExists(atPath: local.path) else {
                throw FTPError.message(L("Couldn’t download ‘\(name)’.", "‘\(name)’ 다운로드에 실패했습니다."))
            }
            return local
        }.value
    }

    /// One curl run, with the FTPS fallback described on `needsControlOnlyTLS`.
    private static func runCurl(_ loc: FTPLocation, path: String, password: String?,
                                maxTime: Int, output: String?, maxLines: Int) -> [String] {
        func attempt(controlOnlyTLS: Bool) -> [String] {
            ExternalTools.run(
                curlPath, ["--config", "-"],
                stdin: config(for: loc, path: path, password: password, maxTime: maxTime,
                              output: output, controlOnlyTLS: controlOnlyTLS),
                env: ["LC_ALL": "C"], maxLines: maxLines, timeout: TimeInterval(maxTime + 10))
        }
        let out = attempt(controlOnlyTLS: false)
        guard loc.isTLS, let err = out.first(where: { $0.hasPrefix("curl:") }),
              needsControlOnlyTLS(err) else { return out }
        Trace.log("FTP: \(loc.label) refused the encrypted data connection (\(err)) — retrying with only the control channel encrypted")
        return attempt(controlOnlyTLS: true)
    }

    /// Whether an FTPS failure is the data-channel one worth retrying without
    /// data encryption.
    ///
    /// macOS's curl is built on SecureTransport, which cannot resume the control
    /// connection's TLS session on the data connection — and servers configured
    /// with `require_ssl_reuse` (vsftpd's default, test.rebex.net, …) reject the
    /// transfer with 425 for exactly that reason. The retry keeps the *login*
    /// encrypted and sends only the listing/file in the clear, which beats FTPS
    /// being unusable on those servers. It is logged, never silent.
    static func needsControlOnlyTLS(_ error: String) -> Bool {
        error.contains("425") || curlCode(error) == 18
    }

    // MARK: - Request building (pure)

    /// A curl config file for one request (`curl --config -`).
    static func config(for loc: FTPLocation, path: String, password: String?,
                       maxTime: Int, output: String? = nil,
                       controlOnlyTLS: Bool = false) -> String {
        var lines = [
            "silent",
            "show-error",
            // ExternalTools sends stderr to /dev/null (ET-001), so fold curl's
            // error text into stdout — otherwise every failure is a silent blank.
            "stderr = \"-\"",
            "connect-timeout = 12",
            "max-time = \(maxTime)",
            // Pin the protocol: a malicious/misconfigured server must not be able
            // to redirect an FTP browse into http(s) or file://.
            "proto = \"=ftp,ftps\"",
        ]
        // Explicit TLS: keep the ftp:// URL and require AUTH TLS before login, so
        // the password never crosses the wire in the clear. `ftp-ssl-control` is
        // the fallback for servers that refuse our data connection — see
        // needsControlOnlyTLS; the login stays encrypted either way.
        if loc.isTLS { lines.append(controlOnlyTLS ? "ftp-ssl-control" : "ssl-reqd") }
        if let user = loc.user {
            lines.append("user = \(quote(user + ":" + (password ?? "")))")
        }
        if let output { lines.append("output = \(quote(output))") }
        lines.append("url = \(quote(requestURL(loc, path: path)))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The URL curl fetches. Always `ftp://` — FTPS is requested with `ssl-reqd`
    /// rather than an `ftps://` URL (that would mean *implicit* TLS on port 990,
    /// which almost no server speaks). The login goes in the config, not here.
    static func requestURL(_ loc: FTPLocation, path: String) -> String {
        var c = URLComponents()
        c.scheme = "ftp"
        c.host = loc.host
        c.port = loc.port
        c.path = path.hasPrefix("/") ? path : "/" + path
        return c.string ?? "ftp://\(loc.host)/"
    }

    /// curl's config parser reads a double-quoted value with backslash escapes —
    /// anything else (a password with a `"` in it) would silently truncate.
    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default:   out.append(ch)
            }
        }
        return out + "\""
    }

    // MARK: - Errors

    /// Turn `curl: (67) Access denied` into something that says what to do.
    static func friendlyError(_ line: String, host: String) -> String {
        switch curlCode(line) {
        case 6:
            return L("Couldn’t find the server ‘\(host)’.", "‘\(host)’ 서버를 찾을 수 없습니다.")
        case 7:
            return L("Couldn’t connect to ‘\(host)’. Check the address and port.",
                     "‘\(host)’에 연결하지 못했습니다. 주소와 포트를 확인하세요.")
        case 9, 78:
            return L("That folder or file isn’t available on ‘\(host)’.",
                     "‘\(host)’에서 해당 폴더나 파일에 접근할 수 없습니다.")
        case 28:
            return L("‘\(host)’ timed out.", "‘\(host)’ 연결이 시간을 초과했습니다.")
        case 60:
            return L("The TLS certificate of ‘\(host)’ couldn’t be verified.",
                     "‘\(host)’의 TLS 인증서를 확인할 수 없습니다.")
        case 67:
            return L("‘\(host)’ rejected the login. Check the user name and password.",
                     "‘\(host)’ 로그인이 거부되었습니다. 사용자 이름과 비밀번호를 확인하세요.")
        default:
            return line
        }
    }

    /// The `NN` out of `curl: (NN) …`.
    static func curlCode(_ line: String) -> Int? {
        guard let open = line.firstIndex(of: "("),
              let close = line[open...].firstIndex(of: ")") else { return nil }
        return Int(line[line.index(after: open)..<close])
    }

    // MARK: - LIST parsing (pure)

    /// One line of an FTP `LIST` response. Servers answer in one of two dialects:
    /// Unix `ls -l` (the vast majority) or MS-DOS/IIS. Returns nil for banners,
    /// "total 12" headers and anything else that isn't an entry.
    static func parse(_ raw: String) -> RemoteEntry? {
        // LIST lines end with CRLF; ExternalTools splits on \n only, so the \r is
        // still attached and would otherwise become part of the file name.
        var line = raw
        while line.hasSuffix("\r") || line.hasSuffix("\n") { line.removeLast() }
        return parseUnix(line) ?? parseDOS(line)
    }

    /// `drwxr-xr-x   2 ftp  ftp   4096 Aug 20 09:12 photos`
    /// The owner/group columns are `{1,2}` because some servers omit the group.
    private static let unixRE = try? NSRegularExpression(pattern:
        #"^([dlbcps\-])[rwxXsStT\-]{9}[@+\.]?\s+\d+\s+(?:\S+\s+){1,2}(\d+)\s+"# +
        #"(\w{3}\s+\d{1,2}\s+(?:\d{1,2}:\d{2}|\d{4}))\s+(.+)$"#)

    private static func parseUnix(_ line: String) -> RemoteEntry? {
        guard let re = unixRE,
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let typeR = Range(m.range(at: 1), in: line),
              let sizeR = Range(m.range(at: 2), in: line),
              let dateR = Range(m.range(at: 3), in: line),
              let nameR = Range(m.range(at: 4), in: line) else { return nil }
        let type = String(line[typeR])
        var name = String(line[nameR])
        let isSymlink = type == "l"
        if isSymlink, let arrow = name.range(of: " -> ") {   // strip "link -> target"
            name = String(name[..<arrow.lowerBound])
        }
        guard !name.isEmpty else { return nil }
        return RemoteEntry(name: name, isDir: type == "d", isSymlink: isSymlink,
                           size: Int64(line[sizeR]) ?? 0,
                           modified: ListingDate.parse(String(line[dateR])))
    }

    /// `08-20-26  09:12AM       <DIR>          photos` (IIS and friends).
    private static let dosRE = try? NSRegularExpression(pattern:
        #"^(\d{2})-(\d{2})-(\d{2,4})\s+(\d{1,2}):(\d{2})([AaPp])[Mm]\s+(<DIR>|\d+)\s+(.+)$"#)

    private static func parseDOS(_ line: String) -> RemoteEntry? {
        guard let re = dosRE,
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func field(_ i: Int) -> String {
            Range(m.range(at: i), in: line).map { String(line[$0]) } ?? ""
        }
        let name = field(8)
        guard !name.isEmpty, let month = Int(field(1)), let day = Int(field(2)),
              let hour12 = Int(field(4)), let minute = Int(field(5)) else { return nil }
        let sizeField = field(7)
        let isDir = sizeField == "<DIR>"
        var c = DateComponents()
        c.year = dosYear(field(3))
        c.month = month
        c.day = day
        // 12AM is midnight and 12PM is noon — the modulo has to come first.
        c.hour = (hour12 % 12) + (field(6).lowercased() == "p" ? 12 : 0)
        c.minute = minute
        let modified = Calendar(identifier: .gregorian).date(from: c) ?? .distantPast
        return RemoteEntry(name: name, isDir: isDir, isSymlink: false,
                           size: isDir ? 0 : (Int64(sizeField) ?? 0), modified: modified)
    }

    /// DOS listings use a two-digit year. Pivot at 70, the same window `strptime`
    /// uses, so "99" is 1999 and "26" is 2026.
    static func dosYear(_ raw: String) -> Int? {
        guard let y = Int(raw) else { return nil }
        if raw.count > 2 { return y }
        return y < 70 ? 2000 + y : 1900 + y
    }
}

enum FTPError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}
