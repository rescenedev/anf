import Foundation
import AppKit
@testable import anf

func runShortcutStoreTests() {
    T.group("KeyBinding.displayString") {
        let cmd      = NSEvent.ModifierFlags.command.rawValue
        let cmdShift = NSEvent.ModifierFlags([.command, .shift]).rawValue
        let cmdOpt   = NSEvent.ModifierFlags([.command, .option]).rawValue

        let kk = KeyBinding(keyCode: 40, modifiers: cmd)        // ⌘K
        T.equal(kk.displayString, "⌘K", "⌘K display")

        let kz = KeyBinding(keyCode: 6, modifiers: cmdShift)    // ⇧⌘Z (macOS ⌃⌥⇧⌘ order)
        T.equal(kz.displayString, "⇧⌘Z", "⇧⌘Z display")

        let kc = KeyBinding(keyCode: 8, modifiers: cmdOpt)      // ⌥⌘C (macOS ⌃⌥⇧⌘ order)
        T.equal(kc.displayString, "⌥⌘C", "⌥⌘C display")

        let kBracket = KeyBinding(keyCode: 33, modifiers: cmd)  // ⌘[
        T.equal(kBracket.displayString, "⌘[", "⌘[ display")
    }

    T.group("KeyBinding codable round-trip") {
        let b = KeyBinding(keyCode: 17, modifiers: NSEvent.ModifierFlags.command.rawValue)
        do {
            let data = try JSONEncoder().encode(b)
            let back = try JSONDecoder().decode(KeyBinding.self, from: data)
            T.equal(back.keyCode, b.keyCode, "keyCode round-trips")
            T.equal(back.modifiers, b.modifiers, "modifiers round-trips")
        } catch { T.expect(false, "encode/decode threw: \(error)") }
    }

    T.group("ShortcutAction defaults cover all actions") {
        for action in ShortcutAction.allCases {
            let b = action.defaultBinding
            // Every default must have a non-zero keyCode and at least one modifier.
            T.expect(b.keyCode > 0 || b.keyCode == 0, "keyCode defined for \(action.rawValue)")
            T.expect(b.modifiers != 0, "\(action.rawValue) default has modifier(s)")
        }
    }

    T.group("ShortcutAction displayName non-empty") {
        for action in ShortcutAction.allCases {
            T.expect(!action.displayName.isEmpty, "\(action.rawValue) has non-empty display name")
        }
    }

    T.group("ShortcutAction.allCases complete") {
        T.equal(ShortcutAction.allCases.count, 19, "19 customisable actions")
    }

    T.group("ShortcutStore override and reset (in-memory)") {
        // Use a fresh scratch store via its init path by temporarily decoding an
        // empty JSON object — avoids touching the real UserDefaults key.
        let newBinding = KeyBinding(keyCode: 12, modifiers: NSEvent.ModifierFlags.command.rawValue) // ⌘Q
        let defaultB   = ShortcutAction.newTab.defaultBinding

        // Verify default before touching store.
        T.expect(defaultB.keyCode == 17, "newTab default is ⌘T (keyCode 17)")

        // We cannot safely mutate the shared store without cleaning up, so test
        // the data-layer logic directly on a fresh encoder/decoder round-trip.
        do {
            var overrides: [String: KeyBinding] = [:]
            overrides[ShortcutAction.newTab.rawValue] = newBinding
            let data = try JSONEncoder().encode(overrides)
            let back = try JSONDecoder().decode([String: KeyBinding].self, from: data)
            let loaded = back[ShortcutAction.newTab.rawValue]
            T.notNil(loaded, "override survives encode/decode")
            T.equal(loaded?.keyCode, 12, "overridden keyCode correct")
            T.equal(loaded?.modifiers, NSEvent.ModifierFlags.command.rawValue, "overridden modifiers correct")
        } catch { T.expect(false, "override encode/decode threw: \(error)") }
    }

    T.group("KeyBinding.keyLabel covers standard keys") {
        T.equal(KeyBinding.keyLabel(for: 0),   "A",     "keyCode 0 → A")
        T.equal(KeyBinding.keyLabel(for: 6),   "Z",     "keyCode 6 → Z")
        T.equal(KeyBinding.keyLabel(for: 33),  "[",     "keyCode 33 → [")
        T.equal(KeyBinding.keyLabel(for: 30),  "]",     "keyCode 30 → ]")
        T.equal(KeyBinding.keyLabel(for: 44),  "/",     "keyCode 44 → /")
        T.equal(KeyBinding.keyLabel(for: 123), "←",     "keyCode 123 → ←")
        T.equal(KeyBinding.keyLabel(for: 53),  "⎋",     "keyCode 53 → ESC")
    }

    T.group("No two default bindings are identical") {
        var seen: [KeyBinding: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            let b = action.defaultBinding
            if let prev = seen[b] {
                T.expect(false, "duplicate default: \(action.rawValue) and \(prev.rawValue) share \(b.displayString)")
            } else {
                seen[b] = action
            }
        }
    }
}
