import AppKit
import Foundation
@testable import anf

func runDocumentTextTests() {
    T.group("DocumentText") {
        T.expect(DocumentText.canExtract("hwpx"), "hwpx extractable")
        T.expect(DocumentText.canExtract("DOCX"), "case-insensitive ext")
        T.expect(DocumentText.canExtract("pptx"), "pptx extractable")
        T.expect(DocumentText.canExtract("xlsx"), "xlsx extractable")
        T.expect(!DocumentText.canExtract("txt"), "txt not extractable")
        T.expect(!DocumentText.canExtract(""), "empty not extractable")

        let stripped = DocumentText.strip("<hp:p><hp:run>금융위</hp:run></hp:p><hp:p>원회 규정</hp:p>")
        T.expect(stripped.contains("금융위"), "keeps text 1")
        T.expect(stripped.contains("원회 규정"), "keeps text 2")
        T.expect(!stripped.contains("<"), "removes tags")
        T.expect(!stripped.contains("hp:"), "removes tag prefixes")

        let para = DocumentText.strip("<w:p>line one</w:p><w:p>line two</w:p>")
        T.expect(para.contains("line one") && para.contains("line two"), "keeps paragraphs")
        T.expect(para.contains("\n"), "paragraph boundary → newline")

        let ent = DocumentText.strip("<w:p>a &amp; b &lt;c&gt; &quot;d&quot;</w:p>")
        T.expect(ent.contains("a & b <c> \"d\""), "decodes entities")
    }

    T.group("DocumentText: PDF body extraction") {
        T.expect(DocumentText.canExtract("pdf"), "pdf is an extractable kind")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anf-doc-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        guard writeTestPDF(to: url, text: "anf 검색 테스트 hello PDF") else {
            T.expect(false, "test PDF written"); return
        }
        let body = DocumentText.extract(url)
        T.expect(body?.contains("hello PDF") == true, "extracts latin text from the PDF")
        T.expect(body?.contains("검색 테스트") == true, "extracts Korean text from the PDF")

        // Cache: hit returns the same body; rewriting the file (new mtime)
        // invalidates and re-extracts.
        T.expect(DocumentTextCache.shared.text(for: url)?.contains("hello PDF") == true,
                 "cache returns the extracted body")
        _ = writeTestPDF(to: url, text: "second version 두번째")
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        T.expect(DocumentTextCache.shared.text(for: url)?.contains("두번째") == true,
                 "mtime change invalidates the cached body")
    }
}

/// Draws one page of text into a real PDF via Core Graphics + Core Text.
private func writeTestPDF(to url: URL, text: String) -> Bool {
    var box = CGRect(x: 0, y: 0, width: 400, height: 200)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
    ctx.beginPDFPage(nil)
    let attr = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 16),
    ])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.textPosition = CGPoint(x: 20, y: 100)
    CTLineDraw(line, ctx)
    ctx.endPDFPage()
    ctx.closePDF()
    return true
}
