import AppKit
import SwiftUI

/// Detachable preview window (#103 follow-up, asked again on #104: "동영상만이
/// 아니라 인스펙터로 볼 때 팝업으로"). Hosts the same per-type preview switch as
/// the docked inspector in a floating, resizable panel that FOLLOWS the active
/// pane's selection — a second screen for the file under the cursor. The pin
/// button toggles always-on-top; the lock button freezes the popup on the
/// current file (선택을 따라가지 않음 — 음악을 틀어두고 다른 작업, #103);
/// ⎋ closes (EscPanel).
@MainActor
final class PreviewPopup: NSObject {
    private static var current: PreviewPopup?

    /// One popup at a time. Summoning it from the SAME workspace just brings it
    /// forward; from another window's workspace it re-binds (close + reopen) so
    /// the popup always follows the window that asked — the singleton silently
    /// staying glued to window A while the user hits F3 in window B was a
    /// multi-window bug the tests caught.
    static func show(workspace: WorkspaceModel) {
        if let p = current {
            if p.workspace === workspace {
                p.window.makeKeyAndOrderFront(nil)
                return
            }
            p.window.close()   // windowWillClose clears `current`
        }
        let p = PreviewPopup(workspace: workspace)
        current = p
        p.window.makeKeyAndOrderFront(nil)
    }

    static var isOpen: Bool { current != nil }

    /// The item the popup is currently rendering (test hook).
    var currentItemPath: String? {
        (state.locked ?? workspace.active.selectedItems.first)?.url.path
    }

    private let window: NSPanel
    private let workspace: WorkspaceModel
    let state = PreviewPopupState()
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
                                                                 panel: w, state: state))
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

/// The popup's lock: while `locked` is set the popup shows that file regardless
/// of the pane's selection, and 연속 재생 advances within `lockedQueue` — the
/// folder's audio files snapshotted at lock time, so navigating the browser to
/// another folder can't derail the music (#103: "음악을 틀어두고 다른 작업").
@MainActor
@Observable
final class PreviewPopupState {
    private(set) var locked: FileItem?
    @ObservationIgnored private(set) var lockedQueue: [FileItem] = []

    func toggleLock(current: FileItem?, folderItems: [FileItem]) {
        if locked == nil, let current {
            locked = current
            lockedQueue = folderItems.filter(AudioPreview.isAudio)
        } else {
            locked = nil
            lockedQueue = []
        }
    }

    /// Next track after `item` in the snapshot queue; advances the lock and
    /// returns it, or nil at the end (or when not locked).
    func advanceLocked(after item: FileItem) -> FileItem? {
        guard locked != nil,
              let i = lockedQueue.firstIndex(where: { $0.id == item.id }),
              i + 1 < lockedQueue.count else { return nil }
        locked = lockedQueue[i + 1]
        return locked
    }
}

/// Popup content: title row (filename + lock + float pin) above the shared
/// preview switch. Tracks the active pane's first selected item live — unless
/// locked, in which case it stays on the locked file.
private struct PreviewPopupView: View {
    @Bindable var workspace: WorkspaceModel
    let panel: NSPanel
    @Bindable var state: PreviewPopupState
    @State private var floating = true

    private var target: FileItem? { state.locked ?? workspace.active.selectedItems.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(target?.displayName ?? L("Select an item", "항목을 선택하세요"))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    state.toggleLock(current: workspace.active.selectedItems.first,
                                     folderItems: workspace.active.items)
                } label: {
                    Image(systemName: state.locked != nil ? "lock.fill" : "lock.open")
                        .font(.system(size: 11))
                        .foregroundStyle(state.locked != nil ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(target == nil)
                .help(L("Keep showing this file — don't follow the selection",
                        "이 파일 고정 — 선택을 따라가지 않음"))
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
                // The advance override exists only while LOCKED — an unlocked
                // popup keeps the default selection-driven 연속 재생.
                InspectorPreviewContent(target: target,
                                        model: workspace.active,
                                        workspace: workspace,
                                        audioAdvanceOverride: state.locked == nil ? nil : { finished in
                                            // Advance inside the snapshot queue;
                                            // the flag makes the NEXT preview
                                            // start playing on mount.
                                            if state.advanceLocked(after: finished) != nil {
                                                AudioPreviewEngine.autoplayNext = true
                                            }
                                        })
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
