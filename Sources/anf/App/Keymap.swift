import AppKit

/// Every remappable app action. The raw value is the key users write in
/// keybindings.json, so renaming one is a breaking change.
enum KeyAction: String, CaseIterable {
    case newTab, closeTab
    case commandPalette, toggleTerminal
    case layoutSingle, layoutDual, layoutRows, layoutQuad
    case viewModePrev, viewModeNext
    case toggleSidebar, toggleInspector, togglePathBar
    case getInfo, duplicate, toggleFavorite
    case goToFolder, newFolder, reload, toggleHidden
    case goBack, goForward, goUp, openSelected
    case copyPath, copyFolderPath
    case transferCopy, transferMove
    case quickLook, rename, trash
    case openWith
    case openSettings
}

/// User-customizable shortcuts the Ghostty way: no settings UI — ⌘, opens
/// ~/.config/anf/keybindings.json, which ships PRE-FILLED with every default
/// binding so "current settings" are right there to edit. The file is the
/// source of truth for these actions: overriding an action replaces its default
/// chord(s), and binding a chord another action used by default steals it.
/// Re-read whenever anf becomes the active app — edit, switch back, done.
@MainActor
final class Keymap {
    static let shared = Keymap()

    struct Chord: Hashable {
        let flags: UInt   // deviceIndependent modifier raw value
        let key: String   // normalized token: "t", "f5", "up", "`", …
    }

    /// Single source of truth for the built-in bindings. The template is
    /// generated from this, so file and code can never drift apart.
    nonisolated static let defaults: [(KeyAction, [String])] = [
        (.newTab, ["cmd+t"]),
        (.closeTab, ["cmd+w"]),
        (.commandPalette, ["cmd+k", "cmd+p"]),
        (.toggleTerminal, ["ctrl+`"]),
        (.layoutSingle, ["cmd+1"]), (.layoutDual, ["cmd+2"]),
        (.layoutRows, ["cmd+3"]), (.layoutQuad, ["cmd+4"]),
        (.viewModePrev, ["cmd+["]), (.viewModeNext, ["cmd+]"]),
        (.toggleSidebar, ["cmd+shift+["]),
        (.toggleInspector, ["cmd+i", "cmd+shift+]"]),
        (.togglePathBar, ["cmd+/"]),
        (.getInfo, ["cmd+opt+i"]),
        (.duplicate, ["cmd+d"]),
        (.toggleFavorite, ["cmd+shift+d"]),
        (.goToFolder, ["cmd+l", "cmd+shift+g"]),
        (.newFolder, ["cmd+shift+n"]),
        (.reload, ["cmd+r"]),
        (.toggleHidden, ["cmd+shift+."]),
        (.goBack, ["cmd+left"]), (.goForward, ["cmd+right"]),
        (.goUp, ["cmd+up"]), (.openSelected, ["cmd+down"]),
        (.copyPath, ["cmd+opt+c"]), (.copyFolderPath, ["cmd+opt+shift+c"]),
        (.openWith, ["f4"]),
        (.transferCopy, ["f5", "shift+f5"]), (.transferMove, ["f6", "shift+f6"]),
        (.quickLook, ["space", "shift+space"]),
        (.rename, ["return", "shift+return", "enter", "shift+enter"]),
        (.trash, ["delete", "shift+delete", "cmd+delete"]),
        (.openSettings, ["cmd+,"]),
    ]

