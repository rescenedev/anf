import Foundation

/// Shared inline-rename selection logic for the list and icon-grid views: when a
/// rename begins, highlight the basename WITHOUT its trailing extension (Finder
/// behavior) so the first keystroke doesn't replace ".pdf". Names with no
/// extension (Makefile, a dotfile, a plain folder) keep the whole name selected.
enum RenameSelection {
    static func basenameLength(_ name: String) -> Int {
        let ns = name as NSString
        let extLen = (ns.pathExtension as NSString).length
        return extLen > 0 ? max(0, ns.length - extLen - 1) : ns.length
    }
}
