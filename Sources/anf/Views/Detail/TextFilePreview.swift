import SwiftUI
import AppKit

/// Plain-text preview for scripts/source/text files. Quick Look draws these at a
/// tiny fixed size; here the font is readable and the text is selectable. Reads
/// at most `byteCap` so a giant log can't stall the inspector.
///
/// Rendering rides on NSTextView (TextKit), NOT a single SwiftUI `Text`: Text
/// lays out the ENTIRE string before showing anything, so a 512KB json froze
/// the arrow keys for a beat every time the selection crossed it. TextKit lays
/// out only the viewport.
struct TextFilePreview: View {
    let url: URL
    var fontSize: CGFloat = 12.5

    @State private var text = ""
    @State private var rich: NSAttributedString?
    @State private var truncated = false

    private let byteCap = 512 * 1024

    var body: some View {
        Group {
            if let rich {
                // Known code extension → four-class syntax highlighting
                // (comments / strings / numbers / keywords), zero dependencies.
                AttributedTextScrollView(text: rich)
            } else {
                PlainTextScrollView(text: text, fontSize: fontSize)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        .safeAreaInset(edge: .bottom) {
            if truncated {
                Text(L("Preview truncated", "미리보기가 잘렸습니다"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(.bar)
            }
        }
        .task(id: "\(url.path)|\(fontSize)") {
            let cap = byteCap, ext = url.pathExtension, size = fontSize
            let loaded = await Task.detached(priority: .userInitiated) { () -> (String, NSAttributedString?, Bool) in
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    return ("", nil, false)
                }
                let slice = data.prefix(cap)
                let s = TextDecoding.string(from: slice)
                return (s, CodeHighlight.highlight(s, ext: ext, fontSize: size), data.count > cap)
            }.value
            text = loaded.0
            rich = loaded.1
            truncated = loaded.2
        }
    }
}

/// Read-only NSTextView in a scroll view — TextKit's viewport-only layout keeps
/// huge files cheap, and selection/copy work like any native text view.
struct PlainTextScrollView: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat

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
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if tv.string != text {
            tv.string = text
            tv.scroll(.zero)
        }
        if tv.font != font {
            tv.font = font
            tv.textColor = .textColor
        }
    }
}
