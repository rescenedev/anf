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

    T.group("TextDecoding: detect CP949 / UTF-16 instead of UTF-8 mojibake") {
        let cp949 = String.Encoding(rawValue:
            CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        // UTF-8 round-trips.
        T.equal(TextDecoding.string(from: Data("한글 hello".utf8)), "한글 hello", "utf-8 decodes")
        // CP949 (Windows Korean) — the bug: decoded as UTF-8 it was all U+FFFD.
        if let d = "한글 문서".data(using: cp949) {
            T.expect(Array(d) != Array("한글 문서".utf8), "precondition: CP949 bytes ≠ UTF-8 bytes")
            T.equal(TextDecoding.string(from: d), "한글 문서", "CP949 detected, not mojibake")
        } else { T.expect(false, "CP949 encoding available") }
        // UTF-16 with BOM.
        if let d = "한글".data(using: .utf16) {
            T.equal(TextDecoding.string(from: d), "한글", "UTF-16 BOM detected")
        } else { T.expect(false, "UTF-16 encoding available") }
        // A valid UTF-8 buffer cut mid-codepoint (the 512KB preview cap) must stay
        // on the UTF-8 path, NOT get misrouted to CP949 and mangled.
        let full = Data("한글".utf8)                      // 6 bytes, 3 per char
        let cut = full.prefix(full.count - 1)            // drops 1 byte of '글'
        let decoded = TextDecoding.string(from: cut)
        T.equal(decoded, "한", "truncated UTF-8 keeps the valid prefix, no replacement chars")
        T.expect(!decoded.contains("\u{FFFD}"), "no U+FFFD from a mid-codepoint cut")
    }

    T.group("DocumentText.extractXLSX: cells in row order, shared + numeric + inline") {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("anfxlsx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try? fm.createDirectory(at: dir.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)
        let shared = """
        <?xml version="1.0"?><sst xmlns="x">\
        <si><t>Name</t></si><si><t>나이</t></si><si><t>박성일</t></si>\
        </sst>
        """
        let sheet = """
        <?xml version="1.0"?><worksheet><sheetData>\
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>\
        <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>42</v></c>\
        <c r="C2" t="inlineStr"><is><t>메모</t></is></c></row>\
        </sheetData></worksheet>
        """
        try? shared.write(to: dir.appendingPathComponent("xl/sharedStrings.xml"), atomically: true, encoding: .utf8)
        try? sheet.write(to: dir.appendingPathComponent("xl/worksheets/sheet1.xml"), atomically: true, encoding: .utf8)
        let xlsx = dir.appendingPathComponent("book.xlsx")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-q", "-r", xlsx.path, "xl"]
        p.currentDirectoryURL = dir
        try? p.run(); p.waitUntilExit()

        guard let body = DocumentText.extractXLSX(xlsx) else {
            T.expect(false, "extractXLSX returned a body"); return
        }
        T.expect(body.contains("Name") && body.contains("나이") && body.contains("박성일"),
                 "shared strings resolved")
        T.expect(body.contains("42"), "numeric cell shown (old bug: dropped)")
        T.expect(body.contains("메모"), "inline-string cell shown (old bug: dropped)")
        T.expect(body.contains("Name\t나이"), "cells in row order, tab-separated (not glued)")
        T.expect(body.split(separator: "\n").count >= 2, "rows on separate lines, no run-on")
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
