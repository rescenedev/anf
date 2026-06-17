import Foundation

/// Windows leaves bookkeeping files on any volume it touches — NTFS/exFAT
/// recycle bins, Windows-upgrade staging, restore-point metadata. macOS only
/// treats dot-prefixed names as hidden, so on external drives and VM shared
/// folders (Parallels, etc.) these `$RECYCLE.BIN`-style entries show up as
/// clutter regardless of the hidden-files setting (issue #53).
///
/// We hide the well-known ones whenever "show hidden files" is OFF; toggling
/// hidden files on (⌘⇧.) still reveals them, exactly like dot-files.
///
/// Deliberately a curated allowlist rather than "anything starting with `$`",
/// so a user's own file named `$draft.txt` is never hidden out from under them.
enum WindowsSystemFiles {
    /// Exact names (matched case-insensitively).
    private static let exactNames: Set<String> = [
        "system volume information",   // restore points / indexing metadata
        "recycler",                    // Windows XP recycle bin
        "recycled",                    // FAT32 recycle bin
        "msocache",                    // Office local install source
        "found.000",                   // chkdsk recovered fragments
    ]

    /// Name prefixes (matched case-insensitively) for families whose suffix
    /// varies between machines/Windows versions.
    private static let prefixes: [String] = [
        "$recycle.bin",   // NTFS/exFAT recycle bin (per-SID subfolders inside)
        "$windows.~",     // $WINDOWS.~BT / $WINDOWS.~WS — in-place upgrade staging
        "$winreagent",    // Windows Recovery Environment agent
        "$getcurrent",    // update download cache
        "$sysreset",      // "Reset this PC" logs
        "$av_asw",        // Avast self-defense folder
    ]

    /// True when `name` is a recognized Windows system file/folder that should
    /// be hidden alongside dot-files.
    static func isHidden(_ name: String) -> Bool {
        let lower = name.lowercased()
        if exactNames.contains(lower) { return true }
        return prefixes.contains { lower.hasPrefix($0) }
    }
}
