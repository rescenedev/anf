import Foundation

/// User scripts (#103 follow-up: "스크립트를 저장해두고 단축키로 불러서 실행") —
/// plain files dropped into Application Support/anf/scripts. The ⌘K palette
/// lists them by name; activating one runs it in the built-in terminal at the
/// active folder, so cwd-dependent one-liners (batch ffmpeg conversion etc.)
/// just work and show their output live.
enum UserScripts {
    /// Test seam: when set, `directory` points here instead of App Support.
    nonisolated(unsafe) static var directoryOverride: URL?

    static var directory: URL {
        if let o = directoryOverride { return o }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("anf/scripts", isDirectory: true)
    }

    /// Create the folder eagerly (palette open) — an existing empty folder is
    /// how users discover where scripts go.
    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
    }

    /// Visible regular files, name-sorted. No extension filter: a script is
    /// whatever the user saved (.sh, .command, extensionless...).
    static func list() -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { directory.appendingPathComponent($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    /// The shell line that runs `script` in the terminal's cwd: executables run
    /// as-is, anything else goes through sh — saving a plain text file must be
    /// enough, chmod +x is not a prerequisite.
    static func command(for script: URL) -> String {
        let quoted = shQuote(script.path)
        return FileManager.default.isExecutableFile(atPath: script.path) ? quoted : "sh \(quoted)"
    }

    static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
