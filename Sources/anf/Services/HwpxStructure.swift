import Foundation

/// Structured HWPX (OWPML) reader for the inspector — the hwpx counterpart of
/// DocxStructure, emitting the same DocxBlock list so one renderer serves both.
///
/// The old tag-strip extraction kept EVERY text node, so click-here form-field
/// metadata ("Clickhere:set:45:Direction…", "HelpState:wstring:0…") leaked into
/// the preview as garbage lines. Here only `<hp:t>` runs (the actual body text)
/// are collected, which silences field parameters, style names and the rest of
/// the container noise structurally.
final class HwpxStructure: NSObject, XMLParserDelegate {

    static func parse(hwpxAt url: URL) -> [DocxBlock] {
        var blocks: [DocxBlock] = []
        for entry in sectionEntries(of: url) {
            guard let xml = DocxStructure.unzipEntry(url, entry) else { continue }
            blocks += parse(sectionXML: xml)
        }
        return blocks
    }

    static func parse(sectionXML data: Data) -> [DocxBlock] {
        let reader = HwpxStructure()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.blocks
    }

    /// Contents/section0.xml, section1.xml… in document order.
    static func sectionEntries(of url: URL) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-Z1", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("Contents/section") && $0.hasSuffix(".xml") }
            .sorted { a, b in
                let na = Int(a.dropFirst("Contents/section".count).dropLast(".xml".count)) ?? 0
                let nb = Int(b.dropFirst("Contents/section".count).dropLast(".xml".count)) ?? 0
                return na < nb
            }
    }

    // MARK: - Parser state

    private var blocks: [DocxBlock] = []
    private var paragraphText = ""
    private var collectingText = false

    private var tableDepth = 0
    private var tableRows: [[String]] = []
    private var currentRow: [String] = []
    private var cellText = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes attrs: [String: String]) {
        switch name {
        case "hp:tbl":
            tableDepth += 1
            if tableDepth == 1 { tableRows = [] }
        case "hp:tr": if tableDepth == 1 { currentRow = [] }
        case "hp:tc": if tableDepth == 1 { cellText = "" }
        case "hp:p": paragraphText = ""
        case "hp:t": collectingText = true
        case "hp:lineBreak": paragraphText += "\n"
        case "hp:tab": paragraphText += "\t"
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // ONLY hp:t content is body text — everything else (field parameters,
        // style names, metadata) is noise by construction.
        if collectingText { paragraphText += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        switch name {
        case "hp:t": collectingText = false
        case "hp:p":
            let text = paragraphText.trimmingCharacters(in: .whitespacesAndNewlines)
            paragraphText = ""
            guard !text.isEmpty, !Self.isFieldJunk(text) else { return }
            if tableDepth > 0 {
                if !cellText.isEmpty { cellText += "\n" }
                cellText += text
            } else {
                blocks.append(.paragraph(runs: [(text, false)]))
            }
        case "hp:tc": if tableDepth == 1 { currentRow.append(cellText.trimmingCharacters(in: .whitespacesAndNewlines)); cellText = "" }
        case "hp:tr": if tableDepth == 1, !currentRow.isEmpty { tableRows.append(currentRow) }
        case "hp:tbl":
            tableDepth -= 1
            if tableDepth == 0, !tableRows.isEmpty { blocks.append(.table(rows: tableRows)) }
        default: break
        }
    }

    /// Belt and braces: some producers stuff click-here instructions inside
    /// hp:t too. Drop any line that is clearly field machinery, never prose.
    static func isFieldJunk(_ s: String) -> Bool {
        s.contains("Clickhere:set:") || s.contains("HelpState:wstring")
    }
}
