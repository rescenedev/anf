import Foundation

/// Locates and runs optional command-line tools (fd, ripgrep, fzf). A GUI app
/// launched from Finder does not inherit the user's shell `PATH`, so binaries are
/// found by probing the common install locations directly.
enum ExternalTools {
    private static let searchDirs: [String] = {
        let home = NSHomeDirectory()
        var dirs = [
            "/opt/homebrew/bin",      // Apple-silicon Homebrew
            "/usr/local/bin",         // Intel Homebrew
            "/usr/bin", "/bin",
            "\(home)/.cargo/bin",     // cargo-installed (fd/rg)
            "\(home)/.local/bin",
            "/opt/local/bin",         // MacPorts
            "/opt/zerobrew/prefix/bin",   // zerobrew prefix
            "/run/current-system/sw/bin", // Nix (system)
            "\(home)/.nix-profile/bin",   // Nix (user profile)
        ]
        // A Finder-launched app gets a minimal PATH, so also read the user's
        // login-shell PATH — this picks up non-standard prefixes (custom brews,
        // asdf, mise, etc.).
        dirs += loginShellPathDirs()
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }()

    private static func loginShellPathDirs() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":").map(String.init)
    }

    /// Absolute path of an executable, or nil if not installed.
    static func path(_ name: String) -> String? {
        for dir in searchDirs {
            let p = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func available(_ name: String) -> Bool { path(name) != nil }

    /// Run `exe args…`, returning stdout split into lines (capped). Reads stdout
    /// fully before waiting to avoid pipe-buffer deadlock on large output.
    @discardableResult
    static func run(_ exe: String, _ args: [String],
                    cwd: URL? = nil, stdin: String? = nil,
                    maxLines: Int = 500, timeout: TimeInterval? = nil) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            do { try process.run() } catch { return [] }
            if let data = stdin.data(using: .utf8) {
                inPipe.fileHandleForWriting.write(data)
            }
            try? inPipe.fileHandleForWriting.close()
        } else {
            do { try process.run() } catch { return [] }
        }

        // Kill the process if it outruns the timeout — return whatever it produced
        // so a slow scan never hangs the palette. terminate() on an exited process
        // is a harmless no-op.
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [process] in
                if process.isRunning { process.terminate() }
            }
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Lossy UTF-8 decode: tools that emit some binary bytes (e.g. `unzip -p`
        // over a whole archive) must not nuke the entire output to nil — invalid
        // bytes become U+FFFD and valid text is preserved.
        let s = String(decoding: data, as: UTF8.self)
        return s.split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(maxLines).map(String.init)
    }
}
