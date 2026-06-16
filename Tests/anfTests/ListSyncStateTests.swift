import Foundation
@testable import anf

/// The selection/items/model reconciliation gates that prevent the view⇄model
/// infinite loop and the "wrong folder under the selected tab" bug. ListDiffTests
/// exercises modelChanged/itemsChanged; these cover the untested selectionChanged
/// outer guard, the force path, and invalidateItems (font/size repaint).
func runListSyncStateTests() {
    MainActor.assumeIsolated {
        let u1 = URL(fileURLWithPath: "/x/one")
        let u2 = URL(fileURLWithPath: "/x/two")

        T.group("selectionChanged skips identical selections, force always reports a change") {
            let s = ListSyncState()
            let sel: Set<FileItem.ID> = [u1, u2]
            T.expect(s.selectionChanged(sel), "first apply → changed")
            T.expect(!s.selectionChanged(sel), "identical selection → skipped (breaks the loop)")
            T.expect(s.selectionChanged(sel, force: true), "force → changed even when identical (post-reload remap)")
            T.expect(s.selectionChanged([u1]), "a different selection → changed")
        }

        T.group("invalidateItems forces the next itemsChanged even for the same version") {
            let s = ListSyncState()
            T.expect(s.itemsChanged(version: 7), "first version → changed")
            T.expect(!s.itemsChanged(version: 7), "same version → skipped")
            s.invalidateItems()
            T.expect(s.itemsChanged(version: 7), "after invalidate, the same version repaints (font/size change)")
        }

        T.group("modelChanged resets both gates (tab switch reuses the coordinator)") {
            let s = ListSyncState()
            _ = s.itemsChanged(version: 9)
            _ = s.selectionChanged([u1])
            T.expect(s.modelChanged("tabB"), "new model identity → changed")
            T.expect(s.itemsChanged(version: 9), "version gate reset → same per-tab version still reloads")
            T.expect(s.selectionChanged([u1]), "selection gate reset → re-applies onto the new listing")
            T.expect(!s.modelChanged("tabB"), "same model identity → no change")
        }
    }
}
