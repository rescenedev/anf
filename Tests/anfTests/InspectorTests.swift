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
            var fired = false
            withObservationTracking {
                _ = model.selectedItems        // cache-hit path
            } onChange: {
                fired = true
            }
            model.selection = [dir.appendingPathComponent("x")]   // a real change must notify
            T.expect(fired, "selection change re-renders a warm-cache reader")
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
            T.equal(WorkspaceModel.loadPreviewTextSize(), 14, "default is 14 — reading size")
            UserDefaults.standard.set(18.0, forKey: key)
            T.equal(WorkspaceModel.loadPreviewTextSize(), 18, "⌘± choice survives relaunch")
            UserDefaults.standard.set(99.0, forKey: key)
            T.equal(WorkspaceModel.loadPreviewTextSize(), 14, "out-of-range value falls back")
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
