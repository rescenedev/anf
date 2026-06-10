import Foundation

/// Directory loading off the main thread. Stateless + Sendable.
struct FileSystemService: Sendable {

    /// Reads the contents of `url`, prefetching all resource keys in one shot so each
    /// `FileItem` is built without extra stat() calls. Runs on a background task.
    func contents(of url: URL, showHidden: Bool) async -> [FileItem] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
            if !showHidden { options.insert(.skipsHiddenFiles) }

            guard let urls = try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(FileItem.resourceKeys),
                options: options
            ) else { return [] }

            return urls.compactMap { FileItem(url: $0) }
        }.value
    }

    /// Fast first-pass listing: only the keys needed to render names and sort
    /// (folder-ness), so a directory with tens of thousands of entries paints
    /// almost instantly. The full `contents(of:)` pass enriches it afterwards.
    func contentsFast(of url: URL, showHidden: Bool) async -> [FileItem] {
        await Task.detached(priority: .userInitiated) {
            // Native bulk read (no per-item stat). Falls back to FileManager only
            // if getattrlistbulk is unavailable for this volume.
            if let entries = FastDirRead.list(path: url.path) {
                let parentPath = url.path
                // Build the items across all cores — URL construction alone is
                // ~100ms for 26k entries, so parallelising it is a real win.
                var out = [FileItem?](repeating: nil, count: entries.count)
                out.withUnsafeMutableBufferPointer { buf in
                    DispatchQueue.concurrentPerform(iterations: entries.count) { i in
                        let e = entries[i]
                        if showHidden || !e.isHidden {
                            buf[i] = FileItem.fast(parentPath: parentPath, entry: e)
                        }
                    }
                }
                return out.compactMap { $0 }
            }
            let fm = FileManager.default
            var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
            if !showHidden { options.insert(.skipsHiddenFiles) }
            guard let urls = try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(FileItem.fastKeys),
                options: options
            ) else { return [] }
            return urls.compactMap { FileItem(fastURL: $0) }
        }.value
    }

    /// Recursively sum the allocated size of everything under `url`. Off the main thread.
    func directorySize(of url: URL) async -> Int64 {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
            guard let en = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                         options: [.skipsHiddenFiles]) else { return 0 }
            var total: Int64 = 0
            for case let f as URL in en {
                let v = try? f.resourceValues(forKeys: keys)
                if v?.isRegularFile == true {
                    total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
                }
            }
            return total
        }.value
    }

    /// Filter by name (if any) then sort. Pure + Sendable so it can run off the
    /// main thread for large directories.
    func filteredSorted(_ items: [FileItem], filter: String, by order: SortOrder) -> [FileItem] {
        var result = items
        if !filter.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        }
        // Fast path for the common name sort: precompute a lowercase UTF-8 key once
        // per item and order by raw bytes. For NFC text (incl. Hangul, which is in
        // dictionary order in Unicode) this matches expectations and is ~10× faster
        // than `localizedStandardCompare` per comparison — the difference between a
        // smooth and a janky 27k-entry folder.
        if order.key == .name {
            let asc = order.ascending
            let keyed = result.map { (item: $0, key: Array($0.name.lowercased().utf8)) }
            let out = keyed.sorted { a, b in
                let ad = a.item.isBrowsableContainer, bd = b.item.isBrowsableContainer
                if ad != bd { return ad }
                if a.key == b.key { return false }
                let less = a.key.lexicographicallyPrecedes(b.key)
                return asc ? less : !less
            }
            return out.map(\.item)
        }
        return sorted(result, by: order)
    }

    /// Sort a snapshot. Directories always float to the top, matching Finder behaviour.
    func sorted(_ items: [FileItem], by order: SortOrder) -> [FileItem] {
        items.sorted { a, b in
            if a.isBrowsableContainer != b.isBrowsableContainer {
                return a.isBrowsableContainer
            }
            let result: Bool
            switch order.key {
            case .name:
                result = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .dateModified:
                result = a.modified < b.modified
            case .size:
                result = a.size < b.size
            case .kind:
                let ka = a.contentType?.localizedDescription ?? a.ext
                let kb = b.contentType?.localizedDescription ?? b.ext
                result = ka.localizedStandardCompare(kb) == .orderedAscending
            }
            return order.ascending ? result : !result
        }
    }
}
