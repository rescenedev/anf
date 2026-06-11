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
        if let inverse = perform(inverseOf: op) { redoStack.append(inverse) }
        return true
    }

    /// Returns true if anything was redone.
    @discardableResult
    func redo() -> Bool {
        guard let op = redoStack.popLast() else { return false }
        if let inverse = perform(inverseOf: op) { undoStack.append(inverse) }
        return true
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
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            FileOperations.presentFailures(L("Couldn’t undo", "되돌리지 못했습니다"), failures)
            return trashedPairs.isEmpty ? nil : .trash(trashedPairs)

        case .trash(let pairs):
            // Inverse of "these were trashed" = restore from the Trash.
            var restored: [URL] = []
            var stillTrashed: [(original: URL, trashed: URL)] = []
            for (original, trashed) in pairs {
                do {
                    try fm.moveItem(at: trashed, to: original)
                    restored.append(original)
                    stillTrashed.append((original, trashed))
                } catch { failures.append("\(original.lastPathComponent): \(error.localizedDescription)") }
            }
            FileOperations.presentFailures(L("Couldn’t restore from Trash", "휴지통에서 복원하지 못했습니다"), failures)
            // Redo = trash them again; recording as .created(restored) trashes on next inverse.
            return restored.isEmpty ? nil : .created(restored)
        }
    }
}
