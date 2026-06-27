import SwiftUI
import PDFKit

/// Extracts plain text from ZIP+XML office documents (hwpx / docx / pptx / xlsx)
/// by unzipping the text-bearing XML and stripping tags, and from PDFs via
/// PDFKit. No QuickLook generator (e.g. 알한글) required — just a readable body.
enum DocumentText {
    static func canExtract(_ ext: String) -> Bool {
        ["hwpx", "docx", "pptx", "xlsx", "pdf"].contains(ext.lowercased())
    }

    /// Pages to walk per PDF — bounds extraction time on thousand-page scans.
    private static let pdfPageCap = 200

    static func extract(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return extractPDF(url) }
        guard canExtract(ext),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip") else { return nil }
        if ext == "xlsx" { return extractXLSX(url) }
        let pattern: String
        switch ext {
        case "hwpx": pattern = "Contents/*.xml"
        case "docx": pattern = "word/document.xml"
        case "pptx": pattern = "ppt/slides/*.xml"
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

    /// PDFKit text layer (no OCR — image-only scans have no text to extract).
    private static func extractPDF(_ url: URL) -> String? {
        guard let doc = PDFDocument(url: url), !doc.isLocked else { return nil }
        var parts: [String] = []
        for i in 0 ..< min(doc.pageCount, pdfPageCap) {
            if let s = doc.page(at: i)?.string, !s.isEmpty { parts.append(s) }
        }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    // MARK: - xlsx (spreadsheet body)

    /// Reconstruct an xlsx body cell-by-cell in row order, resolving shared-string
    /// indices against xl/sharedStrings.xml. The old path dumped ONLY sharedStrings
    /// with no separators, so every cell glued into one run-on line and numeric /
    /// inline-string sheets showed nothing. Internal so unit tests can drive it.
    static func extractXLSX(_ url: URL) -> String? {
        let shared = xlsxSharedStrings(url)
        var lines: [String] = []
        let sheetCap = 8
        for sheet in unzipList(url, glob: "xl/worksheets/sheet*.xml").sorted().prefix(sheetCap) {
            guard let xml = unzipEntry(url, sheet) else { continue }
            for row in xlsxFragments(xml, tag: "row") {
                let cells = xlsxFragments(row.body, tag: "c").map { xlsxCellValue(attrs: $0.attrs, body: $0.body, shared: shared) }
                let line = cells.joined(separator: "\t")
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
            }
        }
        // Couldn't read a worksheet (unusual layout) but have strings → at least
        // show them one per line, still readable (no glue).
        if lines.isEmpty, !shared.isEmpty { lines = shared.filter { !$0.isEmpty } }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    private static func xlsxSharedStrings(_ url: URL) -> [String] {
        guard let xml = unzipEntry(url, "xl/sharedStrings.xml") else { return [] }
        // A shared string may be several rich-text runs: <si><r><t>a</t></r><r><t>b</t></r></si>.
        return xlsxFragments(xml, tag: "si").map { xlsxTexts(in: $0.body).joined() }
    }

    private static func xlsxCellValue(attrs: String, body: String, shared: [String]) -> String {
        switch xlsxAttr("t", in: attrs) {
        case "s":   // shared-string index
            let v = xlsxFirstTag("v", in: body).trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = Int(v), i >= 0, i < shared.count { return shared[i] }
            return ""
        case "inlineStr":
            return xlsxTexts(in: body).joined()
        default:    // "str" formula result, or numeric / boolean / date serial
            return decodeXMLEntities(xlsxFirstTag("v", in: body))
        }
    }

    /// `<tag …>body</tag>` fragments (attrs + body), self-closing tags skipped.
    private static func xlsxFragments(_ xml: String, tag: String) -> [(attrs: String, body: String)] {
        guard let re = try? NSRegularExpression(pattern: "<\(tag)(\\s[^>]*)?>(.*?)</\(tag)>",
                                                options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = xml as NSString
        return re.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map { m in
            let a = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ""
            return (a, ns.substring(with: m.range(at: 2)))
        }
    }

    private static func xlsxTexts(in xml: String) -> [String] {
        xlsxFragments(xml, tag: "t").map { decodeXMLEntities($0.body) }
    }

    private static func xlsxFirstTag(_ tag: String, in body: String) -> String {
        xlsxFragments(body, tag: tag).first?.body ?? ""
    }

    private static func xlsxAttr(_ name: String, in attrs: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\b\(name)=\"([^\"]*)\"") else { return "" }
        let ns = attrs as NSString
        if let m = re.firstMatch(in: attrs, range: NSRange(location: 0, length: ns.length)) {
            return ns.substring(with: m.range(at: 1))
        }
        return ""
    }

    private static func unzipEntry(_ url: URL, _ entry: String) -> String? {
        let cmd = "unzip -p \(shq(url.path)) \(shq(entry)) 2>/dev/null"
        let raw = ExternalTools.run("/bin/sh", ["-c", cmd], maxLines: 200_000, timeout: 8).joined(separator: "\n")
        return raw.isEmpty ? nil : raw
    }

    private static func unzipList(_ url: URL, glob: String) -> [String] {
        let cmd = "unzip -Z1 \(shq(url.path)) \(shq(glob)) 2>/dev/null"
        return ExternalTools.run("/bin/sh", ["-c", cmd], maxLines: 1000, timeout: 8).filter { !$0.isEmpty }
    }

    /// XML entity decode, `&amp;` LAST so "&amp;lt;" doesn't collapse to "<".
    private static func decodeXMLEntities(_ s: String) -> String {
        var t = s
        for (k, v) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
                       ("&#10;", "\n"), ("&#9;", "\t"), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t
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
                    Text(L("Extracting text…", "본문 추출 중…")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if let text, !text.isEmpty {
                // TextKit, not one big SwiftUI Text: Text lays out the WHOLE
                // body before painting, which hitched the arrow keys on long
                // documents (same fix as the json/plain-text previews).
                PlainTextScrollView(text: text, fontSize: fontSize)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "doc.text").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(L("No text to preview", "미리볼 텍스트가 없습니다")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            loading = true
            text = await Task.detached(priority: .userInitiated) {
                DocumentTextCache.shared.text(for: url)
            }.value
            loading = false
        }
    }
}
