import Foundation
@testable import anf

/// TC-2 (RN-001): rename's recordUndo flag — the primitive batch rename relies on
/// to coalesce N renames into ONE undo instead of flooding the stack.
/// TC-3 (AI-001): organizers report the (from,to) pairs of files they actually
/// moved, so the bulk move is undoable.
@MainActor
func runUndoCoalesceTests() {
    let fm = FileManager.default

    T.group("RN-001: rename(recordUndo:) controls undo recording") {
        let dir = fm.temporaryDirectory.appendingPathComponent("anfrn-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt")
        try? "x".write(to: a, atomically: true, encoding: .utf8)

        guard let item = FileItem(url: a) else { T.expect(false, "fixture FileItem"); return }
        let before = FileUndo.shared.undoStack.count
        let dest = FileOperations.rename(item, to: "b.txt", recordUndo: false)
        T.expect(dest != nil, "rename succeeded")
        T.equal(FileUndo.shared.undoStack.count, before, "recordUndo:false pushes NO undo (batch coalesces itself)")

        if let dest, let moved = FileItem(url: dest) {
            _ = FileOperations.rename(moved, to: "c.txt", recordUndo: true)
            T.equal(FileUndo.shared.undoStack.count, before + 1, "recordUndo:true pushes exactly one undo")
        }
    }

    T.group("AI-001: organizer reports only the files it actually moved") {
        let dir = fm.temporaryDirectory.appendingPathComponent("anforg-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for n in ["doc.txt", "report.pdf", "pic.jpg"] {
            try? "x".write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8)
        }
        let plan = FolderOrganizer.plan(in: dir, korean: false)
        guard plan.total > 0 else { T.expect(false, "plan found files to organize"); return }
        let result = FolderOrganizer.move(plan, into: dir)
        T.equal(result.pairs.count, result.moved, "pairs count == moved count (every recorded pair was a real move)")
        T.expect(result.moved > 0, "moved at least one file")
        for p in result.pairs {
            T.expect(fm.fileExists(atPath: p.to.path), "destination exists: \(p.to.lastPathComponent)")
            T.expect(!fm.fileExists(atPath: p.from.path), "source gone: \(p.from.lastPathComponent)")
        }
    }
}
