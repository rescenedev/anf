import SwiftUI

/// Native docx preview: headings, tables, lists and bold parsed straight from
/// the document XML and rendered as full-width dark-mode blocks — instant,
/// unlike Quick Look's paginated page image that re-renders per selection and
/// never fills the pane.
struct DocxPreview: View {
    let url: URL
    var fontSize: CGFloat = 14

    @State private var blocks: [DocxBlock]?

    var body: some View {
        Group {
            if let blocks, blocks.isEmpty {
                // Parse produced nothing (exotic/locked file) — text fallback.
                DocumentTextPreview(url: url, fontSize: fontSize)
            } else if let blocks {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: max(9, fontSize * 0.55)) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            view(for: block)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            blocks = nil
            let target = url
            blocks = await Task.detached(priority: .userInitiated) {
                target.pathExtension.lowercased() == "hwpx"
                    ? HwpxStructure.parse(hwpxAt: target)
                    : DocxStructure.parse(docxAt: target)
            }.value
        }
    }

    @ViewBuilder private func view(for block: DocxBlock) -> some View {
        switch block {
        case .header(let level, let text):
            let scale: CGFloat = [1.55, 1.32, 1.18, 1.08, 1.02, 1.0][min(level, 6) - 1]
            Text(text)
                .font(.system(size: fontSize * scale, weight: .bold))
                .padding(.top, level <= 2 ? fontSize * 0.7 : fontSize * 0.3)
                .textSelection(.enabled)
        case .paragraph(let runs):
            Text(attributed(runs))
                .lineSpacing(fontSize * 0.22)
                .textSelection(.enabled)
        case .listItem(let text, let level):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("•")
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: fontSize * 1.3, alignment: .leading)
                Text(text)
                    .font(.system(size: fontSize))
                    .lineSpacing(fontSize * 0.22)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(level) * fontSize * 1.2)
        case .table(let rows):
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Divider() }
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { j, cell in
                            if j > 0 { Divider() }
                            Text(cell)
                                .font(.system(size: fontSize))
                                .textSelection(.enabled)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .background(Color.primary.opacity(0.03))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func attributed(_ runs: [(text: String, bold: Bool)]) -> AttributedString {
        var out = AttributedString()
        for r in runs {
            var a = AttributedString(r.text)
            a.font = .system(size: fontSize, weight: r.bold ? .bold : .regular)
            out += a
        }
        return out
    }
}
