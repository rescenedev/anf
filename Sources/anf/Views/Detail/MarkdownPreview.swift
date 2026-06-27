import SwiftUI

/// One visual block of a markdown document (header, paragraph, code block, …).
/// Parsed from Foundation's own markdown support — no third-party parser.
struct MDBlock: Identifiable {
    enum Kind: Equatable {
        case header(Int)        // level 1…6
        case paragraph
        case codeBlock
        case quote
        case listItem(prefix: String, depth: Int)
        case divider
    }
    let id: Int
    let kind: Kind
    let text: AttributedString
}

enum MarkdownBlocks {
    /// Split markdown source into styled blocks by walking the presentation
    /// intents Foundation attaches. Pure and synchronous — testable, and run
    /// off the main thread by the view for large files.
    nonisolated static func parse(_ source: String) -> [MDBlock] {
        guard let parsed = try? AttributedString(
            markdown: source,
            options: .init(allowsExtendedAttributes: false,
                           interpretedSyntax: .full,
                           failurePolicy: .returnPartiallyParsedIfPossible)
        ) else {
            return [MDBlock(id: 0, kind: .paragraph, text: AttributedString(source))]
        }

        var blocks: [MDBlock] = []
        var currentIntent: PresentationIntent?
        var currentText = AttributedString()

        func flush() {
            guard !currentText.characters.isEmpty || currentIntent != nil else { return }
            let kind = kind(of: currentIntent)
            if kind == .divider || !currentText.characters.isEmpty {
                blocks.append(MDBlock(id: blocks.count, kind: kind, text: currentText))
            }
            currentText = AttributedString()
        }

        for run in parsed.runs {
            let intent = run.presentationIntent
            if intent != currentIntent {
                flush()
                currentIntent = intent
            }
            var slice = AttributedString(parsed[run.range])
            slice.presentationIntent = nil   // block styling is ours; keep inline styles
            currentText += slice
        }
        flush()
        return blocks
    }

    private nonisolated static func kind(of intent: PresentationIntent?) -> MDBlock.Kind {
        guard let intent else { return .paragraph }
        var listOrdinal: Int?
        var ordered = false
        var depth = 0
        for component in intent.components {
            switch component.kind {
            case .header(let level): return .header(min(max(level, 1), 6))
            case .codeBlock: return .codeBlock
            case .blockQuote: return .quote
            case .thematicBreak: return .divider
            case .listItem(let ordinal): listOrdinal = ordinal
            case .orderedList: ordered = true; depth += 1
            case .unorderedList: depth += 1
            default: break
            }
        }
        if let n = listOrdinal {
            return .listItem(prefix: ordered ? "\(n)." : "•", depth: max(depth, 1))
        }
        return .paragraph
    }
}

/// Rendered markdown preview for the inspector: headers, lists, quotes and
/// code blocks instead of a wall of raw text. Reads at most `byteCap`.
struct MarkdownPreview: View {
    let url: URL
    var fontSize: CGFloat = 13

    @State private var blocks: [MDBlock] = []
    @State private var truncated = false
    private let byteCap = 512 * 1024

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: max(9, fontSize * 0.55)) {
                ForEach(blocks) { block in
                    view(for: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
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
        .task(id: url) {
            let cap = byteCap
            let loaded = await Task.detached(priority: .userInitiated) { () -> ([MDBlock], Bool) in
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    return ([], false)
                }
                let slice = data.prefix(cap)
                let text = TextDecoding.string(from: slice)
                return (MarkdownBlocks.parse(text), data.count > cap)
            }.value
            blocks = loaded.0
            truncated = loaded.1
        }
    }

    /// Inline-code chips: SwiftUI's Text honors inlinePresentationIntent for
    /// bold/italic but draws `code` in the same body font — give code runs a
    /// monospaced face and a subtle chip so code-dense docs stay readable.
    private func inlineStyled(_ text: AttributedString, codeSize: CGFloat) -> AttributedString {
        var t = text
        for run in t.runs {
            if let inline = run.inlinePresentationIntent, inline.contains(.code) {
                t[run.range].font = .system(size: codeSize, design: .monospaced)
                t[run.range].backgroundColor = Color.primary.opacity(0.09)
            }
        }
        return t
    }

    @ViewBuilder private func view(for block: MDBlock) -> some View {
        switch block.kind {
        case .header(let level):
            let scale: CGFloat = [1.65, 1.4, 1.22, 1.1, 1.05, 1.0][level - 1]
            Text(inlineStyled(block.text, codeSize: fontSize * scale - 1))
                .font(.system(size: fontSize * scale, weight: .bold))
                .padding(.top, level <= 2 ? fontSize * 0.7 : fontSize * 0.3)
                .textSelection(.enabled)
        case .codeBlock:
            Text(block.text)
                .font(.system(size: fontSize - 1, design: .monospaced))
                .lineSpacing(fontSize * 0.15)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .quote:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                Text(inlineStyled(block.text, codeSize: fontSize - 1))
                    .font(.system(size: fontSize))
                    .lineSpacing(fontSize * 0.22)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .listItem(let prefix, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(prefix)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: fontSize * 1.3, alignment: .leading)
                Text(inlineStyled(block.text, codeSize: fontSize - 1))
                    .font(.system(size: fontSize))
                    .lineSpacing(fontSize * 0.22)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(depth - 1) * fontSize * 1.2)
        case .divider:
            Divider().padding(.vertical, 4)
        case .paragraph:
            Text(inlineStyled(block.text, codeSize: fontSize - 1))
                .font(.system(size: fontSize))
                .lineSpacing(fontSize * 0.22)
                .textSelection(.enabled)
        }
    }
}
