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

    T.group("ListSyncState: tab switch forces a reload despite itemsVersion collision") {
        MainActor.assumeIsolated {
            let s = ListSyncState()
            let tabA = UUID(); let tabB = UUID()

            // Tab A: version 0 applied, then stable.
            T.expect(s.modelChanged(tabA), "first bound model counts as a change")
            T.expect(s.itemsChanged(version: 0), "tab A v0 → reload")
            T.expect(!s.itemsChanged(version: 0), "tab A v0 again → no reload")

            // Switch to tab B whose per-model itemsVersion ALSO starts at 0.
            // Without modelChanged, itemsChanged(version: 0) would return false
            // and the old tab's listing would stay on screen (the reported bug).
            T.expect(s.modelChanged(tabB), "switching tabs is a change")
            T.expect(s.itemsChanged(version: 0),
                     "tab B v0 → reload even though the version collides with tab A")

            // Re-applying the same model is not a change.
            T.expect(!s.modelChanged(tabB), "same model id → no forced reload")
        }
    }

    T.group("ListDiff: worst case stays fast") {
        // Best-of-N, not a single cold timing: this also runs inside the nightly
        // release (mid build + notarize), where one cold run jittered to ~108ms
        // and failed a 100ms bar that the algorithm clears with ease. The fastest
        // of several runs reflects the algorithm, not scheduler noise — and an
        // accidental O(n²) regression would be hundreds of ms even at best.
        let clock = ContinuousClock()
        func runMS() -> Double {
            let t0 = clock.now
            _ = ListDiff.strategy(old: ids, new: ids.reversed())
            let d = clock.now - t0
            return Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
        }
        let best = (0..<5).map { _ in runMS() }.min() ?? .greatestFiniteMagnitude
        T.expect(best < 100,
                 "26k reorder decision (best of 5) takes \(String(format: "%.1f", best))ms (must be <100ms)")
    }
}
