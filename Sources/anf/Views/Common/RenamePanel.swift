import AppKit
import SwiftUI

/// Floating panel that proposes AI filenames for a set of files and lets the
/// user review, edit, and apply them in one go. Drives both the single-file
/// "AI 이름 제안" menu item and the batch "스크린샷 정리". Renaming happens
/// here (collision-safe) and reloads the browser.
@MainActor
final class RenamePanel: NSObject {
    private static var current: RenamePanel?

    /// Show the panel for `urls`. `title` is the window title; `onDone` reloads
    /// the browser after renames land.
    static func show(title: String, urls: [URL], onDone: @escaping () -> Void) {
        current?.window.close()
        let p = RenamePanel(title: title, urls: urls, onDone: onDone)
        current = p
        p.window.makeKeyAndOrderFront(nil)
        p.state.start()
    }

    private let window: NSPanel
    private let state: RenameState

    private init(title: String, urls: [URL], onDone: @escaping () -> Void) {
        let st = RenameState(urls: urls, onDone: onDone)
        self.state = st
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        w.title = title
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 460, height: 280)
        self.window = w
        super.init()
        w.center()
        st.close = { [weak w] in w?.close() }
        w.contentView = NSHostingView(rootView: RenamePanelView(state: st))
        w.delegate = self
    }
}

extension RenamePanel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if RenamePanel.current?.window === (notification.object as? NSWindow) {
            RenamePanel.current = nil
        }
    }
}

/// One file's row: original name → AI proposal (editable), with a checkbox.
private struct RenameRow: Identifiable {
    let url: URL
    var id: URL { url }
    let original: String
    var proposed: String
    var enabled: Bool
    enum Phase { case working, ready, none, done, failed }
    var phase: Phase
}

@MainActor
private final class RenameState: ObservableObject {
    @Published var rows: [RenameRow]
    @Published var scanning = true
    let onDone: () -> Void
    var close: () -> Void = {}

    init(urls: [URL], onDone: @escaping () -> Void) {
        self.onDone = onDone
        self.rows = urls.map {
            RenameRow(url: $0, original: $0.lastPathComponent, proposed: "", enabled: true, phase: .working)
        }
    }

    var readyCount: Int { rows.filter { $0.enabled && $0.phase == .ready }.count }

    /// Propose names one at a time (the on-device LLM is serial anyway) so the
    /// list fills progressively.
    func start() {
        Task {
            for i in rows.indices {
                let url = rows[i].url
                let suggestion = await SmartRename.suggest(for: url)
                if let suggestion, suggestion != rows[i].original {
                    rows[i].proposed = suggestion
                    rows[i].phase = .ready
                } else {
                    rows[i].proposed = rows[i].original
                    rows[i].enabled = false
                    rows[i].phase = .none
                }
            }
            scanning = false
        }
    }

    /// Apply every enabled, ready row — collision-safe — then reload.
    func apply() {
        var changed = false
        for i in rows.indices where rows[i].enabled && rows[i].phase == .ready {
            let row = rows[i]
            let dir = row.url.deletingLastPathComponent()
            let wanted = row.proposed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wanted.isEmpty, wanted != row.original else { rows[i].phase = .none; continue }
            let finalName = Self.uniqueName(in: dir, fileName: wanted, excluding: row.url)
            if FileOperations.rename(FileItem(url: row.url) ?? placeholder(row.url), to: finalName) != nil {
                rows[i].phase = .done
                changed = true
            } else {
                rows[i].phase = .failed
            }
        }
        if changed { onDone() }
        // Close once nothing actionable remains.
        if !rows.contains(where: { $0.enabled && $0.phase == .ready }) { close() }
    }

    /// FileItem(url:) can fail only if the file vanished mid-flight; rename then
    /// no-ops on the missing source. This keeps the type non-optional.
    private func placeholder(_ url: URL) -> FileItem {
        FileItem(url: url) ?? FileItem(fastURL: url)!
    }

    /// A non-colliding name in `dir` (appends " 2", " 3"…), ignoring the source.
    static func uniqueName(in dir: URL, fileName: String, excluding source: URL) -> String {
        let fm = FileManager.default
        let ns = fileName as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        func make(_ n: Int) -> String {
            let stem = n == 0 ? base : "\(base) \(n)"
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        var n = 0
        while true {
            let candidate = make(n)
            let dest = dir.appendingPathComponent(candidate)
            if !fm.fileExists(atPath: dest.path) || dest == source { return candidate }
            n += 1
        }
    }
}

private struct RenamePanelView: View {
    @ObservedObject var state: RenameState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 16)).foregroundStyle(.tint)
                Text(state.scanning
                     ? L("Proposing names…", "이름 짓는 중…")
                     : L("\(state.rows.count) files · \(state.readyCount) to rename",
                         "\(state.rows.count)개 파일 · \(state.readyCount)개 변경"))
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.secondary)
                if state.scanning { ProgressView().controlSize(.small).padding(.leading, 2) }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($state.rows) { $row in
                        RowView(row: $row)
                        Divider()
                    }
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button(L("Cancel", "취소")) { state.close() }
                    .controlSize(.large)
                Button(L("Rename", "이름 바꾸기")) { state.apply() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.readyCount == 0)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RowView: View {
    @Binding var row: RenameRow

    var body: some View {
        HStack(spacing: 12) {
            switch row.phase {
            case .working:
                ProgressView().controlSize(.small).frame(width: 22)
            case .none:
                Image(systemName: "minus.circle").foregroundStyle(.tertiary).frame(width: 22)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 22)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: 22)
            case .ready:
                Toggle("", isOn: $row.enabled).labelsHidden().frame(width: 22)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(row.original)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .strikethrough(row.phase == .ready || row.phase == .done)
                    .lineLimit(1).truncationMode(.middle)
                if row.phase == .ready {
                    TextField("", text: $row.proposed)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .medium))
                } else if row.phase == .done {
                    Text(row.proposed).font(.system(size: 16, weight: .medium)).foregroundStyle(.green)
                } else if row.phase == .none {
                    Text(L("no suggestion", "제안 없음")).font(.system(size: 13)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .opacity(row.phase == .none ? 0.55 : 1)
    }
}
