import AppKit
@testable import anf

/// Custom keybindings (issue #8): chord parsing, the pre-filled template, and
/// the override semantics (rebinding frees old keys; bindings steal chords).
func runKeymapTests() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("anfkeys-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    func write(_ json: String) -> URL {
        let url = dir.appendingPathComponent("kb-\(UUID().uuidString).json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    func chord(_ spec: String) -> Keymap.Chord? { Keymap.parseChord(spec) }

    T.group("Keymap.parseChord") {
        T.expect(chord("cmd+shift+t") != nil, "modifier chain parses")
        T.equal(chord("cmd+shift+t")?.key, "t", "key token extracted")
        T.equal(chord("CMD+T")?.key, "t", "case-insensitive")
        T.equal(chord("ctrl+`")?.key, "`", "backtick token")
        T.equal(chord("f5")?.key, "f5", "bare function key")
        T.equal(chord("cmd+up")?.key, "up", "arrow token")
        T.expect(chord("cmd+질") == nil, "unknown key rejected")
        T.expect(chord("cmd+t+x") == nil, "two keys rejected")
        T.expect(chord("cmd") == nil, "modifier-only rejected")
        T.expect(chord("cmd+t") != chord("cmd+shift+t"), "flags participate in identity")
    }

    T.group("defaults cover every action; template is valid pre-filled JSON") {
        let mapped = Set(Keymap.defaults.map(\.0))
        for action in KeyAction.allCases {
            T.expect(mapped.contains(action), "default chord exists for \(action.rawValue)")
        }
        for (_, specs) in Keymap.defaults {
            for spec in specs {
                T.expect(Keymap.parseChord(spec) != nil, "default '\(spec)' parses")
            }
        }
        let data = Data(Keymap.template.utf8)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        T.expect(obj != nil, "template parses as JSON")
        for action in KeyAction.allCases {
            T.expect(obj?[action.rawValue] != nil, "template pre-fills \(action.rawValue)")
        }
    }

    T.group("override semantics") {
        // No file → pure defaults.
        let base = Keymap.effectiveBindings(fileAt: dir.appendingPathComponent("nope.json"))
        T.equal(base[chord("cmd+t")!], .newTab, "default cmd+t → newTab")
        T.equal(base[chord("cmd+p")!], .commandPalette, "secondary default kept")

        // Rebinding an action frees its old chords.
        let moved = Keymap.effectiveBindings(fileAt: write(#"{"newTab": "cmd+shift+t"}"#))
        T.equal(moved[chord("cmd+shift+t")!], .newTab, "new chord works")
        T.expect(moved[chord("cmd+t")!] == nil, "old default chord freed")

        // Binding a chord another action used by default steals it.
        let stolen = Keymap.effectiveBindings(fileAt: write(#"{"layoutQuad": "cmd+t"}"#))
        T.equal(stolen[chord("cmd+t")!], .layoutQuad, "cmd+t stolen by layoutQuad")
        T.expect(!stolen.values.contains(.newTab) || stolen[chord("cmd+t")!] != .newTab,
                 "newTab no longer on cmd+t")

        // Arrays bind several chords to one action.
        let multi = Keymap.effectiveBindings(fileAt: write(#"{"reload": ["cmd+r", "f5"]}"#))
        T.equal(multi[chord("cmd+r")!], .reload, "array chord 1")
        T.equal(multi[chord("f5")!], .reload, "array chord 2 steals f5 from transferCopy")

        // Junk never breaks anything.
        let junk = Keymap.effectiveBindings(fileAt: write(#"{"_readme": ["x"], "nope": "cmd+t", "newTab": 3, "reload": "cmd+무"}"#))
        T.equal(junk[chord("cmd+t")!], .newTab, "junk entries ignored, defaults intact")
    }

    T.group("hidden event flags don't break matching (1.1.0 regression)") {
        // Arrow keys carry .numericPad|.function on the real NSEvent; F-keys
        // carry .function; Caps Lock adds .capsLock. v1.1.0 compared the full
        // mask, which killed ⌘↑/⌘↓/⌘←/⌘→ and F5/F6 — folder navigation died.
        let map = Keymap.effectiveBindings(fileAt: dir.appendingPathComponent("none.json"))
        func match(_ flags: NSEvent.ModifierFlags, _ key: String) -> KeyAction? {
            map[Keymap.Chord(flags: flags.intersection(Keymap.relevantFlags).rawValue, key: key)]
        }
        T.equal(match([.command, .numericPad, .function], "down"), .openSelected,
                "⌘↓ with the arrow-key extra flags → openSelected")
        T.equal(match([.command, .numericPad, .function], "up"), .goUp,
                "⌘↑ → goUp")
        T.equal(match([.command, .numericPad, .function], "left"), .goBack,
                "⌘← → goBack")
        T.equal(match([.function], "f5"), .transferCopy,
                "F5 with .function → transferCopy")
        T.equal(match([.command, .capsLock], "t"), .newTab,
                "Caps Lock doesn't break ⌘T")
        T.expect(Keymap.relevantFlags == [.command, .shift, .option, .control],
                 "matching considers exactly cmd/shift/opt/ctrl")
    }

    T.group("event token normalization") {
        T.equal(Keymap.token(keyCode: 40, fallback: "ㅏ"), "k", "Korean IME: physical K wins")
        T.equal(Keymap.token(keyCode: 49, fallback: " "), "space", "space by keyCode")
        T.equal(Keymap.token(keyCode: 96, fallback: nil), "f5", "f5 by keyCode")
        T.equal(Keymap.token(keyCode: 43, fallback: ","), ",", "comma (⌘, settings)")
        T.equal(Keymap.token(keyCode: 999, fallback: "Q"), "q", "fallback lowercases")
        // Both delete keys normalize to "delete" so either trashes the selection:
        // 51 = ⌫ (Backspace), 117 = ⌦ (forward delete). 117 was unmapped, so the
        // "delete" key on full-size keyboards did nothing.
        T.equal(Keymap.token(keyCode: 51, fallback: nil), "delete", "backspace ⌫ → delete")
        T.equal(Keymap.token(keyCode: 117, fallback: nil), "delete", "forward delete ⌦ → delete")
    }

    T.group("both delete keys are bound to trash") {
        let map = Keymap.effectiveBindings(fileAt: URL(fileURLWithPath: "/nonexistent-keymap-file"))
        let noMods = Keymap.relevantFlags.subtracting(Keymap.relevantFlags).rawValue   // 0
        let backspace = Keymap.Chord(flags: noMods, key: Keymap.token(keyCode: 51, fallback: nil))
        let forward = Keymap.Chord(flags: noMods, key: Keymap.token(keyCode: 117, fallback: nil))
        T.equal(map[backspace], .trash, "⌫ (51) is bound to trash")
        T.equal(map[forward], .trash, "⌦ (117) is bound to trash")
    }
}
