import Foundation
@testable import anf

/// Screenshot detection (name-prefix path, pure) + the collision-avoiding rename
/// used when moving captures into month folders. Previously untested.
func runScreenshotOrganizerTests() {
    T.group("isScreenshot — name-prefix path (no Spotlight)") {
        T.expect(ScreenshotTidy.isScreenshot(URL(fileURLWithPath: "/x/Screenshot 2026-06-14 at 10.00.00.png")),
                 "macOS default capture name")
        T.expect(ScreenshotTidy.isScreenshot(URL(fileURLWithPath: "/x/스크린샷 2026-06-14.png")),
                 "Korean capture name")
        T.expect(ScreenshotTidy.isScreenshot(URL(fileURLWithPath: "/x/CleanShot 2026.png")),
                 "CleanShot prefix")
        T.expect(!ScreenshotTidy.isScreenshot(URL(fileURLWithPath: "/x/report.pdf")),
                 "non-image is never a screenshot")
    }

    T.group("uniqueName appends a counter on collision") {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("anfshot-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        T.equal(ScreenshotOrganizer.uniqueName(in: dir, fileName: "a.png"), "a.png", "free name kept as-is")
        try? "x".write(to: dir.appendingPathComponent("a.png"), atomically: true, encoding: .utf8)
        T.equal(ScreenshotOrganizer.uniqueName(in: dir, fileName: "a.png"), "a 1.png", "collision → ' 1' before extension")
        try? "x".write(to: dir.appendingPathComponent("a 1.png"), atomically: true, encoding: .utf8)
        T.equal(ScreenshotOrganizer.uniqueName(in: dir, fileName: "a.png"), "a 2.png", "next free counter")
    }
}
