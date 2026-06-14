import Foundation

/// The model⇄AppKit-view reconciliation dance, in one place.
///
/// The list and icon-grid coordinators wrap native NSTableView/NSCollectionView
/// but their data lives in an `@Observable` model, so each `updateNSView` tick
/// must push model→view WITHOUT the view's resulting selection callback pushing
/// view→model again (an infinite loop). Three pieces of bookkeeping prevent it,
/// and they used to be hand-copied — and hand-mis-copied — into every
/// coordinator. Centralising them means a selection-sync bug is fixed once.
///
/// - `itemsChanged(version:)`  — gate a full reload on the model's `itemsVersion`
///    so the table reloads only when the listing actually changed.
/// - `selectionChanged(_:force:)` — skip re-applying a selection identical to the
///    one already on screen (the loop's outer guard).
/// - `applying { … }` — raise a re-entrancy flag while pushing the selection into
///    the view, so the view's didSelect/didDeselect callback is ignored.
@MainActor
final class ListSyncState {
    private var lastVersion = -1
    private var lastAppliedSelection: Set<FileItem.ID>?
    private var lastModelID: AnyHashable?
    private(set) var isSyncing = false

    /// True (and records the version) when the listing changed since last call.
    func itemsChanged(version: Int) -> Bool {
        guard lastVersion != version else { return false }
        lastVersion = version
        return true
    }

    /// True when the bound model changed identity since the last call — and
    /// resets the reload/selection gates so the caller does a clean reload.
    ///
    /// A tab switch reuses the SAME coordinator (the content view has no per-tab
    /// id), so `updateNSView` just points `coordinator.model` at the next tab's
    /// model. But `itemsVersion` is per-model — each tab counts from 0 — so the
    /// new tab's version can equal the value last applied from the previous tab,
    /// `itemsChanged` then returns false, the reload is skipped, and the old
    /// tab's listing stays on screen (the "wrong folder shown under the selected
    /// tab" bug). Calling this first makes the next `itemsChanged` report a
    /// change and forces the selection to be re-applied onto the new listing.
    @discardableResult
    func modelChanged(_ id: some Hashable) -> Bool {
        let boxed = AnyHashable(id)
        guard lastModelID != boxed else { return false }
        lastModelID = boxed
        lastVersion = -1            // next itemsChanged(version:) → true
        lastAppliedSelection = nil  // re-apply selection onto the new listing
        return true
    }

    /// Force the next `itemsChanged` to report a change (e.g. after a font/size
    /// change that requires re-making cells even with the same listing).
    func invalidateItems() { lastVersion = -1 }

    /// True (and records it) when the model selection differs from the one last
    /// applied to the view. `force` always reports changed (post-reload remap).
    func selectionChanged(_ selection: Set<FileItem.ID>, force: Bool = false) -> Bool {
        if !force, lastAppliedSelection == selection { return false }
        lastAppliedSelection = selection
        return true
    }

    /// Record a selection the VIEW just reported, so the next model→view pass
    /// doesn't redundantly re-apply it.
    func recordApplied(_ selection: Set<FileItem.ID>) {
        lastAppliedSelection = selection
    }

    /// Run `body` with the re-entrancy guard up; view callbacks fired during it
    /// see `isSyncing == true` and bail.
    func applying(_ body: () -> Void) {
        isSyncing = true
        body()
        isSyncing = false
    }
}
