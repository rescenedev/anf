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
}
