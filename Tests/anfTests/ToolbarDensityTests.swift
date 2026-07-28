import Foundation
@testable import anf

/// Issue #93: the two toolbar clusters are single custom `NSToolbarItem`s. When
/// their combined width doesn't fit, AppKit doesn't overflow them — it silently
/// drops one, leaving half the toolbar empty with no way back. So the clusters
/// must never *ask* for more than the window has, which is what `ToolbarFit`
/// decides. The end-to-end check is `ANF_TOOLBAR_PROBE=1 anf`; this covers the
/// arithmetic that harness depends on.
func runToolbarDensityTests() {
    T.group("toolbar density: ladder never widens as it degrades") {
        let ladder = ToolbarFit.ladder
        T.expect(ladder.count >= 2, "ladder has rungs to fall through")
        T.equal(ladder.first, ToolbarFit.widest, "first rung is the full toolbar")
        for (a, b) in zip(ladder, ladder.dropFirst()) {
            T.expect(b.requiredWidth < a.requiredWidth,
                     "rung \(b) must be narrower than \(a) — a wider fallback would never be reached")
        }
    }

    T.group("toolbar density: each rung's estimate covers its parts") {
        // The estimates only have to be *not too small* — under-estimating is what
        // brings the drop back. ANF_TOOLBAR_PROBE prints the rendered widths to
        // check them against.
        for density in ToolbarDensity.allCases {
            T.expect(ToolbarWidths.leading(density) > 0, "leading \(density) has a width")
            T.expect(ToolbarWidths.trailing(density) > 0, "trailing \(density) has a width")
        }
        T.expect(ToolbarWidths.leading(.full) > ToolbarWidths.leading(.compact),
                 "leading compact is narrower than full")
        T.expect(ToolbarWidths.leading(.compact) > ToolbarWidths.leading(.minimal),
                 "leading minimal is narrower than compact")
        T.expect(ToolbarWidths.trailing(.full) > ToolbarWidths.trailing(.compact),
                 "trailing compact is narrower than full")
        T.expect(ToolbarWidths.trailing(.compact) > ToolbarWidths.trailing(.minimal),
                 "trailing minimal is narrower than compact")
    }

    T.group("toolbar density: resolve picks the densest rung that fits") {
        let ladder = ToolbarFit.ladder
        for rung in ladder {
            T.equal(ToolbarFit.resolve(available: rung.requiredWidth), rung,
                    "exactly enough room for \(rung) picks it")
        }
        // A hair under a rung falls to the next one down, never up.
        for (a, b) in zip(ladder, ladder.dropFirst()) {
            T.equal(ToolbarFit.resolve(available: a.requiredWidth - 1), b,
                    "one point short of \(a) degrades to \(b)")
        }
        T.equal(ToolbarFit.resolve(available: 10_000), ToolbarFit.widest,
                "a wide window gets the full toolbar")
    }

    T.group("toolbar density: never gives up entirely") {
        // Nothing is ever better than an empty toolbar half, so the narrowest rung
        // is the answer even when it doesn't fit either.
        let narrowest = ToolbarFit.ladder[ToolbarFit.ladder.count - 1]
        T.equal(ToolbarFit.resolve(available: 0), narrowest, "zero width still renders something")
        T.equal(ToolbarFit.resolve(available: -100), narrowest, "negative width doesn't crash out")
    }

    T.group("toolbar density: sidebar cap leaves room for the narrowest toolbar") {
        // The sidebar shares the titlebar with the clusters. At the window's own
        // minimum width the cap has to still be a usable sidebar, or the clamp
        // just moves the problem into the sidebar.
        let narrowest = ToolbarFit.ladder[ToolbarFit.ladder.count - 1].requiredWidth
        for windowWidth in stride(from: CGFloat(720), through: 2000, by: 40) {
            let cap = WindowToolbarController.maxSidebarWidth(windowWidth: windowWidth)
            T.expect(windowWidth - cap >= narrowest,
                     "at \(Int(windowWidth))px the cap (\(Int(cap))px) leaves room for the narrowest toolbar")
        }
        T.expect(WindowToolbarController.maxSidebarWidth(windowWidth: 720)
                 >= AnfWindowController.sidebarMinThickness,
                 "at the window's minimum width the sidebar can still be its minimum thickness")
        T.expect(WindowToolbarController.maxSidebarWidth(windowWidth: 1400)
                 >= AnfWindowController.sidebarMaxThickness,
                 "a roomy window doesn't clamp the sidebar at all")
    }
}
