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

        // No-extension files keep no extension.
        T.equal(SmartRename.sanitize("Makefile rules", ext: ""), "Makefile rules",
                "no extension stays bare")
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
