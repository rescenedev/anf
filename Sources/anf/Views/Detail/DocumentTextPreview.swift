import SwiftUI

/// Extracts plain text from ZIP+XML office documents (hwpx / docx / pptx / xlsx)
/// by unzipping the text-bearing XML and stripping tags. No QuickLook generator
/// (e.g. 알한글) required — just a readable text body.
enum DocumentText {
    static func canExtract(_ ext: String) -> Bool {
        ["hwpx", "docx", "pptx", "xlsx"].contains(ext.lowercased())
    }

    static func extract(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        guard canExtract(ext),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip") else { return nil }
        let pattern: String
        switch ext {
        case "hwpx": pattern = "Contents/*.xml"
        case "docx": pattern = "word/document.xml"
        case "pptx": pattern = "ppt/slides/*.xml"
        case "xlsx": pattern = "xl/sharedStrings.xml"
        default:     pattern = "*.xml"
        }
        let cmd = "unzip -p \(shq(url.path)) \(shq(pattern)) 2>/dev/null"
        let raw = ExternalTools.run("/bin/sh", ["-c", cmd], maxLines: 200_000, timeout: 8)
            .joined(separator: "\n")
        guard !raw.isEmpty else { return nil }
        return strip(raw)
    }

    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Internal (not private) so unit tests can exercise tag/entity stripping.
    static func strip(_ s: String) -> String {
        var t = s
        // Paragraph boundaries → newlines (HWPML / OOXML / ODF).
        for end in ["</hp:p>", "</w:p>", "</a:p>", "</text:p>"] {
            t = t.replacingOccurrences(of: end, with: "\n")
        }
        // Drop all remaining tags.
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode common entities.
        for (k, v) in ["&lt;": "<", "&gt;": ">", "&quot;": "\"",
                       "&apos;": "'", "&#10;": "\n", "&#9;": "\t", "&amp;": "&"] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        t = t.replacingOccurrences(of: "&#[0-9]+;", with: " ", options: .regularExpression)
        // Trim lines, collapse runs of blank lines.
        var out: [String] = []
        var blank = false
        for line in t.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { if !blank { out.append("") }; blank = true }
            else { out.append(l); blank = false }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Inspector preview for office documents: shows the extracted body text.
struct DocumentTextPreview: View {
    let url: URL
    var fontSize: CGFloat = 12.5
    @State private var text: String?
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("본문 추출 중…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if let text, !text.isEmpty {
                ScrollView {
                    Text(text)
                        .font(.system(size: fontSize))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "doc.text").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("미리볼 텍스트가 없습니다").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            loading = true
            text = await Task.detached(priority: .userInitiated) { DocumentText.extract(url) }.value
            loading = false
        }
    }
}
