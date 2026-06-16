import Foundation
@testable import anf

private func item(_ name: String, dir: Bool, size: Int64 = 0) -> FileItem {
    FileItem.remote(url: URL(fileURLWithPath: "/x/\(name)"),
                    name: name, isDir: dir, isSymlink: false,
                    size: size, modified: .distantPast)
}

func runSortTests() {
    T.group("FileSystemService.sorted") {
        let fs = FileSystemService()

        let mixed = [item("b.txt", dir: false), item("Apple", dir: true),
                     item("a.txt", dir: false), item("zoo", dir: true)]
        T.equal(fs.sorted(mixed, by: SortOrder(key: .name, ascending: true)).map(\.name),
                ["Apple", "zoo", "a.txt", "b.txt"], "dirs first, then name")

        let letters = [item("a", dir: false), item("c", dir: false), item("b", dir: false)]
        T.equal(fs.sorted(letters, by: SortOrder(key: .name, ascending: false)).map(\.name),
                ["c", "b", "a"], "descending name")

        let sizes = [item("big", dir: false, size: 900), item("small", dir: false, size: 10),
                     item("mid", dir: false, size: 100)]
        T.equal(fs.sorted(sizes, by: SortOrder(key: .size, ascending: true)).map(\.name),
                ["small", "mid", "big"], "sort by size")

        let docs = [item("report.md", dir: false), item("notes.txt", dir: false),
                    item("old report.txt", dir: false)]
        let filtered = fs.filteredSorted(docs, filter: "report", by: SortOrder())
        T.equal(Set(filtered.map(\.name)), ["report.md", "old report.txt"], "filter by name substring")
    }

    T.group("natural numeric sort (issue #34 — fastNameSort path)") {
        let fs = FileSystemService()
        func names(_ ns: [String], asc: Bool = true) -> [String] {
            fs.filteredSorted(ns.map { item($0, dir: false) },
                              filter: "", by: SortOrder(key: .name, ascending: asc)).map(\.name)
        }
        T.equal(names(["1.txt", "10.txt", "2.txt", "11.txt", "21.txt", "3.txt"]),
                ["1.txt", "2.txt", "3.txt", "10.txt", "11.txt", "21.txt"],
                "numbers sort naturally (not 1, 10, 11, 2)")
        T.equal(names(["file2", "file10", "file1"]),
                ["file1", "file2", "file10"], "numeric suffix sorts naturally")
        T.equal(names(["1", "10", "2", "3"], asc: false),
                ["10", "3", "2", "1"], "descending is natural too")
        T.equal(names(["1", "01", "2", "02"]),
                ["1", "01", "2", "02"], "leading-zero tiebreak: bare number before zero-padded")
        // Non-numeric names keep their existing (byte/Unicode) order — Hangul is
        // dictionary-ordered in NFC, so this must be unchanged.
        T.equal(names(["나", "가", "다"]), ["가", "나", "다"], "Hangul order unchanged")
        // Folders still float to the top regardless of natural keys.
        let mix = [item("10", dir: false), item("2", dir: true), item("1", dir: true)]
        T.equal(fs.filteredSorted(mix, filter: "", by: SortOrder(key: .name, ascending: true)).map(\.name),
                ["1", "2", "10"], "dirs first (1,2), then files (10)")
    }
}
