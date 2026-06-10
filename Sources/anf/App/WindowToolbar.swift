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

    private static let leading = NSToolbarItem.Identifier("anf.leading")
    private static let trailing = NSToolbarItem.Identifier("anf.trailing")

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        super.init()
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
            return host(identifier, AnyView(ToolbarLeadingView(workspace: workspace)))
        case Self.trailing:
            return host(identifier, AnyView(ToolbarTrailingView(workspace: workspace)))
        default:
            return nil   // system items (.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace)
        }
    }

    private func host(_ id: NSToolbarItem.Identifier, _ view: AnyView) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        item.view = hosting
        return item
    }
}
