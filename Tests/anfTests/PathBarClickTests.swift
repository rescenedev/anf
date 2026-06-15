import AppKit
@testable import anf

/// Regression guard for issue #12 "상태바를 눌러도 폴더 이동이 안 됨": the window
/// edge-resizer overlay must NOT swallow clicks in the bottom path-bar strip.
/// The path bar is 26 pt tall with its breadcrumbs vertically centred (~y=13),
/// and the resizer's bottom band is only `bottomEdgeMargin` (6 pt) — so the
/// breadcrumbs stay clickable while the very bottom edge still resizes.
///
/// (PR #13 proposed a different fix — reservedBottomHeight — but main already
/// solved this with the tight 6 pt band in c462a0a; #13 was closed. This test
/// pins down that the fix is present and keeps working.)
func runPathBarClickTests() {
    MainActor.assumeIsolated {
        T.group("edge-resizer leaves the path-bar strip clickable") {
            let r = WindowEdgeResizer(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            // AppKit (non-flipped) coords: y=0 is the window bottom, where the
            // 26 pt path bar lives. Breadcrumbs sit at its vertical centre.
            let centerX: CGFloat = 400

            T.expect(!r.isResizeZoneForTest(at: NSPoint(x: centerX, y: 13)),
                     "breadcrumb centre (y=13) is NOT a resize zone → click reaches the path bar")
            T.expect(!r.isResizeZoneForTest(at: NSPoint(x: centerX, y: 25)),
                     "top of the path bar (y=25) is clickable")
            T.expect(!r.isResizeZoneForTest(at: NSPoint(x: centerX, y: 7)),
                     "just above the 6 pt band (y=7) is clickable")

            // The very bottom edge still resizes (we didn't disable it wholesale).
            T.expect(r.isResizeZoneForTest(at: NSPoint(x: centerX, y: 3)),
                     "bottom 6 pt (y=3) still resizes the window")
            // Side edges unaffected.
            T.expect(r.isResizeZoneForTest(at: NSPoint(x: 1, y: 300)),
                     "left edge still resizes")
        }

        T.group("breadcrumb components are navigable targets") {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let model = BrowserModel(start: home)
            let comps = model.pathComponents
            T.expect(comps.count >= 2, "home dir yields at least 2 breadcrumb components")
            // Every ancestor URL differs from current, so clicking it is a real
            // navigate(to:) — not a silent no-op (the N-004 fix).
            T.expect(comps.dropLast().allSatisfy { $0 != model.currentURL },
                     "each ancestor crumb differs from the current folder")
        }
    }
}
