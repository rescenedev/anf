import Foundation
@testable import anf

/// The action↔key IDENTITY map and the command-palette search-intent statics.
/// KeymapTests proves every action has *a* binding and that defaults parse, but
/// never that a given chord maps to the RIGHT action — a swapped mapping (the
/// #40 bug class: Return must mean rename, not go-up) would slip through.
func runKeybindingMapTests() {
    func chord(_ s: String) -> Keymap.Chord { Keymap.parseChord(s)! }

    T.group("default chords map to the expected actions (identity, not just presence)") {
        // A path with no keybindings file → pure defaults, no user overrides.
        let none = FileManager.default.temporaryDirectory.appendingPathComponent("anfkb-\(UUID().uuidString).json")
        let m = Keymap.effectiveBindings(fileAt: none)
        let expect: [(String, KeyAction)] = [
            ("return", .rename), ("enter", .rename), ("shift+return", .rename),
            ("delete", .trash), ("cmd+delete", .trash),
            ("space", .quickLook),
            ("cmd+,", .openSettings),
            ("cmd+left", .goBack), ("cmd+right", .goForward),
            ("cmd+up", .goUp), ("cmd+down", .openSelected),
            ("cmd+t", .newTab), ("cmd+w", .closeTab),
            ("cmd+d", .duplicate), ("cmd+shift+n", .newFolder),
            ("cmd+shift+d", .toggleFavorite),
            ("cmd+1", .layoutSingle), ("cmd+4", .layoutQuad),
            // Selection movement (issue #52): arrows plus Emacs/Vim aliases.
            ("up", .moveUp), ("ctrl+p", .moveUp), ("ctrl+k", .moveUp),
            ("down", .moveDown), ("ctrl+n", .moveDown), ("ctrl+j", .moveDown),
            ("left", .moveLeft), ("ctrl+h", .moveLeft),
            ("right", .moveRight), ("ctrl+l", .moveRight),
        ]
        for (spec, action) in expect {
            T.equal(m[chord(spec)], action, "'\(spec)' → \(action)")
        }
        // The move chords must not collide with the ⌘-modified history/open
        // navigation that shares the arrow keys.
        T.equal(m[chord("cmd+up")], .goUp, "⌘↑ stays goUp, not moveUp")
        T.equal(m[chord("cmd+down")], .openSelected, "⌘↓ stays openSelected")
        // isMove flags exactly the four movement actions.
        for a in KeyAction.allCases {
            let shouldMove = [.moveUp, .moveDown, .moveLeft, .moveRight].contains(a)
            T.equal(a.isMove, shouldMove, "\(a).isMove == \(shouldMove)")
        }
    }

    MainActor.assumeIsolated {
        T.group("CommandPalette search-intent detection") {
            T.expect(CommandPaletteController.isSearchIntent("강아지 사진 찾아줘"), "Korean 'find' verb is a search")
            T.expect(CommandPaletteController.isSearchIntent("find report"), "English 'find' is a search")
            T.expect(CommandPaletteController.isSearchIntent("where is my invoice"), "'where' is a search")
            T.expect(!CommandPaletteController.isSearchIntent("what is this folder"), "a question is NOT a search")
            T.expect(!CommandPaletteController.isSearchIntent("summarize the docs"), "no search verb → not a search")
        }

        T.group("CommandPalette search needle drops the verbs") {
            let needle = CommandPaletteController.searchNeedle("강아지 사진 찾아줘")
            T.expect(needle.contains("강아지"), "subject kept")
            T.expect(!needle.contains("찾아줘"), "search verb dropped")
            T.equal(CommandPaletteController.searchNeedle("hello"), "hello", "no verb → original query")
        }
    }
}
