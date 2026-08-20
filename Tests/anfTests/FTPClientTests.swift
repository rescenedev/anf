import Foundation
@testable import anf

/// FTP browsing: address parsing, the two LIST dialects servers answer in, and
/// the curl config we hand over on stdin. All pure — no server is contacted.
func runFTPClientTests() {
    T.group("FTP address parsing") {
        let plain = FTPLocation.parse(URL(string: "ftp://files.example.com/pub/docs")!)
        T.equal(plain?.host, "files.example.com", "host")
        T.equal(plain?.path, "/pub/docs", "path")
        T.isNil(plain?.user, "no user → anonymous")
        T.isNil(plain?.port, "no port → server default")
        T.equal(plain?.isTLS, false, "ftp:// is plain")

        let full = FTPLocation.parse(URL(string: "ftps://bob@files.example.com:2121/in")!)
        T.equal(full?.user, "bob", "user")
        T.equal(full?.port, 2121, "port")
        T.equal(full?.isTLS, true, "ftps:// asks for TLS")

        T.equal(FTPLocation.parse(URL(string: "ftp://host")!)?.path, "/",
                "bare host browses the root")
        // parse() doubles as the "is this FTP?" test, so every other scheme must
        // come back nil — sftp in particular routes to a different client.
        for other in ["sftp://host/x", "smb://host/share", "https://host/x", "file:///tmp"] {
            T.isNil(FTPLocation.parse(URL(string: other)!), "\(other) is not FTP")
        }
    }

    T.group("FTP address rebuilding") {
        let loc = FTPLocation(scheme: "ftps", host: "h.example", port: 2121, user: "bob", path: "/a")
        let child = loc.url(path: "/a/My Docs/보고서.txt")
        T.equal(child.scheme, "ftps", "scheme survives")
        T.equal(child.port, 2121, "port survives")
        T.equal(child.user, "bob", "user survives")
        // Round-tripping through the URL is what pane navigation actually does:
        // a name with a space or Hangul must come back byte-identical.
        T.equal(FTPLocation.parse(child)?.path, "/a/My Docs/보고서.txt", "path round-trips")
        T.equal(loc.serverURL.absoluteString, loc.url(path: "/").absoluteString,
                "serverURL is the login at the root")

        // Keychain account is path-free: one login serves the whole server.
        let deep = FTPLocation(scheme: "ftps", host: "h.example", port: 2121, user: "bob", path: "/z/z")
        T.equal(loc.secretAccount, deep.secretAccount, "password is per-login, not per-folder")
        T.equal(loc.secretAccount, "ftp:bob@h.example:2121", "account key")
        T.equal(FTPLocation(scheme: "ftp", host: "h", port: nil, user: nil, path: "/").secretAccount,
                "ftp:anonymous@h", "anonymous account key")
        T.equal(loc.label, "bob@h.example:2121", "label")
        T.equal(FTPLocation(scheme: "ftp", host: "h", port: nil, user: nil, path: "/").label, "h",
                "anonymous label is just the host")
    }

    T.group("FTP LIST parsing — Unix dialect") {
        let dir = FTPClient.parse("drwxr-xr-x   2 ftp      ftp          4096 Aug 20 09:12 photos")
        T.equal(dir?.name, "photos", "dir name")
        T.equal(dir?.isDir, true, "dir flag")

        let file = FTPClient.parse("-rw-r--r--   1 1000     1000      1048576 Jan  2  2025 archive.zip")
        T.equal(file?.name, "archive.zip", "file name")
        T.equal(file?.size, 1_048_576, "size")
        T.equal(file?.isDir, false, "file is not a dir")

        // Some servers print owner only, with no group column.
        let noGroup = FTPClient.parse("-rw-r--r--   1 owner            1234 Aug 20 09:12 notes.txt")
        T.equal(noGroup?.name, "notes.txt", "owner-only line still parses")
        T.equal(noGroup?.size, 1234, "owner-only size")

        let spaced = FTPClient.parse("-rw-r--r--   1 ftp ftp   12 Aug 20 09:12 my long name.txt")
        T.equal(spaced?.name, "my long name.txt", "spaces belong to the name")

        let link = FTPClient.parse("lrwxrwxrwx   1 ftp ftp    7 Aug 20 09:12 latest -> v2.txt")
        T.equal(link?.name, "latest", "symlink target is stripped")
        T.equal(link?.isSymlink, true, "symlink flag")

        // LIST is CRLF-terminated and ExternalTools splits on \n only — an
        // unstripped \r would ride along inside every file name.
        T.equal(FTPClient.parse("drwxr-xr-x 2 ftp ftp 4096 Aug 20 09:12 photos\r")?.name,
                "photos", "trailing CR is stripped")

        for junk in ["total 12", "220 Welcome to the FTP service", "", "drwxr-xr-x"] {
            T.isNil(FTPClient.parse(junk), "non-entry line ‘\(junk)’ is skipped")
        }
    }

    // Verbatim lines from ftp.gnu.org, kept as regression cases: real vsftpd
    // output pads the day ("Jan 08"), uses numeric owners, and has names that
    // start with punctuation — each of which broke an earlier draft of the regex.
    T.group("FTP LIST parsing — real server output") {
        let cases: [(String, String, Bool, Int64)] = [
            ("drwxr-xr-x    2 3003     3003         4096 Dec 13  2013 3dldf", "3dldf", true, 4096),
            ("-rw-r--r--    1 3003     65534        1492 Jan 25  2001 =README", "=README", false, 1492),
            ("-rw-r--r--    1 3003     65534        1042 Jan 08  2000 =README-about-.gz-files",
             "=README-about-.gz-files", false, 1042),
            ("drwxrwsr-x    3 0        3003         4096 Aug 14  2003 GNUsBulletins", "GNUsBulletins", true, 4096),
            ("drwxrwxr-x    2 0        3003         4096 Aug 20 04:45 Licenses", "Licenses", true, 4096),
        ]
        for (line, name, isDir, size) in cases {
            guard let e = FTPClient.parse(line) else {
                T.expect(false, "vsftpd line parses: \(name)"); continue
            }
            T.equal(e.name, name, "name: \(name)")
            T.equal(e.isDir, isDir, "isDir: \(name)")
            T.equal(e.size, size, "size: \(name)")
            T.expect(e.modified > Date(timeIntervalSince1970: 0), "date parsed: \(name)")
        }
        // "Jan 08  2000" — a padded day AND a year, the form the time-only
        // formatter must reject so the year isn't silently replaced with today's.
        if let dated = FTPClient.parse(cases[2].0)?.modified {
            T.equal(Calendar(identifier: .gregorian).component(.year, from: dated), 2000,
                    "explicit year wins over the current one")
        }
    }

    T.group("FTP LIST parsing — DOS dialect") {
        let dir = FTPClient.parse("08-20-26  09:12AM       <DIR>          photos")
        T.equal(dir?.name, "photos", "DOS dir name")
        T.equal(dir?.isDir, true, "DOS dir flag")
        T.equal(dir?.size, 0, "DOS dir has no size")

        let file = FTPClient.parse("01-02-99  11:45PM              1048576 archive.zip")
        T.equal(file?.name, "archive.zip", "DOS file name")
        T.equal(file?.size, 1_048_576, "DOS size")

        let cal = Calendar(identifier: .gregorian)
        if let d = FTPClient.parse("08-20-26  12:30AM   10 midnight.txt")?.modified {
            T.equal(cal.component(.year, from: d), 2026, "two-digit year 26 → 2026")
            T.equal(cal.component(.month, from: d), 8, "month")
            T.equal(cal.component(.day, from: d), 20, "day")
            // 12AM is midnight, not noon — the modulo has to run before the +12.
            T.equal(cal.component(.hour, from: d), 0, "12AM is 00:00")
        } else {
            T.expect(false, "DOS midnight line parses")
        }
        if let noon = FTPClient.parse("08-20-26  12:30PM   10 noon.txt")?.modified {
            T.equal(cal.component(.hour, from: noon), 12, "12PM is 12:00")
        } else {
            T.expect(false, "DOS noon line parses")
        }
        T.equal(FTPClient.dosYear("99"), 1999, "99 pivots to 1999")
        T.equal(FTPClient.dosYear("26"), 2026, "26 pivots to 2026")
        T.equal(FTPClient.dosYear("2026"), 2026, "four-digit year passes through")
    }

    T.group("FTP curl config") {
        let anon = FTPLocation(scheme: "ftp", host: "h.example", port: nil, user: nil, path: "/pub")
        let cfg = FTPClient.config(for: anon, path: "/pub/", password: nil, maxTime: 30)
        T.expect(cfg.contains("url = \"ftp://h.example/pub/\""), "url line, trailing slash kept (LIST)")
        T.expect(!cfg.contains("user ="), "anonymous sends no credentials")
        T.expect(!cfg.contains("ssl-reqd"), "plain ftp doesn’t force TLS")
        // A redirect must never be able to walk an FTP browse into another protocol.
        T.expect(cfg.contains("proto = \"=ftp,ftps\""), "protocol is pinned")
        T.expect(cfg.contains("stderr = \"-\""), "errors are folded into stdout so they’re reportable")

        let tls = FTPLocation(scheme: "ftps", host: "h.example", port: 2121, user: "bob", path: "/x")
        let tlsCfg = FTPClient.config(for: tls, path: "/x/y.txt", password: "p@ss\"w",
                                      maxTime: 300, output: "/tmp/a b.txt")
        T.expect(tlsCfg.contains("ssl-reqd"), "ftps requires AUTH TLS")
        T.expect(tlsCfg.contains(#"user = "bob:p@ss\"w""#), "password is escaped for curl’s parser")
        T.expect(tlsCfg.contains(#"output = "/tmp/a b.txt""#), "output path is quoted")
        // FTPS is explicit TLS over the normal FTP URL — an ftps:// URL would mean
        // implicit TLS on 990, which almost no server speaks.
        T.expect(tlsCfg.contains("url = \"ftp://h.example:2121/x/y.txt\""), "port in URL, scheme stays ftp")
        T.expect(!tlsCfg.contains("ftps://"), "no implicit-TLS URL")

        // FTPS fallback: macOS curl can't resume the control TLS session on the
        // data connection, so require_ssl_reuse servers answer 425. The retry
        // keeps the login encrypted and must be reserved for exactly that failure.
        let fallback = FTPClient.config(for: tls, path: "/x/", password: "p",
                                        maxTime: 30, controlOnlyTLS: true)
        T.expect(fallback.contains("ftp-ssl-control"), "fallback encrypts the control channel")
        T.expect(!fallback.contains("ssl-reqd"), "fallback drops full-TLS")
        T.expect(fallback.contains("user ="), "fallback still logs in over TLS")
        T.expect(FTPClient.needsControlOnlyTLS("curl: (18) server did not report OK, got 425"),
                 "425 on the data connection triggers the retry")
        T.expect(!FTPClient.needsControlOnlyTLS("curl: (67) Access denied: 530"),
                 "a rejected login is not retried in the clear")
        T.expect(!FTPClient.needsControlOnlyTLS("curl: (60) certificate problem"),
                 "a certificate failure is not retried in the clear")

        T.equal(FTPClient.quote(#"a\b"c"#), #""a\\b\"c""#, "backslash and quote are escaped")
        T.equal(FTPClient.requestURL(anon, path: "/a b/#c"), "ftp://h.example/a%20b/%23c",
                "path is percent-encoded")
    }

    T.group("FTP error messages") {
        T.equal(FTPClient.curlCode("curl: (67) Access denied: 530"), 67, "code is extracted")
        T.isNil(FTPClient.curlCode("something else"), "non-curl line has no code")
        let login = FTPClient.friendlyError("curl: (67) Access denied: 530", host: "h.example")
        T.expect(login.contains("h.example"), "message names the host")
        T.expect(login != "curl: (67) Access denied: 530", "known code is rewritten for humans")
        // An unknown code still has to say *something* — raw curl beats blank.
        T.equal(FTPClient.friendlyError("curl: (99) weird", host: "h"), "curl: (99) weird",
                "unknown code falls back to curl’s own text")
    }

    T.group("FTP saved servers") {
        let a = FTPServer(FTPLocation(scheme: "ftp", host: "h", port: nil, user: "bob", path: "/one"))
        let b = FTPServer(FTPLocation(scheme: "ftp", host: "h", port: nil, user: "bob", path: "/two"))
        T.equal(a.id, b.id, "same login is the same server whatever folder it points at")
        let other = FTPServer(FTPLocation(scheme: "ftp", host: "h", port: nil, user: "amy", path: "/one"))
        T.expect(a.id != other.id, "a different login is a different server")
        T.equal(a.url.absoluteString, "ftp://bob@h/one", "url keeps the saved folder")
        // Round-trips through UserDefaults — and must never carry a password.
        guard let data = try? JSONEncoder().encode(a),
              let back = try? JSONDecoder().decode(FTPServer.self, from: data) else {
            T.expect(false, "server encodes"); return
        }
        T.equal(back.id, a.id, "decodes back to the same server")
        let json = String(decoding: data, as: UTF8.self).lowercased()
        T.expect(!json.contains("password"), "no password field is persisted")
    }
}

/// Opt-in live check (`ANF_FTP_LIVE=1`, optionally `ANF_FTP_URL=ftp://…`): drives
/// the real curl against a real server, which the rest of the suite never does —
/// CI and nightly stay hermetic and offline.
func runFTPLiveCheck() {
    guard ProcessInfo.processInfo.environment["ANF_FTP_LIVE"] == "1" else { return }
    let raw = ProcessInfo.processInfo.environment["ANF_FTP_URL"] ?? "ftp://ftp.gnu.org/gnu/"
    guard let url = URL(string: raw), let loc = FTPLocation.parse(url) else {
        T.expect(false, "ANF_FTP_URL is a valid ftp address"); return
    }
    // A login-protected server can't be checked from here: the password is in the
    // Keychain and Keychain.get refuses to prompt (it would hang a headless run),
    // so a re-signed test binary reads nothing and the server answers 530. Say so
    // instead of reporting a failure that isn't one.
    if let user = loc.user, !user.isEmpty, Keychain.get(loc.secretAccount) == nil {
        print("  live: skipped — no Keychain password for \(loc.secretAccount) " +
              "(store it from the app; the test binary can’t read it back)")
        return
    }
    T.group("FTP live listing (\(loc.label))") {
        // FTPClient does its work on a detached task, so blocking here is safe —
        // nothing it awaits needs the main thread to make progress.
        let sem = DispatchSemaphore(value: 0)
        var entries: [RemoteEntry] = []
        var failure: String?
        Task {
            do { entries = try await FTPClient.list(loc) }
            catch { failure = error.localizedDescription }
            sem.signal()
        }
        sem.wait()
        if let failure { T.expect(false, "live listing failed: \(failure)"); return }
        T.expect(!entries.isEmpty, "live listing returned entries")
        T.expect(entries.contains { $0.isDir }, "live listing has at least one directory")
        T.expect(entries.allSatisfy { !$0.name.isEmpty && !$0.name.contains("\r") },
                 "live names are clean")
        print("  live: \(entries.count) entries from \(raw)")

        // Downloading is the other half of browsing (double-click opens a file),
        // so pull the smallest regular file the listing offered. Symlinks are
        // excluded: LIST reports their *target string* length as the size and the
        // target is often a directory, which has nothing to download.
        guard let small = entries.filter({ !$0.isDir && !$0.isSymlink && $0.size > 0 })
            .min(by: { $0.size < $1.size }) else { return }
        let base = loc.path.hasSuffix("/") ? loc.path : loc.path + "/"
        let file = FTPLocation(scheme: loc.scheme, host: loc.host, port: loc.port,
                               user: loc.user, path: base + small.name)
        let dsem = DispatchSemaphore(value: 0)
        var local: URL?
        var dlFailure: String?
        Task {
            do { local = try await FTPClient.download(file) }
            catch { dlFailure = error.localizedDescription }
            dsem.signal()
        }
        dsem.wait()
        if let dlFailure {
            T.expect(false, "live download of \(FTPClient.requestURL(file, path: file.path)) failed: \(dlFailure)")
            return
        }
        guard let local, let data = try? Data(contentsOf: local) else {
            T.expect(false, "downloaded file is readable"); return
        }
        T.equal(Int64(data.count), small.size, "downloaded \(small.name) matches the listed size")
        try? FileManager.default.removeItem(at: local)
    }
}

/// The remote-URL builder is shared by SFTP and FTP navigation: a breadcrumb or a
/// listing row must land on the same server it came from.
@MainActor
func runRemoteURLTests() {
    T.group("remote URL rebuilding by scheme") {
        let ftp = URL(string: "ftps://bob@h.example:2121/a/b")!
        let up = BrowserModel.remoteURL(like: ftp, path: "/a")
        T.equal(up.absoluteString, "ftps://bob@h.example:2121/a", "FTP keeps user, port and scheme")

        // SFTP hosts are ~/.ssh/config aliases that may contain "/" or "@" (#70),
        // so they stay percent-encoded in the host position.
        let sftp = URL(string: "sftp://homelab%2Fnuc/srv")!
        let sftpUp = BrowserModel.remoteURL(like: sftp, path: "/")
        T.equal(sftpUp.host, "homelab/nuc", "SFTP alias survives the rebuild")
        T.equal(sftpUp.scheme, "sftp", "SFTP scheme is unchanged")

        let m = BrowserModel(start: ftp)
        T.expect(m.isRemote, "ftps:// is a remote location")
        T.expect(!m.isSFTP, "ftps:// is not the SSH-backed scheme")
        T.equal(m.ftpLocation?.host, "h.example", "model exposes the parsed FTP location")
        T.equal(m.remotePath, "/a/b", "remote path")
        T.expect(m.canGoUp, "not at the root yet")

        let local = BrowserModel(start: URL(fileURLWithPath: NSHomeDirectory()))
        T.expect(!local.isRemote, "a local folder is not remote")
        T.isNil(local.ftpLocation, "a local folder has no FTP location")
    }
}
