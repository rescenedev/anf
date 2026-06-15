import Foundation
@testable import anf

/// Tab chip label, especially for locked tabs (issue #12): a locked tab keeps
/// its locked-folder name as its identity; when browsed elsewhere it shows
/// "!workingdir".
func runTabTitleTests() {
    MainActor.assumeIsolated {
        let comic = URL(fileURLWithPath: "/Volumes/NAS/코믹")
        let morning = URL(fileURLWithPath: "/Volumes/NAS/모닝스페셜")
        let root = URL(fileURLWithPath: "/")

        T.group("unlocked tab shows its current folder") {
            T.equal(BrowserModel.tabTitle(current: comic, locked: nil), "코믹",
                    "unlocked → current folder name")
            T.equal(BrowserModel.tabTitle(current: root, locked: nil), "Macintosh HD",
                    "root shows the volume name")
        }

        T.group("locked tab keeps the locked folder's name") {
            // Locked at 코믹, currently sitting in 코믹 → just "코믹".
            T.equal(BrowserModel.tabTitle(current: comic, locked: comic), "코믹",
                    "locked & at the locked dir → locked name, no marker")
            // Locked at 코믹 but browsed to 모닝스페셜 → "!모닝스페셜" (the reported bug:
            // it used to show "모닝스페셜" with no indication it was a locked tab).
            T.equal(BrowserModel.tabTitle(current: morning, locked: comic), "!모닝스페셜",
                    "locked but browsed away → '!' + working dir")
        }

        T.group("locked-tab path comparison is normalized") {
            // Trailing slash / non-standard form must still count as "at locked dir".
            let comicSlash = URL(fileURLWithPath: "/Volumes/NAS/코믹/")
            T.equal(BrowserModel.tabTitle(current: comicSlash, locked: comic), "코믹",
                    "trailing-slash variant is treated as the locked dir, not '!'")
        }
    }
}
