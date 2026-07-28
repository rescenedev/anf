import SwiftUI
import AppKit

/// jq-style pretty printing for the inspector, with zero external tools:
/// JSONSerialization re-indents (jq isn't on macOS 14, and shelling out per
/// keystroke would be slow anyway) and a small scanner colors keys / strings /
/// numbers / literals the way jq does.
enum JSONPretty {
    /// UTF-16 code unit of an ASCII scalar (UInt16 has no `ascii:` initializer).
    private nonisolated static func u16(_ c: Unicode.Scalar) -> UInt16 { UInt16(c.value) }

    /// Re-serialize as indented JSON, or nil when it isn't valid JSON.
    /// Keys are sorted — NSDictionary loses source order, so sorted beats random.
    nonisolated static func prettyString(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    /// Colorize pretty-printed JSON. The input is well-formed (we produced it),
    /// so a single pass with a tiny string-state machine is enough.
    nonisolated static func highlight(_ pretty: String, fontSize: CGFloat) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let out = NSMutableAttributedString(
            string: pretty,
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        let chars = Array(pretty.utf16)
        let ns = pretty as NSString

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == u16("\"") {
                // String literal: scan to the unescaped closing quote.
                var j = i + 1
                while j < chars.count {
                    if chars[j] == u16("\\") { j += 2; continue }
                    if chars[j] == u16("\"") { break }
                    j += 1
                }
                let end = min(j, chars.count - 1)
                // Key when the next non-space char is ':'.
                var k = end + 1
                while k < chars.count, chars[k] == u16(" ") { k += 1 }
                let isKey = k < chars.count && chars[k] == u16(":")
                out.addAttribute(.foregroundColor,
                                 value: isKey ? NSColor.systemTeal : NSColor.systemGreen,
                                 range: NSRange(location: i, length: end - i + 1))
                i = end + 1
            } else if c == u16("-") || (c >= u16("0") && c <= u16("9")) {
                var j = i
                while j < chars.count, "0123456789+-.eE".utf16.contains(chars[j]) { j += 1 }
                out.addAttribute(.foregroundColor, value: NSColor.systemOrange,
                                 range: NSRange(location: i, length: j - i))
                i = j
            } else if c == u16("t") || c == u16("f") || c == u16("n") {
                for word in ["true", "false", "null"] where ns.length - i >= word.count {
                    if ns.substring(with: NSRange(location: i, length: word.count)) == word {
                        out.addAttribute(.foregroundColor, value: NSColor.systemPurple,
                                         range: NSRange(location: i, length: word.count))
                        i += word.count - 1
                        break
                    }
                }
                i += 1
            } else {
                i += 1
            }
        }
        return out
    }
}

/// Inspector preview for .json: pretty-printed and colorized. Falls back to the
/// plain text preview when the file is too big or isn't valid JSON.
struct JSONPreview: View {
    let url: URL
    var fontSize: CGFloat = 12.5

    @State private var rich: NSAttributedString?
    @State private var fallback = false

    private let byteCap = 2 * 1024 * 1024   // pretty-printing is cheap; cap for sanity

    var body: some View {
        Group {
            if fallback {
                TextFilePreview(url: url, fontSize: fontSize)
            } else {
                AttributedTextScrollView(text: rich ?? NSAttributedString())
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            }
        }
        .task(id: "\(url.path)|\(fontSize)") {
            let cap = byteCap, size = fontSize
            let result = await Task.detached(priority: .userInitiated) { () -> Handoff<NSAttributedString?> in
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      data.count <= cap,
                      let pretty = JSONPretty.prettyString(data) else { return Handoff(nil) }
                return Handoff(JSONPretty.highlight(pretty, fontSize: size))
            }.value.value
            if let result { rich = result; fallback = false }
            else { fallback = true }
        }
    }
}

/// Read-only NSTextView showing an attributed string (TextKit viewport layout).
struct AttributedTextScrollView: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.textContainer?.widthTracksTextView = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.textStorage?.isEqual(to: text) != true {
            tv.textStorage?.setAttributedString(text)
            tv.scroll(.zero)
        }
    }
}
