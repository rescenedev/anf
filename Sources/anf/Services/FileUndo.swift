import Foundation

/// Undo/redo for file operations (⌘Z / ⌘⇧Z). Each mutating operation records an
/// `Op`; undoing performs its inverse and pushes that onto the redo stack.
/// Deliberately file-system-truth based: if the user (or another app) moved
/// things since, the inverse just fails item-by-item and reports.
@MainActor
final class FileUndo {
    static let shared = FileUndo()

    enum Op {
        /// Items moved/renamed: each (from → to). Inverse moves them back.
        case move([(from: URL, to: URL)])
        /// Items newly created (copy results, duplicates, new folders).
        /// Inverse trashes them.
        case created([URL])
        /// Items trashed: (original location, location inside the Trash).
        /// Inverse moves them back out of the Trash.
        case trash([(original: URL, trashed: URL)])
    }

    private(set) var undoStack: [Op] = []
    private(set) var redoStack: [Op] = []
    private let maxDepth = 50

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func record(_ op: Op) {
        undoStack.append(op)
        if undoStack.count > maxDepth { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Returns true if anything was undone (callers reload their listings).
    @discardableResult
    func undo() -> Bool {
        guard let op = undoStack.popLast() else { return false }
        var dirs = affectedDirs(op)
        if let inverse = perform(inverseOf: op) { redoStack.append(inverse); dirs.formUnion(affectedDirs(inverse)) }
        // Refresh EVERY tab/pane showing a touched folder, not just the visible
        // active one (N-010 — same staleness N-002 fixed for forward ops).
        BrowserModel.broadcastDirsChanged(dirs)
        return true
    }

    /// Returns true if anything was redone.
    @discardableResult
    func redo() -> Bool {
        guard let op = redoStack.popLast() else { return false }
        var dirs = affectedDirs(op)
        if let inverse = perform(inverseOf: op) { undoStack.append(inverse); dirs.formUnion(affectedDirs(inverse)) }
        BrowserModel.broadcastDirsChanged(dirs)
        return true
    }

    /// Parent directories touched by an op — the folders whose listings change.
    private func affectedDirs(_ op: Op) -> Set<String> {
        func parent(_ u: URL) -> String { u.deletingLastPathComponent().standardizedFileURL.path }
        switch op {
        case .move(let pairs):    return Set(pairs.flatMap { [parent($0.from), parent($0.to)] })
        case .created(let urls):  return Set(urls.map(parent))
        case .trash(let pairs):   return Set(pairs.flatMap { [parent($0.original), parent($0.trashed)] })
        }
    }

    /// Execute the inverse of `op`; returns the op that would revert *that*
    /// (i.e. what redo should perform), or nil if nothing succeeded.
    private func perform(inverseOf op: Op) -> Op? {
        let fm = FileManager.default
        var failures: [String] = []

        switch op {
        case .move(let pairs):
            var done: [(from: URL, to: URL)] = []
            for (from, to) in pairs.reversed() {
                do {
                    try fm.moveItem(at: to, to: from)
                    done.append((from: to, to: from))
                } catch { failures.append("\(to.lastPathComponent): \(error.localizedDescription)") }
            }
            FileOperations.presentFailures(L("Couldn’t undo", "되돌리지 못했습니다"), failures)
            // `done` records the movements just performed; the op whose inverse
            // re-applies the original action is exactly that record. (Flipping it
            // here would make redo repeat the *undo* — and fail.)
            return done.isEmpty ? nil : .move(done)

        case .created(let urls):
            // Inverse of "these were created" = trash them again.
            var trashedPairs: [(original: URL, trashed: URL)] = []
            for url in urls {
                do {
                    var t: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &t)
                    if let t = t as URL? { trashedPairs.append((url, t)) }
                } catch let e as NSError
                            where e.domain == NSCocoaErrorDomain && e.code == NSFeatureUnsupportedError {
                    // Volume has no Trash (network share). Do NOT permanently delete on
                    // an undo without consent — the copy may have been edited since, and
                    // undo must never silently destroy data (N-011 허점). Refuse and
                    // report; the user can remove it manually.
                    failures.append(L("\(url.lastPathComponent): can’t undo on a volume without a Trash — delete it manually",
                                      "\(url.lastPathComponent): 휴지통이 없는 볼륨이라 되돌릴 수 없어요 — 직접 삭제하세요"))
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            FileOperations.presentFailures(L("Couldn’t undo", "되돌리지 못했습니다"), failures)
            return trashedPairs.isEmpty ? nil : .trash(trashedPairs)

        case .trash(let pairs):
            // Inverse of "these were trashed" = restore from the Trash.
            var restoredPairs: [(original: URL, trashed: URL)] = []
            for (original, trashed) in pairs {
                do {
                    try fm.moveItem(at: trashed, to: original)
                    restoredPairs.append((original, trashed))
                } catch { failures.append("\(original.lastPathComponent): \(error.localizedDescription)") }
            }
            FileOperations.presentFailures(L("Couldn’t restore from Trash", "휴지통에서 복원하지 못했습니다"), failures)
            // Redo = trash the restored items again. Return .created(restored originals)
            // so redo’s inverse calls trashItem and records the NEW trash location.
            // (We cannot reuse the old `trashed` URLs because moveItem already moved
            // those files out — FU-001: dead `stillTrashed` removed, behaviour unchanged.)
            let restored = restoredPairs.map(\.original)
            return restored.isEmpty ? nil : .created(restored)
        }
    }
}
