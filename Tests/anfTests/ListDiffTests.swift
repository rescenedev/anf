import Foundation
@testable import anf

/// Regression guard for the sort-flip beachball: the table's Myers diff is
/// O(N·D), and a re-sort of a big folder is its worst case (same IDs, edit
/// distance ≈ 2N). The strategy function must route every reorder to a plain
/// reload and reserve the diff for small membership changes.
func runListDiffTests() {
    let ids = (0..<26_000).map { URL(fileURLWithPath: "/kr/folder-\($0)") }

    T.group("ListDiff.strategy") {
        T.expect(ListDiff.strategy(old: ids, new: ids) == .visibleRefresh,
                 "identical listing → refresh visible rows only")
        T.expect(ListDiff.strategy(old: [], new: ids) == .reload,
                 "first load → reload")
        T.expect(ListDiff.strategy(old: ids, new: ids.reversed()) == .reload,
                 "sort flip (pure reorder) must NEVER reach the Myers diff")
        T.expect(ListDiff.strategy(old: ids, new: ids.shuffled()) == .reload,
                 "arbitrary reorder → reload")
        T.expect(ListDiff.strategy(old: ids, new: Array(ids.dropFirst(13_500))) == .reload,
                 "mostly-different listing (navigation) → reload")

        var oneAdded = ids; oneAdded.insert(URL(fileURLWithPath: "/kr/new-file"), at: 7)
        T.expect(ListDiff.strategy(old: ids, new: oneAdded) == .incremental,
                 "single insert keeps the animated diff")
        var oneGone = ids; oneGone.remove(at: 19_000)
        T.expect(ListDiff.strategy(old: ids, new: oneGone) == .incremental,
                 "single removal keeps the animated diff")
    }

    T.group("ListDiff: worst case stays fast") {
        let clock = ContinuousClock()
        let t0 = clock.now
        _ = ListDiff.strategy(old: ids, new: ids.reversed())
        let elapsed = Double((clock.now - t0).components.attoseconds) / 1e15
        T.expect(elapsed < 100,
                 "26k reorder decision takes \(String(format: "%.1f", elapsed))ms (must be <100ms)")
    }
}
