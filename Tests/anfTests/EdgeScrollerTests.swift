import AppKit
@testable import anf

/// Regression guard for issue #87 "스크롤바를 클릭할 수 없어요": the 16 pt
/// right edge-resize band fully covers a legacy (always-visible, ~15 pt)
/// scroll bar flush against the window edge, so the overlay used to swallow
/// the scrollbar's hover (resize cursor) and clicks. A visible scroller under
/// the pointer must win — except the outermost `scrollerGrip` points, which
/// keep resizing like the native band does over a scroller.
func runEdgeScrollerTests() {
    MainActor.assumeIsolated {
        T.group("edge-resizer yields to a visible scrollbar (#87)") {
            let r = WindowEdgeResizer(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            // Simulate a legacy vertical scroller: the right 15 pt strip of the
            // content area, between toolbar (top) and path bar (bottom).
            r.scrollerProbeForTest = { p in p.x >= 785 && p.y > 30 && p.y < 570 }

            T.expect(!r.wouldConsumeForTest(at: NSPoint(x: 790, y: 300)),
                     "click over the scrollbar (x=790) passes through to it")
            T.expect(!r.wouldConsumeForTest(at: NSPoint(x: 796, y: 300)),
                     "scrollbar interior just inside the grip strip stays clickable")
            T.expect(r.wouldConsumeForTest(at: NSPoint(x: 798, y: 300)),
                     "outermost 3 pt still resizes even over the scrollbar")
            T.expect(r.wouldConsumeForTest(at: NSPoint(x: 790, y: 10)),
                     "right edge below the scroller strip still resizes")
            T.expect(r.wouldConsumeForTest(at: NSPoint(x: 1, y: 300)),
                     "left edge (no scroller) unaffected")
        }

        T.group("no scroller → band behaves exactly as before") {
            let r = WindowEdgeResizer(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            r.scrollerProbeForTest = { _ in false }
            T.expect(r.wouldConsumeForTest(at: NSPoint(x: 790, y: 300)),
                     "right band consumes when nothing scrollable is under it")
        }
    }
}
