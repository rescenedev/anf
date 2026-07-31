import AppKit
import SwiftUI

/// Detachable preview window (#103 follow-up, asked again on #104: "동영상만이
/// 아니라 인스펙터로 볼 때 팝업으로"). Hosts the same per-type preview switch as
/// the docked inspector in a floating, resizable panel that FOLLOWS the active
/// pane's selection — a second screen for the file under the cursor. The pin
/// button toggles always-on-top; ⎋ closes (EscPanel).
@MainActor
final class PreviewPopup: NSObject {
    private static var current: PreviewPopup?

    /// One popup at a time: summoning it again just brings it forward (and it
    /// already tracks the selection, so there's nothing to re-point).
    static func show(workspace: WorkspaceModel) {
        if let p = current {
            p.window.makeKeyAndOrderFront(nil)
            return
        }
        let p = PreviewPopup(workspace: workspace)
        current = p
        p.window.makeKeyAndOrderFront(nil)
    }

    static var isOpen: Bool { current != nil }

    /// The item the popup is currently rendering (test hook).
    var currentItemPath: String? { workspace.active.selectedItems.first?.url.path }

    private let window: NSPanel
    private let workspace: WorkspaceModel
    static var currentForTesting: PreviewPopup? { current }

    private init(workspace: WorkspaceModel) {
        self.workspace = workspace
        let w = EscPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                         styleMask: [.titled, .closable, .resizable, .utilityWindow],
                         backing: .buffered, defer: false)
        w.title = L("Preview", "미리보기")
        w.isFloatingPanel = true               // always-on-top by default (the ask)
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 320, height: 300)
        self.window = w
        super.init()
        w.contentView = NSHostingView(rootView: PreviewPopupView(workspace: workspace,
                                                                 panel: w))
        w.center()
        w.delegate = self
    }
}

extension PreviewPopup: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if PreviewPopup.current?.window === (notification.object as? NSWindow) {
            PreviewPopup.current = nil
        }
    }
}

/// Popup content: title row (filename + float pin) above the shared preview
/// switch. Tracks the active pane's first selected item live.
private struct PreviewPopupView: View {
    @Bindable var workspace: WorkspaceModel
    let panel: NSPanel
    @State private var floating = true

    private var target: FileItem? { workspace.active.selectedItems.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(target?.displayName ?? L("Select an item", "항목을 선택하세요"))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    floating.toggle()
                    panel.isFloatingPanel = floating
                    panel.level = floating ? .floating : .normal
                } label: {
                    Image(systemName: floating ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundStyle(floating ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(L("Keep on top", "항상 위에 유지"))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            if let target {
                InspectorPreviewContent(target: target,
                                        model: workspace.active,
                                        workspace: workspace)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id("\(target.url.path)|\(target.isCloudPlaceholder)")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "eye").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(L("Select an item to preview", "미리볼 항목을 선택하세요"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.regularMaterial)
    }
}
