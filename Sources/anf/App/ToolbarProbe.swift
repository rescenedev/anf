import AppKit
import SwiftUI

/// Sweeps the window across its whole width range and reports, at each step,
/// whether the custom toolbar clusters actually made it into the window.
///
/// Written for #93: when both clusters don't fit, AppKit doesn't overflow them —
/// it silently drops one. The delegate still runs and a frame is still computed,
/// but `view.window` stays nil and the user just sees an empty toolbar half, with
/// no way back short of widening the window. Run with `ANF_TOOLBAR_PROBE=1 anf`;
/// exits non-zero if a cluster vanishes at any width the window can actually be.
@MainActor
enum ToolbarProbe {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["ANF_TOOLBAR_PROBE"] != nil
    }

    /// The window's own `minSize.width` — the narrowest the user can get.
    private static let minWidth: CGFloat = 720
    private static let maxWidth: CGFloat = 1500
    private static let step: CGFloat = 30

    static func run(window: NSWindow, workspace: WorkspaceModel) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            measureDensities(workspace: workspace)

            var failures: [String] = []
            // Both pane layouts: a split one adds the "save workspace" button, so
            // it's the wider — and more easily dropped — trailing cluster.
            for layout in [PaneLayout.single, .dual] {
                workspace.setLayout(layout)
                // Widen the sidebar to its maximum for the second pass: it eats
                // into the same titlebar the clusters share, so a fat sidebar on a
                // narrow window is the tightest the toolbar ever gets.
                if layout == .dual, let split = window.anfSplitViewController?.splitView {
                    split.setPosition(340, ofDividerAt: 0)
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                let down = Array(stride(from: maxWidth, through: minWidth, by: -step))
                // Shrinking is what drops a cluster; growing is what proves it
                // comes back. Sweep both ways.
                for width in down + down.reversed() {
                    if let bad = await check(window: window, width: width, layout: layout) {
                        failures.append(bad)
                    }
                }
            }

            if failures.isEmpty {
                print("TOOLBARPROBE ok — clusters stayed attached \(Int(minWidth))–\(Int(maxWidth))px, both layouts")
            } else {
                print("TOOLBARPROBE FAIL — dropped at \(failures.joined(separator: ", "))")
            }
            exit(failures.isEmpty ? 0 : 1)
        }
    }

    /// Resizes to `width` and returns a failure label if a cluster came unstuck.
    private static func check(window: NSWindow, width: CGFloat, layout: PaneLayout) async -> String? {
        var frame = window.frame
        frame.size.width = width
        // A programmatic setFrame skips windowWillResize, so stand in for it:
        // the app's real resize path shrinks the clusters before AppKit lays out.
        WindowRegistry.controllers.first { $0.window === window }?.syncToolbarWidth(width: width)
        window.setFrame(frame, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // The toolbar re-lays out on the next runloop turn, not inside setFrame —
        // measure after it has actually settled.
        try? await Task.sleep(nanoseconds: 80_000_000)

        let items = window.toolbar?.items ?? []
        let dropped = items.contains { $0.view != nil && $0.view?.window == nil }
        let report = items.filter { $0.view != nil }.map { describe($0) }.joined(separator: " ")
        let sidebar = window.anfSplitViewController?.splitViewItems.first?
            .viewController.view.frame.width ?? -1
        print("TOOLBARPROBE \(layout) width=\(Int(width)) sidebar=\(Int(sidebar)) \(report)"
              + (dropped ? " DROPPED" : ""))
        return dropped ? "\(layout)@\(Int(width))px" : nil
    }

    /// Renders each cluster at each density off-screen and prints the real fitting
    /// width next to the hand-computed estimate in `ToolbarWidths`. The estimates
    /// only have to be *not too small*; this is how you check that.
    private static func measureDensities(workspace: WorkspaceModel) {
        for density in ToolbarDensity.allCases {
            let lead = NSHostingView(rootView: ToolbarLeadingView(workspace: workspace, density: density))
            let trail = NSHostingView(rootView: ToolbarTrailingView(workspace: workspace, density: density))
            print(String(format: "TOOLBARPROBE density=%@ leading=%.0f(est %.0f) trailing=%.0f(est %.0f)",
                         density.rawValue,
                         lead.fittingSize.width, ToolbarWidths.leading(density),
                         trail.fittingSize.width, ToolbarWidths.trailing(density)))
        }
    }

    private static func describe(_ item: NSToolbarItem) -> String {
        guard let view = item.view else { return "" }
        let id = item.itemIdentifier.rawValue
        return String(format: "%@=%@(w=%.0f,fit=%.0f)", id, view.window != nil ? "on" : "OFF",
                      view.frame.width, view.fittingSize.width)
    }
}
