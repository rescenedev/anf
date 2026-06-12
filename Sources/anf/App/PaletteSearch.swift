import AppKit

enum PaletteSearch {
    // MARK: - fd (filenames, scoped to `root` and below)

    static func fdNames(root: URL, needle: String, cap: Int) -> [URL]? {
        guard let fd = ExternalTools.path("fd") else { return nil }
        let lines = ExternalTools.run(fd, [
            "--color=never", "--absolute-path", "--no-ignore",
            "--fixed-strings", "--type", "f", "--type", "d",
            "--max-results", "\(cap)", needle, root.path
        ], maxLines: cap)
        return lines.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - mdfind fallback (Spotlight, scoped to the folder via -onlyin)

    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// NFC + NFD forms of `s`, de-duplicated by raw bytes. Korean from the IME vs.
    /// on-disk text can differ only by normalization; byte matchers (rg) need both.
    /// NOTE: compare UTF-8 bytes, not the strings — Swift `==` is canonical, so
    /// `nfc == nfd` is always true for canonically equivalent forms.
    static func normalizationVariants(_ s: String) -> [String] {
        let nfc = s.precomposedStringWithCanonicalMapping
        let nfd = s.decomposedStringWithCanonicalMapping
        return Array(nfc.utf8) == Array(nfd.utf8) ? [nfc] : [nfc, nfd]
    }

    /// Filenames via Spotlight, scoped to `root`. Used when fd is not installed —
    /// `-onlyin` keeps it fast and free of global noise (Nix Store, system files).
    static func mdfindNames(root: URL, needle: String, cap: Int) -> [URL]? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/mdfind") else { return nil }
        let cmd = "mdfind -onlyin \(shQuote(root.path)) -name \(shQuote(needle)) 2>/dev/null | head -n \(cap)"
        let lines = ExternalTools.run("/bin/sh", ["-c", cmd], maxLines: cap, timeout: 3.0)
        return lines.map { URL(fileURLWithPath: $0) }
    }

    /// File contents via Spotlight, scoped to `root`. Fallback for ripgrep.
    static func mdfindContent(root: URL, needle: String, cap: Int) -> [URL] {
        let clean = needle.replacingOccurrences(of: "'", with: "")
        guard !clean.isEmpty,
              FileManager.default.isExecutableFile(atPath: "/usr/bin/mdfind") else { return [] }
        let pred = "kMDItemTextContent == '*\(clean)*'cd"
        let cmd = "mdfind -onlyin \(shQuote(root.path)) \(shQuote(pred)) 2>/dev/null | head -n \(cap)"
        let lines = ExternalTools.run("/bin/sh", ["-c", cmd], maxLines: cap, timeout: 3.0)
        return lines.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - FileManager fallback (filenames, last resort)

    static func fmNames(root: URL, needle: String,
                        maxDepth: Int, cap: Int) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var urls: [URL] = []
        for case let url as URL in en {
            if en.level > maxDepth { en.skipDescendants(); continue }
            if Task.isCancelled || urls.count >= cap { break }
            if url.lastPathComponent.localizedCaseInsensitiveContains(needle) {
                urls.append(url)
            }
        }
        return urls
    }

    // MARK: - ripgrep (content)

    static func rgContent(root: URL, needle: String, cap: Int) -> [URL]? {
        guard let rg = ExternalTools.path("rg") else { return nil }
        // Skip big files and cap the time so content search never hangs. Search
        // both Unicode normalizations (rg byte-matches; IME text may be NFC/NFD).
        var args = ["--color=never", "--files-with-matches", "--smart-case",
                    "--max-count", "1", "--no-messages", "--max-filesize", "2M"]
        for v in normalizationVariants(needle) { args += ["-e", v] }
        args += [root.path]
        let lines = ExternalTools.run(rg, args, maxLines: cap, timeout: 3.0)
        return lines.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Document body search (hwpx / docx / pptx / xlsx / pdf)

    /// ripgrep treats these as binary (ZIP+XML — or PDF), so search their
    /// bodies via DocumentText (unzip for office files, PDFKit for PDFs) and
    /// match in Swift. Matching is done in Swift (not piped to `grep`) for two
    /// reasons: Swift string comparison is Unicode-canonical, so it's immune to
    /// NFC/NFD differences between IME input and document text; and it avoids
    /// depending on a `grep` that may be shadowed or misconfigured in the app's
    /// spawn environment. Bounded by file count + per-file page caps so it
    /// stays fast.
    static func docContent(root: URL, needle: String, cap: Int) -> [URL] {
        guard let fd = ExternalTools.path("fd"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip") else { return [] }
        var args = ["--color=never", "--absolute-path", "--type", "f"]
        for ext in ["hwpx", "docx", "pptx", "xlsx", "pdf"] { args += ["--extension", ext] }
        let scanLimit = 80
        args += ["--max-results", "\(scanLimit)", ".", root.path]
        let files = ExternalTools.run(fd, args, maxLines: scanLimit, timeout: 2.0)
        guard !files.isEmpty else { return [] }

        let lock = NSLock()
        var matched: [URL] = []
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            lock.lock(); let enough = matched.count >= cap; lock.unlock()
            if enough { return }
            let url = URL(fileURLWithPath: files[i])
            // Extract only the text-bearing parts and match in Swift (Unicode-
            // canonical, immune to NFC/NFD differences). Bodies are cached by
            // mtime, so only the first query of a session pays for extraction.
            guard let body = DocumentTextCache.shared.text(for: url) else { return }
            if body.localizedCaseInsensitiveContains(needle) {
                lock.lock(); if matched.count < cap { matched.append(url) }; lock.unlock()
            }
        }
        return matched
    }
}
