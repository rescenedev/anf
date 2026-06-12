import Foundation
@testable import anf

/// hwpx structured preview: only hp:t body runs are collected, so click-here
/// form-field metadata ("Clickhere:set:…", "HelpState:wstring…") that polluted
/// the old tag-strip preview never appears; tables come through as tables.
func runHwpxStructureTests() {
    let xml = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section"
            xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph">
      <hp:p><hp:run><hp:ctrl><hp:fieldBegin type="CLICK_HERE">
        <hp:parameters count="2">
          <hp:stringParam name="Command">Clickhere:set:45:Direction:wstring:3:기관명</hp:stringParam>
          <hp:stringParam name="Help">HelpState:wstring:0:</hp:stringParam>
        </hp:parameters></hp:fieldBegin></hp:ctrl>
        <hp:t>금융위원회 공고 제2026-324호</hp:t></hp:run></hp:p>
      <hp:p><hp:run><hp:t>1. 개정이유</hp:t></hp:run></hp:p>
      <hp:tbl><hp:tr>
        <hp:tc><hp:subList><hp:p><hp:run><hp:t>구분</hp:t></hp:run></hp:p></hp:subList></hp:tc>
        <hp:tc><hp:subList><hp:p><hp:run><hp:t>내용</hp:t></hp:run></hp:p></hp:subList></hp:tc>
      </hp:tr></hp:tbl>
      <hp:p><hp:run><hp:t>Clickhere:set:46:Direction:wstring:4:공고연도</hp:t></hp:run></hp:p>
    </hs:sec>
    """

    T.group("HwpxStructure: body text only, field junk gone") {
        let blocks = HwpxStructure.parse(sectionXML: Data(xml.utf8))
        T.equal(blocks.count, 3, "three blocks (got \(blocks.count))")
        if case .paragraph(let runs) = blocks[0] {
            T.equal(runs.first?.text, "금융위원회 공고 제2026-324호",
                    "body text survives, parameter junk doesn't")
        } else { T.expect(false, "block 0 is a paragraph") }
        if case .table(let rows) = blocks[2] {
            T.equal(rows, [["구분", "내용"]], "table rows/cells")
        } else { T.expect(false, "block 2 is a table") }
        let all = blocks.compactMap { block -> String? in
            if case .paragraph(let runs) = block { return runs.map(\.text).joined() }
            return nil
        }.joined()
        T.expect(!all.contains("Clickhere"), "no Clickhere anywhere (even inside hp:t)")
        T.expect(!all.contains("HelpState"), "no HelpState anywhere")
    }
}
