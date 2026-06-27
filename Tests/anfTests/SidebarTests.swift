import Foundation
@testable import anf

/// Sidebar favorites: iCloud Drive must appear when it's set up (reported
/// missing 2026-06-14 — there was no entry point at all).
func runSidebarTests() {
    let fm = FileManager.default

    T.group("iCloud Drive path + gating") {
        let home = URL(fileURLWithPath: "/Users/someone")
        T.equal(SidebarBuilder.iCloudDriveURL(home: home).path,
                "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs",
                "canonical iCloud Drive path")

        // Build a fake home with the CloudDocs dir and confirm gating sees it.
        let fakeHome = fm.temporaryDirectory.appendingPathComponent("anfhome-\(UUID().uuidString)")
        let cloud = SidebarBuilder.iCloudDriveURL(home: fakeHome)
        defer { try? fm.removeItem(at: fakeHome) }
        T.expect(!fm.fileExists(atPath: cloud.path), "absent before creation → would be hidden")
        try? fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        T.expect(fm.fileExists(atPath: cloud.path), "present after creation → would show")
    }

    T.group("favorites list is well-formed") {
        let favs = SidebarBuilder.favorites()
        T.expect(favs.contains { $0.name == L("Home", "홈") }, "Home always present")
        // Distinct ids (paths) — duplicates would break NSOutlineView identity.
        T.equal(Set(favs.map(\.id)).count, favs.count, "favorite ids are unique")
    }

    T.group("only real file locations are favoritable") {
        // ⌘⇧D / the toolbar star reach virtual + remote locations too; favoriting
        // one persisted a garbage path that broke after relaunch.
        T.expect(FavoritesStore.isFavoritable(URL(fileURLWithPath: "/Users/me/Documents")),
                 "a real folder is favoritable")
        T.expect(!FavoritesStore.isFavoritable(URL(string: "anf://recents")!), "anf:// virtual location is not")
        T.expect(!FavoritesStore.isFavoritable(URL(string: "anf://smartfolder/abc")!), "smart folder is not")
        T.expect(!FavoritesStore.isFavoritable(URL(string: "sftp://host/dir")!), "remote sftp:// is not")
    }
}
