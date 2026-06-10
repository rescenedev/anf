import SwiftUI

/// Plain-text preview for scripts/source/text files. Quick Look draws these at a
/// tiny fixed size; here the font is readable and the text is selectable. Reads
/// at most `byteCap` so a giant log can't stall the inspector.
struct TextFilePreview: View {
    let url: URL
    var fontSize: CGFloat = 12.5

    @State private var text = ""
    @State private var truncated = false

    private let byteCap = 512 * 1024

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? " " : text)
                .font(.system(size: fontSize, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        .safeAreaInset(edge: .bottom) {
            if truncated {
                Text("Preview truncated")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(.bar)
            }
        }
        .task(id: url) {
            let cap = byteCap
            let loaded = await Task.detached(priority: .userInitiated) { () -> (String, Bool) in
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    return ("", false)
                }
                let slice = data.prefix(cap)
                return (String(decoding: slice, as: UTF8.self), data.count > cap)
            }.value
            text = loaded.0
            truncated = loaded.1
        }
    }
}
