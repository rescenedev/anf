import AppKit
import SwiftUI

/// The window's NSToolbar. With a `.sidebarTrackingSeparator`, the control groups
/// land over the *content* (right of the sidebar divider) while the system sidebar
/// toggle stays over the sidebar — exactly how Finder lays its toolbar out. Pairs
/// with the `NSSplitViewController` sidebar so resize / traffic-lights / full-height
/// glass are all handled natively.
@MainActor
final class WindowToolbarController: NSObject, NSToolbarDelegate {
    private let workspace: WorkspaceModel
    private let metrics = ToolbarMetrics()
    /// The two cluster hosting views, so a width change can be flushed into them
    /// synchronously — see `updateAvailableWidth`.
    private var clusters: [NSView] = []

    static let leading = NSToolbarItem.Identifier("anf.leading")
    static let trailing = NSToolbarItem.Identifier("anf.trailing")

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        super.init()
    }

    /// Titlebar the clusters can't reach: window insets, and the sidebar section
    /// that holds the sidebar toggle. Measured with ANF_TOOLBAR_PROBE; sizing it
    /// too tight leaves a cluster dropped at the exact width where the density
    /// steps down, so it deliberately errs wide.
    nonisolated private static let chrome: CGFloat = 48

    /// How wide the sidebar may get before it starves the toolbar. The sidebar
    /// shares the titlebar with the clusters, so on a narrow window a
    /// dragged-out sidebar leaves less room than even the narrowest density
    /// needs — and then AppKit drops a cluster again. The window clamps
    /// `maximumThickness` to this.
    nonisolated static func maxSidebarWidth(windowWidth: CGFloat) -> CGFloat {
        // A little slack on top: the width estimates are close, not exact.
        windowWidth - (ToolbarFit.ladder.last?.requiredWidth ?? 0) - chrome - 24
    }

    /// Feed the width the two clusters have to share. Call on every resize and
    /// whenever the sidebar changes width — if the clusters ask for more than
    /// this, AppKit drops one of them outright (#93).
    func updateAvailableWidth(windowWidth: CGFloat, sidebarWidth: CGFloat) {
        let available = max(0, windowWidth - sidebarWidth - Self.chrome)
        guard available != metrics.available else { return }
        metrics.available = available
        // Observation commits SwiftUI updates on the next runloop turn, but the
        // toolbar lays out during this one — one pass with the old, too-wide
        // cluster is all it takes for AppKit to drop it. Flush the re-render now
        // so the toolbar only ever sees a size that fits.
        for hosting in clusters {
            hosting.layoutSubtreeIfNeeded()
            hosting.invalidateIntrinsicContentSize()
        }
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "anf.main.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The flexible space before the sidebar toggle pushes it to the RIGHT
        // edge of the sidebar section (next to the tracking separator).
        [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator, Self.leading, .flexibleSpace, Self.trailing]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.leading:
            return host(identifier, AnyView(ToolbarLeadingCluster(workspace: workspace, metrics: metrics)))
        case Self.trailing:
            return host(identifier, AnyView(ToolbarTrailingCluster(workspace: workspace, metrics: metrics)))
        default:
            return nil   // system items (.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace)
        }
    }

    private func host(_ id: NSToolbarItem.Identifier, _ view: AnyView) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        // The cluster re-renders narrower as the window shrinks, so the item has
        // to be sized by the live intrinsic size rather than the frame it had at
        // insertion time.
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // Density changes commit on the next runloop turn, so a fast resize can
        // still hand AppKit one stale (too wide) pass. Let it squeeze the cluster
        // rather than drop it: a clipped frame recovers, a dropped item doesn't.
        hosting.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        item.view = hosting
        clusters.append(hosting)
        return item
    }
}

/// The width the two toolbar clusters have to share, and the density that fits
/// in it. Observable so the SwiftUI clusters re-render when the window resizes.
@MainActor
@Observable
final class ToolbarMetrics {
    /// Starts effectively unbounded so the first render is the full toolbar; the
    /// window feeds a real number as soon as it has laid out.
    var available: CGFloat = 10_000

    var fit: ToolbarFit { ToolbarFit.resolve(available: available) }
}

/// Thin wrappers so the density read happens inside a SwiftUI body — that's what
/// subscribes the cluster to `ToolbarMetrics`.
private struct ToolbarLeadingCluster: View {
    let workspace: WorkspaceModel
    let metrics: ToolbarMetrics

    var body: some View {
        ToolbarLeadingView(workspace: workspace, density: metrics.fit.leading)
    }
}

private struct ToolbarTrailingCluster: View {
    let workspace: WorkspaceModel
    let metrics: ToolbarMetrics

    var body: some View {
        ToolbarTrailingView(workspace: workspace, density: metrics.fit.trailing)
    }
}
