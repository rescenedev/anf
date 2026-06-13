import Foundation
@testable import anf

/// Pure logic for the AI rename / screenshot-tidy features: filename
/// sanitization (the model's reply is untrusted) and screenshot detection by
/// name prefix. The LLM/Vision calls themselves are gated by availability and
/// exercised by LLMTests/OCRTests.
func runRenameTests() {
    T.group("SmartRename.sanitize cleans the model's reply") {
        // Keeps the original extension, drops a duplicated one.
        T.equal(SmartRename.sanitize("Quarterly Revenue Report", ext: "pdf"),
                "Quarterly Revenue Report.pdf", "appends original extension")
        T.equal(SmartRename.sanitize("report.pdf", ext: "pdf"), "report.pdf",
                "doesn't double the extension")

        // Strips quotes the model loves to wrap names in.
        T.equal(SmartRename.sanitize("\"Login Screen Error\"", ext: "png"),
                "Login Screen Error.png", "strips surrounding quotes")
        T.equal(SmartRename.sanitize("“계약서 초안”", ext: "docx"),
                "계약서 초안.docx", "strips smart quotes")

        // First line only; illegal chars replaced.
        T.equal(SmartRename.sanitize("Budget 2026\nextra commentary", ext: "xlsx"),
                "Budget 2026.xlsx", "takes the first line")
        T.equal(SmartRename.sanitize("a/b:c", ext: "txt"), "a-b-c.txt",
                "replaces / and : (HFS-illegal)")

        // Leading dots can't make a hidden file; empty → nil.
        T.equal(SmartRename.sanitize("...hidden", ext: "txt"), "hidden.txt",
                "trims leading dots")
        T.expect(SmartRename.sanitize("   ", ext: "png") == nil, "blank reply → nil")

        // Strips ANY trailing known extension, not just the original — kills
        // the doubled ".jpg.png" the model used to produce.
        T.equal(SmartRename.sanitize("Screenshot_20260622_105701.jpg", ext: "png"),
                "Screenshot_20260622_105701.png", "drops a foreign extension before reattaching")

        // No-extension files keep no extension.
        T.equal(SmartRename.sanitize("Makefile rules", ext: ""), "Makefile rules",
                "no extension stays bare")
    }

    T.group("SmartRename.isLazy rejects junk names") {
        T.expect(SmartRename.isLazy("Screenshot_2026.png", ext: "png"),
                 "generic 'screenshot' name is lazy")
        T.expect(SmartRename.isLazy("이미지 1.png", ext: "png"),
                 "Korean generic '이미지' is lazy")
        T.expect(SmartRename.isLazy("2026-06-13.png", ext: "png"),
                 "a bare date has no letters → lazy")
        T.expect(!SmartRename.isLazy("Stripe Payments Dashboard.png", ext: "png"),
                 "a real content name is kept")
        T.expect(!SmartRename.isLazy("결제 대시보드 현황.png", ext: "png"),
                 "a real Korean content name is kept")
    }

    T.group("FolderOrganizer buckets files by kind") {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("anforg-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for n in ["a.png", "b.jpg", "c.pdf", "d.docx", "e.zip", "f.swift", "g.unknownext"] {
            fm.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data("x".utf8))
        }
        try? fm.createDirectory(at: dir.appendingPathComponent("subfolder"), withIntermediateDirectories: true)

        let plan = FolderOrganizer.plan(in: dir, korean: false)
        let byFolder = Dictionary(uniqueKeysWithValues: plan.groups.map { ($0.folder, $0.urls.count) })
        T.equal(byFolder["Images"], 2, "png+jpg → Images")
        T.equal(byFolder["PDF"], 1, "pdf → PDF")
        T.equal(byFolder["Documents"], 1, "docx → Documents")
        T.equal(byFolder["Archives"], 1, "zip → Archives")
        T.equal(byFolder["Code"], 1, "swift → Code")
        T.expect(plan.groups.allSatisfy { $0.folder != "subfolder" }, "folders are left alone")
        T.equal(plan.total, 6, "unknown extension is not moved")
    }

    T.group("TagService.parse cleans the model's tag reply") {
        T.equal(TagService.parse("invoice, finance, 2026"), ["invoice", "finance", "2026"],
                "comma-separated tags")
        T.equal(TagService.parse("#계약서\n법무\n#계약서"), ["계약서", "법무"],
                "strips #, splits newlines, dedupes")
        T.equal(TagService.parse("invoice, document, image, taxes").count, 2,
                "drops generic words (document/image), keeps invoice+taxes")
        T.equal(TagService.parse("a, b, c, d, e").count, 3, "capped at maxTags (3)")
        T.expect(TagService.parse("   ").isEmpty, "blank → no tags")
        T.expect(TagService.parse("ThisTagIsWayTooLongToBeUsefulAsATag").isEmpty,
                 "over-long single token dropped")
    }

    T.group("ContentOrganizer matches model replies to the taxonomy") {
        let opts = ["Receipts & Invoices", "Reports", "Other"]
        T.equal(ContentOrganizer.match("Reports", in: opts), "Reports", "exact match")
        T.equal(ContentOrganizer.match("reports", in: opts), "Reports", "case-insensitive")
        T.equal(ContentOrganizer.match("This is a Report document", in: opts), nil,
                "reply containing none of the option strings → nil")
        T.equal(ContentOrganizer.match("Receipts", in: opts), "Receipts & Invoices",
                "option contains the reply")
        T.equal(ContentOrganizer.match("", in: opts), nil, "empty reply → nil")
    }

    T.group("ScreenshotTidy detects capture names") {
        let dir = FileManager.default.temporaryDirectory
        func u(_ n: String) -> URL { dir.appendingPathComponent(n) }
        // Name-prefix fallback (these files don't exist, so the Spotlight flag
        // is nil and detection falls back to the name — and the extension must
        // be an image).
        T.expect(ScreenshotTidy.isScreenshot(u("Screenshot 2026-06-13 at 10.30.00.png")),
                 "English screenshot name")
        T.expect(ScreenshotTidy.isScreenshot(u("스크린샷 2026-06-13 오전 10.30.00.png")),
                 "Korean screenshot name")
        T.expect(ScreenshotTidy.isScreenshot(u("CleanShot 2026-06-13.png")),
                 "CleanShot name")
        T.expect(!ScreenshotTidy.isScreenshot(u("vacation.png")),
                 "ordinary image is not a screenshot")
        T.expect(!ScreenshotTidy.isScreenshot(u("Screenshot notes.txt")),
                 "non-image is never a screenshot")
    }
}