    private var bindings: [Chord: KeyAction] = [:]
    private var fileMTime: Date?
    private var observer: NSObjectProtocol?

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/anf/keybindings.json")
    }

    private init() {
        load()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { Keymap.shared.reloadIfChanged() } }
    }

    /// Only these modifiers participate in matching. Arrow and function keys
    /// also set .numericPad/.function on the event (and Caps Lock adds
    /// .capsLock) — exact-mask comparison broke ⌘↓/⌘↑ and F5/F6 in 1.1.0.
    nonisolated static let relevantFlags: NSEvent.ModifierFlags =
        [.command, .shift, .option, .control]

    /// The action bound to this (modifiers, key token), if any.
    func action(flags: NSEvent.ModifierFlags, key: String) -> KeyAction? {
        bindings[Chord(flags: flags.intersection(Self.relevantFlags).rawValue, key: key)]
    }

    // MARK: - Loading

    func reloadIfChanged() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: Self.fileURL.path)[.modificationDate]) as? Date
        guard mtime != fileMTime else { return }
        load()
    }

    private func load() {
        fileMTime = (try? FileManager.default.attributesOfItem(atPath: Self.fileURL.path)[.modificationDate]) as? Date
        bindings = Self.effectiveBindings(fileAt: Self.fileURL)
        // Non-key settings live in the same file (it IS the ⌘, settings file).
        // The file wins when edited; ⌘± keeps adjusting live in between.
        if let size = Self.previewTextSize(fileAt: Self.fileURL) {
            UserDefaults.standard.set(Double(size), forKey: "anf.previewTextSize")
            NotificationCenter.default.post(name: Self.previewTextSizeChanged, object: size)
        }
        if let ai = Self.aiFeatures(fileAt: Self.fileURL) {
            AIFeatures.enabled = ai
        }
        if let loc = Self.settingsDict(fileAt: Self.fileURL)["locationSearch"] as? Bool {
            UserDefaults.standard.set(loc, forKey: "anf.locationSearch")
        }
        // AI provider config (apple / local / claude). Mirror file → UserDefaults
        // so RemoteLLM / ClaudeLLM / LocalLLM all read one source.
        let dict = Self.settingsDict(fileAt: Self.fileURL)
        // NOTE: aiApiKey is deliberately NOT mirrored — the key lives only in the
        // macOS Keychain. Migrate any leftover plaintext key out of the file/defaults.
        for key in ["aiProvider", "aiEndpoint", "aiModel", "openWithApp"] {
            if let s = dict[key] as? String {
                UserDefaults.standard.set(s, forKey: "anf.\(key)")
            }
        }
        AISecret.migrate(settingsFile: Self.fileURL)
    }

    nonisolated static func settingsDict(fileAt url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return dict
    }

    /// "aiFeatures": true/false in the settings file, or nil when absent.
    nonisolated static func aiFeatures(fileAt url: URL) -> Bool? {
        settingsDict(fileAt: url)["aiFeatures"] as? Bool
    }

    static let previewTextSizeChanged = Notification.Name("anf.settings.previewTextSize")

    /// "previewTextSize": 18 in the settings file (9…28), or nil when absent.
    nonisolated static func previewTextSize(fileAt url: URL) -> CGFloat? {
        guard let data = try? Data(contentsOf: url),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let n = dict["previewTextSize"] as? Double, n >= 9, n <= 28 else { return nil }
        return CGFloat(n)
    }

    /// Defaults overlaid with the user's file: an action listed in the file
    /// drops its default chords first (rebinding frees the old key), then its
    /// new chords are set — overwriting (stealing) any default that used them.
    nonisolated static func effectiveBindings(fileAt url: URL) -> [Chord: KeyAction] {
        var map: [Chord: KeyAction] = [:]
        for (action, specs) in defaults {
            for spec in specs {
                if let chord = parseChord(spec) { map[chord] = action }
            }
        }
        for (action, chords) in fileEntries(at: url) {
            map = map.filter { $0.value != action }
            for chord in chords { map[chord] = action }
        }
        return map
    }

    /// Parse the file into action → chords. Values may be a string or an array
    /// of strings; "_"-prefixed keys are docs; junk is skipped, never fatal.
    nonisolated static func fileEntries(at url: URL) -> [(KeyAction, [Chord])] {
        guard let data = try? Data(contentsOf: url),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        var out: [(KeyAction, [Chord])] = []
        for name in dict.keys.sorted() {   // deterministic collision behavior
            guard !name.hasPrefix("_"), let action = KeyAction(rawValue: name) else { continue }
            let specs: [String]
            if let s = dict[name] as? String { specs = [s] }
            else if let a = dict[name] as? [String] { specs = a }
            else { continue }
            let chords = specs.compactMap { parseChord($0) }
            if !chords.isEmpty { out.append((action, chords)) }
        }
        return out
    }

    /// "cmd+shift+t" / "ctrl+`" / "f5" / "cmd+up" → Chord. Nil when malformed.
    nonisolated static func parseChord(_ spec: String) -> Chord? {
        var flags = NSEvent.ModifierFlags()
        var key: String?
        for raw in spec.lowercased().split(separator: "+", omittingEmptySubsequences: true) {
            let token = raw.trimmingCharacters(in: .whitespaces)
            switch token {
            case "cmd", "command", "meta": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt", "option", "alt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default:
                guard key == nil, validKeys.contains(token) else { return nil }
                key = token
            }
        }
        guard let key else { return nil }
        return Chord(flags: flags.intersection(relevantFlags).rawValue, key: key)
    }

    /// Tokens we can actually match against an NSEvent.
    nonisolated static let validKeys: Set<String> = {
        var s = Set("abcdefghijklmnopqrstuvwxyz0123456789".map(String.init))
        s.formUnion((1...12).map { "f\($0)" })
        s.formUnion(["space", "return", "enter", "tab", "escape", "esc", "delete",
                     "up", "down", "left", "right", "home", "end", "pageup", "pagedown",
                     "`", "[", "]", "/", "\\", "=", "-", ".", ",", ";", "'"])
        return s
    }()

    /// Normalized token for a key event: physical keycode first (works under
    /// the Korean IME — same trick as the latinLetter table), then whatever the
    /// event claims was typed.
    nonisolated static func token(keyCode: UInt16, fallback: String?) -> String {
        if let s = special[keyCode] { return s }
        return (fallback ?? "").lowercased()
    }

    /// keyCode → token for keys whose characters are IME-dependent or useless.
    nonisolated static let special: [UInt16: String] = [
        // letters (physical position, input-source independent)
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c",
        9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k",
        45: "n", 46: "m",
        // digits
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        // punctuation by position
        50: "`", 33: "[", 30: "]", 44: "/", 42: "\\", 24: "=", 27: "-", 47: ".", 43: ",", 41: ";", 39: "'",
        // editing / navigation
        49: "space", 36: "return", 76: "enter", 48: "tab", 53: "escape", 51: "delete",
        123: "left", 124: "right", 125: "down", 126: "up",
        115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        // function row
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    // MARK: - Settings file (⌘,)

    /// ⌘, the Ghostty way: make sure the pre-filled file exists, then open it
    /// in the user's editor. Edits apply when anf becomes active again.
    static func openSettingsFile() {
        let url = ensureFileExists()
        migrateMissingSettings(at: url)
        NSWorkspace.shared.open(url)
    }

    /// Files created by older templates lack newer settings keys. Append them
    /// TEXTUALLY (before the closing brace) so the user's formatting and edits
    /// survive — re-serializing would mangle their hand-written file.
    nonisolated static func migrateMissingSettings(at url: URL) {
        guard let s = try? String(contentsOf: url, encoding: .utf8),
              let data = s.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any],
              let brace0 = s.range(of: "}", options: .backwards) else { return }
        var out = s
        func appendKey(_ key: String, _ value: String) {
            guard let data = out.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  dict[key] == nil,
                  let brace = out.range(of: "}", options: .backwards) else { return }
            let head = out[..<brace.lowerBound]
            guard let lastIdx = head.lastIndex(where: { !" \n\t".contains($0) }) else { return }
            let comma = (head[lastIdx] == "{" || head[lastIdx] == ",") ? "" : ","
            out.replaceSubrange(head.index(after: lastIdx)..<brace.lowerBound,
                                with: "\(comma)\n  \"\(key)\": \(value)\n")
        }
        _ = brace0
        let stored = UserDefaults.standard.double(forKey: "anf.previewTextSize")
        let size = stored >= 9 && stored <= 28 ? Int(stored) : 16
        appendKey("previewTextSize", "\(size)")
        appendKey("aiFeatures", AIFeatures.enabled ? "true" : "false")
        appendKey("aiProvider", "\"auto\"")
        appendKey("aiEndpoint", "\"\"")
        appendKey("aiModel", "\"\"")
        appendKey("openWithApp", "\"\"")
        appendKey("favorites", "[]")
        appendKey("workspaces", "[]")
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Create the keybindings file pre-filled with EVERY current default
    /// binding (the user asked for "current settings already in the file").
    @discardableResult
    static func ensureFileExists() -> URL {
        let url = fileURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// Generated from `defaults`, so the file can never drift from the code.
    nonisolated static var template: String {
        var lines: [String] = ["{"]
        lines.append("""
          "_readme": [
            "anf settings — every line below IS the current value; edit and switch back to anf to apply.",
            "Keybindings — modifiers: cmd shift opt ctrl, joined with +.  Keys: a-z 0-9 f1-f12 space return tab",
            "escape delete up down left right home end pageup pagedown ` [ ] / \\\\ = - . , ; '",
            "An action may have several chords (JSON array). Rebinding an action frees its old keys;",
            "binding a key another action used steals it. Menu items keep showing the factory shortcut.",
            "previewTextSize — inspector text previews (markdown/json/code/document), 9-28. ⌘+/⌘− also adjusts it live.",
            "aiFeatures — on-device AI (summarize, ask, suggest name, auto-tag, organize-by-content, image search). true/false. Also toggleable in the Tools menu.",
            "aiProvider — 'auto' (default): uses Claude when an API key is set, else a local endpoint, else Apple on-device. Force one with 'claude', 'local', or 'apple'.",
            "Anthropic API key — set it in the AI menu (AI → Set Anthropic API Key…). It is stored in the macOS Keychain, NEVER in this file. (The ANTHROPIC_API_KEY env var is used only when aiProvider is set to 'claude', so a stray env key never sends to the cloud on its own.)",
            "aiEndpoint — local OpenAI-compatible URL for 'local', e.g. 'http://localhost:11434/v1' (Ollama) or 'http://localhost:1234/v1' (LM Studio).",
            "aiModel — override the model, e.g. 'claude-opus-4-8' or 'llama3.2'. Empty uses the provider default.",
            "openWithApp — app for the 'Open With' action (name, path, or bundle id), e.g. 'Typora'. The shortcut is the 'openWith' keybinding below (default F4).",
            "favorites / pinned — paths to pin in the sidebar, e.g. ['~/Code', '~/Documents/Work']. Each imported once (great for migrating to a new Mac).",
            "workspaces — saved window arrangements (use Tools → Copy Pins & Workspaces to generate this).",
            "locationSearch — find photos by place in ⌘K (e.g. 'find photos in Paris'). Reads EXIF GPS locally but geocodes the place name online, so it's off by default. true/false."
          ],
          "previewTextSize": 16,
          "aiFeatures": false,
          "aiProvider": "auto",
          "aiEndpoint": "",
          "aiModel": "",
          "openWithApp": "",
          "locationSearch": false,
          "favorites": [],
          "workspaces": [],
        """)
        for (i, entry) in defaults.enumerated() {
            let (action, specs) = entry
            let value = specs.count == 1
                ? "\"\(specs[0])\""
                : "[" + specs.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
            let comma = i == defaults.count - 1 ? "" : ","
            lines.append("  \"\(action.rawValue)\": \(value)\(comma)")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }
}
