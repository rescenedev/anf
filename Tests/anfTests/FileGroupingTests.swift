import Foundation
@testable import anf

private func gi(_ name: String, dir: Bool = false, size: Int64 = 0, modified: Date = .distantPast) -> FileItem {
    FileItem.remote(url: URL(fileURLWithPath: "/g/\(name)"), name: name,
                    isDir: dir, isSymlink: false, size: size, modified: modified)
}

/// `FileGrouping.group` reorders an already-sorted list into buckets and reports
/// contiguous ranges. Pure logic — the Arrange-By feature had no coverage.
func runFileGroupingTests() {
    T.group(".none leaves the list untouched") {
        let items = [gi("a.txt"), gi("b.txt")]
        let r = FileGrouping.group(items, by: .none)
        T.equal(r.items.map(\.name), ["a.txt", "b.txt"], "items unchanged")
        T.expect(r.groups.isEmpty, "no groups for .none")
    }

    T.group("empty input → empty groups") {
        let r = FileGrouping.group([], by: .kind)
        T.expect(r.items.isEmpty && r.groups.isEmpty, "nothing in, nothing out")
    }

    T.group("by kind: folders lead, ranges contiguous & complete") {
        let items = [gi("b", dir: true), gi("a", dir: true), gi("z.txt"), gi("y.pdf")]
        let r = FileGrouping.group(items, by: .kind)
        T.equal(r.items.count, items.count, "no items lost")
        // First bucket is the folders, in the input order (stable within bucket).
        T.expect(r.groups.first != nil, "has at least one group")
        if let first = r.groups.first {
            let firstSlice = Array(r.items[first.range])
            T.expect(firstSlice.allSatisfy { $0.isBrowsableContainer }, "folders bucket leads")
            T.equal(firstSlice.map(\.name), ["b", "a"], "input order preserved within bucket")
        }
        // Ranges tile the whole array with no gaps or overlaps.
        var cursor = 0
        for g in r.groups { T.equal(g.range.lowerBound, cursor, "range \(g.title) is contiguous"); cursor = g.range.upperBound }
        T.equal(cursor, r.items.count, "ranges cover every item")
    }

    T.group("by size: every item lands in exactly one bucket") {
        let items = [gi("tiny", size: 10), gi("big", size: 5_000_000), gi("mid", size: 50_000)]
        let r = FileGrouping.group(items, by: .size)
        T.equal(r.items.count, 3, "all items kept")
        let total = r.groups.reduce(0) { $0 + $1.range.count }
        T.equal(total, 3, "buckets partition the items")
    }
}
