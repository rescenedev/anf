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
}
