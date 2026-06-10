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
