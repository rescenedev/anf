import AppKit
import Foundation
@testable import anf

/// Inspector regression pack (2026-06-13 user reports):
/// 1. The preview stopped following arrow-key selection — the memoized
///    `selectedItems` returned the warm cache WITHOUT reading `selection`, so a
///    SwiftUI body evaluating after another reader registered no Observation
///    dependency and went permanently stale.
/// 2. Opaque binaries (.so) must take the instant-placeholder path, never QL.
/// 3. Markdown gets a real block-parsed preview.
func runInspectorTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("anfinsp-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        T.group("selectedItems registers Observation deps even on a warm cache") {
            let model = BrowserModel(start: dir)
            _ = model.selectedItems            // warm the memo OUTSIDE tracking
            // A class box, not a captured var: onChange is @Sendable, and mutating
            // a captured local there is a Swift 6 data-race error.
            final class Flag: @unchecked Sendable { var fired = false }
            let flag = Flag()
            withObservationTracking {
                _ = model.selectedItems        // cache-hit path
            } onChange: {
                flag.fired = true
            }
            model.selection = [dir.appendingPathComponent("x")]   // a real change must notify
            T.expect(flag.fired, "selection change re-renders a warm-cache reader")
        }

        T.group("opaque binary / markdown classification") {
            func make(_ name: String) -> FileItem? {
                let u = dir.appendingPathComponent(name)
                fm.createFile(atPath: u.path, contents: Data("x".utf8))
                return FileItem(url: u)
            }
            T.expect(make("lib.so")?.isOpaqueBinary == true, ".so → instant placeholder")
            T.expect(make("lib.dylib")?.isOpaqueBinary == true, ".dylib → instant placeholder")
            T.expect(make("a.md")?.isOpaqueBinary == false, ".md is not a binary")
            T.expect(make("a.md")?.isMarkdown == true, ".md → markdown preview")
            T.expect(make("b.markdown")?.isMarkdown == true, ".markdown → markdown preview")
            T.expect(make("c.txt")?.isMarkdown == false, ".txt stays plain text")
        }

        T.group("preview text size: defaults large, persists, clamps") {
            let key = "anf.previewTextSize"
            UserDefaults.standard.removeObject(forKey: key)
            T.equal(WorkspaceModel.loadPreviewTextSize(), 16, "default is 16 — reading size")
            UserDefaults.standard.set(18.0, forKey: key)
            T.equal(WorkspaceModel.loadPreviewTextSize(), 18, "⌘± choice survives relaunch")
            UserDefaults.standard.set(99.0, forKey: key)
            T.equal(WorkspaceModel.loadPreviewTextSize(), 16, "out-of-range value falls back")
            UserDefaults.standard.removeObject(forKey: key)
        }

        T.group("JSONPretty") {
            let pretty = JSONPretty.prettyString(Data(#"{"b":1,"a":{"k":[true,null,"s"]}}"#.utf8))
            T.expect(pretty?.contains("\n") == true, "re-indents")
            T.expect(pretty?.contains("\"a\"") == true, "keys survive")
            T.expect(JSONPretty.prettyString(Data("not json".utf8)) == nil, "invalid → nil (text fallback)")
            if let pretty {
                let rich = JSONPretty.highlight(pretty, fontSize: 12)
                T.equal(rich.length, (pretty as NSString).length, "highlight keeps full text")
                var colors = Set<NSColor>()
                rich.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: rich.length)) { v, _, _ in
                    if let c = v as? NSColor { colors.insert(c) }
                }
                T.expect(colors.count >= 3, "keys/strings/numbers colored distinctly (got \(colors.count))")
            }
        }

        T.group("CodeHighlight") {
            func colors(_ src: String, _ ext: String) -> Int {
                guard let rich = CodeHighlight.highlight(src, ext: ext, fontSize: 14) else { return 0 }
                var set = Set<NSColor>()
                rich.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: rich.length)) { v, _, _ in
                    if let c = v as? NSColor { set.insert(c) }
                }
                return set.count
            }
            T.expect(CodeHighlight.lang(for: "sh") != nil, "sh recognized")
            T.expect(CodeHighlight.lang(for: "ts") != nil, "ts recognized")
            T.expect(CodeHighlight.lang(for: "java") != nil, "java recognized")
            T.expect(CodeHighlight.lang(for: "css") != nil, "css recognized")
            T.expect(CodeHighlight.lang(for: "txt") == nil, "txt stays plain")
            T.expect(colors("#!/bin/sh\n# c\nif [ \"$x\" = 1 ]; then echo 2; fi", "sh") >= 4,
                     "sh: comment/string/number/keyword all colored")
            T.expect(colors("// c\nconst x: string = \"hi\"; let n = 42;", "ts") >= 4,
                     "ts: four classes colored")
            T.expect(colors("SELECT id FROM t WHERE x = 'a' -- c", "sql") >= 4,
                     "sql: case-insensitive keywords")
            let kept = CodeHighlight.highlight("let x = 1", ext: "swift", fontSize: 14)
            T.equal(kept?.string, "let x = 1", "text content untouched")
        }

        T.group("settings file previewTextSize") {
            let f = dir.appendingPathComponent("settings.json")
            try? #"{"previewTextSize": 18, "newTab": "cmd+t"}"#.write(to: f, atomically: true, encoding: .utf8)
            T.equal(Keymap.previewTextSize(fileAt: f), 18, "size read from the ⌘, file")
            try? #"{"previewTextSize": 99}"#.write(to: f, atomically: true, encoding: .utf8)
            T.expect(Keymap.previewTextSize(fileAt: f) == nil, "out-of-range ignored")
            T.expect(Keymap.previewTextSize(fileAt: dir.appendingPathComponent("no.json")) == nil,
                     "missing file → nil")
            T.expect(Keymap.template.contains("\"previewTextSize\": 16"),
                     "template pre-fills the setting")
        }

        T.group("settings migration appends previewTextSize to old files") {
            let f = dir.appendingPathComponent("old-template.json")
            try? "{\n  \"newTab\": \"cmd+t\",\n  \"openSettings\": \"cmd+,\"\n}\n"
                .write(to: f, atomically: true, encoding: .utf8)
            Keymap.migrateMissingSettings(at: f)
            let after = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            let dict = (try? JSONSerialization.jsonObject(with: Data(after.utf8))) as? [String: Any]
            T.expect(dict?["previewTextSize"] != nil, "key appended")
            T.equal(dict?["newTab"] as? String, "cmd+t", "existing entries untouched")
            T.expect(after.contains("\"openSettings\": \"cmd+,\","), "comma added after last entry")
            // Already has the key → file untouched (idempotent).
            let before2 = after
            Keymap.migrateMissingSettings(at: f)
            T.equal((try? String(contentsOf: f, encoding: .utf8)) ?? "", before2, "second run is a no-op")
        }

        T.group("MarkdownBlocks.parse") {
            let src = """
            # Title

            Some **bold** text.

            - first
            - second

            ```
            let x = 1
            ```
            """
            let blocks = MarkdownBlocks.parse(src)
            T.expect(blocks.count >= 4, "splits into blocks (got \(blocks.count))")
            T.expect(blocks.first?.kind == .header(1), "first block is an H1")
            T.expect(blocks.contains { $0.kind == .codeBlock }, "code block recognized")
            T.expect(blocks.contains {
                if case .listItem = $0.kind { return true } else { return false }
            }, "list items recognized")
            let empty = MarkdownBlocks.parse("")
            T.expect(empty.isEmpty, "empty source → no blocks (no crash)")
        }
    }
}
