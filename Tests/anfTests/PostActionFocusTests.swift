import Foundation
@testable import anf

/// Issue #31: keep focus on the result of an action so the keyboard flow keeps
/// going — a new folder lands selected + renaming, a duplicate lands selected —
/// plus the favorites-JSON path cleaning (#31 item 3).
func runPostActionFocusTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        func pump(_ m: BrowserModel, until: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !until() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        T.group("favorites JSON path cleaning (#31)") {
            T.equal(FavoritesStore.cleanFavoritePath("/Users/x/projects"), "/Users/x/projects",
                    "plain path unchanged")
            T.equal(FavoritesStore.cleanFavoritePath("  /Users/x/p  "), "/Users/x/p",
                    "surrounding whitespace trimmed")
            // The reported bug: a space-containing path shell-quoted inside JSON.
            T.equal(FavoritesStore.cleanFavoritePath("'/Users/x/Camera Uploads'"), "/Users/x/Camera Uploads",
                    "single-quoted path with spaces is unquoted")
            T.equal(FavoritesStore.cleanFavoritePath("\"/Users/x/p\""), "/Users/x/p",
                    "double-quoted path unquoted")
            T.equal(FavoritesStore.cleanFavoritePath("~"), NSHomeDirectory(), "leading tilde expanded")
            T.equal(FavoritesStore.cleanFavoritePath("   "), "", "blank → empty (skipped on import)")
        }

        T.group("new folder lands selected and renaming (#31)") {
            let dir = fm.temporaryDirectory.appendingPathComponent("anfnew-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            let m = BrowserModel(start: dir)
            m.viewMode = .list
            pump(m) { !m.isLoading }
            m.makeNewFolder()
            pump(m) { m.editingItemID != nil }
            T.expect(m.editingItemID != nil, "the new folder enters inline rename")
            T.equal(m.selectedItems.count, 1, "exactly the new folder is selected")
            T.expect(m.selectedItems.first?.isDirectory == true, "selection is the new folder")
        }

        T.group("duplicate lands on the copy (#31)") {
            let dir = fm.temporaryDirectory.appendingPathComponent("anfdup-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let src = dir.appendingPathComponent("a.txt")
            try? "x".write(to: src, atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(at: dir) }
            let m = BrowserModel(start: dir)
            m.viewMode = .list
            pump(m) { m.items.contains { $0.name == "a.txt" } }
            m.selection = [src.standardizedFileURL]
            m.duplicateSelection()
            pump(m) { m.selectedItems.first?.name.contains("copy") == true }
            T.equal(m.selectedItems.count, 1, "the duplicate is selected")
            T.expect(m.selectedItems.first?.name.contains("copy") == true,
                     "selection is the 'a copy.txt' duplicate, not the source")
        }
    }
}
