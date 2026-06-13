import AppKit
@testable import anf

/// Regression test for issue #12: the path bar (status bar) buttons were
/// silently eaten by WindowEdgeResizer's bottom resize zone. The path bar is
/// 26 pt tall and the bottom zone was 16 pt, so clicks at the vertical centre
/// of the bar (y≈13) were consumed before reaching the SwiftUI Button.
///
/// Fix: WindowEdgeResizer.reservedBottomHeight shifts the bottom and
/// corner-bottom zones upward, leaving the strip click-through.
func runPathBarNavTests() {
    MainActor.assumeIsolated {
        T.group("WindowEdgeResizer reserved bottom (path bar click fix)") {
            let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
            let r = WindowEdgeResizer(frame: bounds)

            // Without reserved height: bottom 16 px ARE in an edge zone.
            r.reservedBottomHeight = 0
            T.expect(r.inEdgeZone(at: NSPoint(x: 400, y: 13)),
                     "y=13 is in edge zone (no reservation)")

            // With path bar reserved (26 pt): the path bar strip is NOT a zone.
            r.reservedBottomHeight = 26
            T.expect(!r.inEdgeZone(at: NSPoint(x: 400, y: 13)),
                     "y=13 NOT in edge zone (path bar reserved)")
            T.expect(!r.inEdgeZone(at: NSPoint(x: 400, y: 0)),
                     "y=0 (very bottom) also not in edge zone")
            T.expect(!r.inEdgeZone(at: NSPoint(x: 400, y: 25)),
                     "y=25 (top of path bar) not in edge zone")

            // Just above the path bar: bottom edge zone starts at rb=26, spans +16=42.
            T.expect(r.inEdgeZone(at: NSPoint(x: 400, y: 34)),
                     "y=34 IS in edge zone (above path bar, within bottom band)")

            // Corner (bottom-left) zone is suppressed for y inside the reserved strip:
            // (x=10, y=10) is still caught by the LEFT-edge zone (x≤16 regardless of y),
            // but it is NOT caught by the bottom-left corner zone, so a point that is
            // only in the corner zone (x just outside the side-edge band) is not caught.
            T.expect(!r.inEdgeZone(at: NSPoint(x: 20, y: 10)),
                     "x=20 y=10 (above reserved, outside side band) not in edge zone")
            T.expect(r.inEdgeZone(at: NSPoint(x: 20, y: 30)),
                     "x=20 y=30 (bottom-left corner area, above reserved) IS in edge zone")

            // Reverting to zero restores the original behaviour.
            r.reservedBottomHeight = 0
            T.expect(r.inEdgeZone(at: NSPoint(x: 400, y: 13)),
                     "y=13 back in edge zone after reset")
        }

        T.group("BrowserModel.pathComponents navigability") {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let model = BrowserModel(start: home)
            let comps = model.pathComponents
            T.expect(comps.count >= 2, "at least 2 path components for home dir")
            // Every ancestor URL differs from current — clicking it calls navigate(to:)
            // which is not a no-op.
            let ancestors = comps.dropLast()
            T.expect(ancestors.allSatisfy { $0 != model.currentURL },
                     "all ancestor components differ from currentURL")
        }
    }
}
