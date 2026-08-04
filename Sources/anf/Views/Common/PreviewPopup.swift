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
    private static var popups: [PreviewPopup] = []
    /// The selection-following popup (at most one); locked popups are
    /// independent viewers and never returned here unless nothing else exists.
    private static var current: PreviewPopup? {
        popups.last(where: { $0.state.locked == nil }) ?? popups.last
    }

    /// ONE selection-following popup at a time — summoning it from the SAME
    /// workspace brings it forward; from another window's workspace it re-binds
    /// (close + reopen) so it follows the window that asked. LOCKED popups are
    /// left alone and a fresh following popup opens beside them (#103: "음악을
    /// 플레이 해두고 다른 문서를 체크" — 잠근 뷰어는 독립 창).
    static func show(workspace: WorkspaceModel) {
        if let p = popups.last(where: { $0.state.locked == nil }) {
            if p.workspace === workspace {
                p.window.makeKeyAndOrderFront(nil)
                return
            }
            p.window.close()   // windowWillClose drops it from `popups`
        }
        let p = PreviewPopup(workspace: workspace)
        popups.append(p)
        p.window.makeKeyAndOrderFront(nil)
        // AFTER ordering front: the first display's layout pass rewrites any
        // frame set on the not-yet-shown panel (height snapped back to the
        // contentRect default — the #103 "크기 기억 안 됨" report).
        p.restoreSavedFrame()
        // A brand-new popup opening exactly over a locked one reads as "my
        // viewer got replaced" — offset it so both are visibly present.
        if popups.count > 1, let prev = popups.dropLast().last,
           abs(prev.window.frame.origin.x - p.window.frame.origin.x) < 8,
           abs(prev.window.frame.origin.y - p.window.frame.origin.y) < 8 {
            p.window.setFrameOrigin(NSPoint(x: p.window.frame.origin.x + 40,
                                            y: p.window.frame.origin.y - 40))
        }
    }

    static var isOpen: Bool { !popups.isEmpty }

    /// The item the popup is currently rendering (test hook).
    var currentItemPath: String? {
        (state.locked ?? workspace.active.selectedItems.first)?.url.path
    }

    private let window: NSPanel
    private let workspace: WorkspaceModel
    let state = PreviewPopupState()
    /// Content kind at summon time — the save-key fallback when the selection
    /// has drifted (or emptied) by the time the popup closes. Keying saves off
    /// the close-time selection alone silently dropped sizes (#103: mp3 세션
    /// 크기 저장 안 됨).
    private let openCategory: String
    static var currentForTesting: PreviewPopup? { current }
    static var openCountForTesting: Int { popups.count }
    var windowForTesting: NSWindow { window }

    fileprivate static func remove(windowed w: NSWindow) {
        popups.removeAll { $0.window === w }
    }

    private init(workspace: WorkspaceModel) {
        self.workspace = workspace
        openCategory = workspace.active.selectedItems.first
            .map(PreviewSizeClass.category) ?? "other"
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
        let host = NSHostingView(rootView: PreviewPopupView(workspace: workspace,
                                                            panel: w, state: state))
        // Never let SwiftUI dictate the panel's min/max: the default sizing
        // options clamp setFrame (breaking size restore, run-order dependent)
        // and stop the user shrinking the popup into a compact player. The
        // panel's own minSize is the only floor.
        host.sizingOptions = []
        w.contentView = host
        w.center()
        w.delegate = self
        // ⌘Q with the popup open never delivers windowWillClose to a panel —
        // that quietly lost the session's size (#103: 크기 기억 안 됨).
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification, object: nil)
    }

    @objc private func appWillTerminate() { saveFrame() }

    /// Remember the size PER CONTENT KIND (#103: 음악은 작게, 만화·문서는
    /// 크게) — the frame last used for this kind, else the last of ANY kind,
    /// else the default stays. Clamp instead of rejecting: a saved frame a
    /// point under minSize must not silently discard the whole restore.
    private func restoreSavedFrame() {
        let d = UserDefaults.standard
        guard let saved = d.string(forKey: "anf.previewPopup.frame.\(openCategory)")
                       ?? d.string(forKey: "anf.previewPopup.frame.last") else { return }
        var f = NSRectFromString(saved)
        guard f.width > 0, f.height > 0 else { return }
        f.size.width = max(f.width, window.minSize.width)
        f.size.height = max(f.height, window.minSize.height)
        window.setFrame(f, display: true)
    }

    fileprivate func saveFrame() {
        let cat = (state.locked ?? workspace.active.selectedItems.first)
            .map(PreviewSizeClass.category) ?? openCategory
        let d = UserDefaults.standard
        d.set(NSStringFromRect(window.frame), forKey: "anf.previewPopup.frame.\(cat)")
        d.set(NSStringFromRect(window.frame), forKey: "anf.previewPopup.frame.last")
    }
}

/// Broad content kinds the popup remembers a size for. Pure so the bucketing
/// is testable — the exact buckets matter less than their stability.
enum PreviewSizeClass {
    static func category(for item: FileItem) -> String {
        let e = item.ext
        if AudioPreview.isAudio(item) { return "audio" }
        if ["mp4", "mov", "mkv", "avi", "webm", "m4v", "wmv"].contains(e) { return "video" }
        if ["zip", "cbz", "cbr", "rar", "7z", "tar", "gz"].contains(e) { return "archive" }
        if OCRService.isImage(item.url) { return "image" }
        if ["pdf", "docx", "hwpx", "pptx", "xlsx", "md", "txt", "rtf", "epub"].contains(e) {
            return "document"
        }
        return "other"
    }
}

extension PreviewPopup: NSWindowDelegate {
    func windowDidEndLiveResize(_ notification: Notification) {
        saveFrame()
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        saveFrame()
        // Drop the hosting view NOW: a closed-but-retained panel keeps its
        // SwiftUI tree mounted, so onDisappear never fires and an AVPlayer in
        // the preview keeps playing after ⎋ (#103 follow-up: "esc로 뷰어를
        // 꺼도 음악재생이 멈추지 않아요").
        w.contentView = nil
        PreviewPopup.remove(windowed: w)
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
                // fixedSize: in a narrow popup the filename must truncate —
                // never these controls (#103: 잠금 표시가 안 보임).
                Button {
                    state.toggleLock(current: workspace.active.selectedItems.first,
                                     folderItems: workspace.active.items)
                } label: {
                    Image(systemName: state.locked != nil ? "lock.fill" : "lock.open")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(state.locked != nil ? Color.accentColor : Color.primary.opacity(0.55))
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .disabled(target == nil)
                .help(L("Keep showing this file — don't follow the selection",
                        "이 파일 고정 — 선택을 따라가지 않음"))
                Button {
                    floating.toggle()
                    panel.isFloatingPanel = floating
                    panel.level = floating ? .floating : .normal
                } label: {
                    Image(systemName: floating ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(floating ? Color.accentColor : Color.primary.opacity(0.55))
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .fixedSize()
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
                                        },
                                        mediaAutoplay: true)
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
