import Foundation
@testable import anf

/// Windows system-file hiding (issue #53): the curated allowlist must catch the
/// real clutter ($RECYCLE.BIN family, upgrade staging, restore-point metadata)
/// while never hiding a user's own file that merely starts with `$`.
func runWindowsSystemFilesTests() {
    T.group("WindowsSystemFiles.isHidden recognizes Windows clutter") {
        let hidden = [
            "$RECYCLE.BIN", "$Recycle.Bin", "$recycle.bin",
            "System Volume Information", "system volume information",
            "$WINDOWS.~BT", "$Windows.~WS", "$windows.~ws",
            "$WinREAgent", "$GetCurrent", "$SysReset", "$AV_ASW",
            "RECYCLER", "Recycled", "MSOCache", "FOUND.000",
        ]
        for name in hidden {
            T.expect(WindowsSystemFiles.isHidden(name), "'\(name)' is hidden")
        }
    }

    T.group("WindowsSystemFiles.isHidden leaves user files alone") {
        let visible = [
            "$draft.txt",          // a user's own $-prefixed file
            "$money.xlsx",
            "$",                    // bare dollar sign
            "report.pdf", "Documents", "Photos",
            ".hidden",              // dot-files are handled elsewhere, not here
            "recycle.bin",          // no $ prefix → not the NTFS bin
            "system volume",        // partial name, not the exact entry
            "$Windows",             // bare, without the ".~" upgrade-staging suffix
        ]
        for name in visible {
            T.expect(!WindowsSystemFiles.isHidden(name), "'\(name)' stays visible")
        }
    }
}
