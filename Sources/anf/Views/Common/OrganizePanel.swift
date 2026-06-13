import AppKit
import SwiftUI

/// Reviews an AI "내용별 분류" run: classifies each file into a topic folder,
/// fills the list live (the on-device model is serial), lets the user uncheck
/// any file, then moves the checked ones into their category subfolders.
@MainActor
final class OrganizePanel: NSObject {
    private static var current: OrganizePanel?

    static func show(title: String, folder: URL, urls: [URL], onDone: @escaping () -> Void) {
        current?.window.close()
        let p = OrganizePanel(title: title, folder: folder, urls: urls, onDone: onDone)
        current = p
        p.window.makeKeyAndOrderFront(nil)
        p.state.start()
    }

    private let window: NSPanel
    private let state: OrganizeState

    private init(title: String, folder: URL, urls: [URL], onDone: @escaping () -> Void) {
        let st = OrganizeState(folder: folder, urls: urls, onDone: onDone)
        self.state = st
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        w.title = title
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 480, height: 300)
        self.window = w
        super.init()
        w.center()
        st.close = { [weak w] in w?.close() }
        w.contentView = NSHostingView(rootView: OrganizePanelView(state: st))
        w.delegate = self
    }
}

extension OrganizePanel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        state.cancel()
        if OrganizePanel.current?.window === (notification.object as? NSWindow) {
            OrganizePanel.current = nil
        }
    }
}

private struct OrganizeRow: Identifiable {
    let url: URL
    var id: URL { url }
    let original: String
    var category: String
    var enabled: Bool
    enum Phase { case working, ready, done, failed }
    var phase: Phase
}

@MainActor
private final class OrganizeState: ObservableObject {
    @Published var rows: [OrganizeRow]
    @Published var scanning = true
    private let folder: URL
    private let onDone: () -> Void
    private var task: Task<Void, Never>?
    var close: () -> Void = {}

    init(folder: URL, urls: [URL], onDone: @escaping () -> Void) {
        self.folder = folder
        self.onDone = onDone
        self.rows = urls.map {
            OrganizeRow(url: $0, original: $0.lastPathComponent, category: "", enabled: true, phase: .working)
        }
    }

    var readyCount: Int { rows.filter { $0.enabled && $0.phase == .ready }.count }

    func start() {
        task = Task {
            for i in rows.indices {
                if Task.isCancelled { return }
                let category = await ContentOrganizer.categorize(rows[i].url)
                if Task.isCancelled { return }
                rows[i].category = category
                rows[i].phase = .ready
            }
            scanning = false
        }
    }

    func cancel() { task?.cancel() }

    /// Move enabled, ready rows into their category folders, then reload.
    func apply() {
        var groups: [String: [URL]] = [:]
        for row in rows where row.enabled && row.phase == .ready {
            groups[row.category, default: []].append(row.url)
        }
        guard !groups.isEmpty else { return }
        let folder = self.folder
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                ContentOrganizer.move(groups: groups, into: folder)
            }.value
            for i in rows.indices where rows[i].enabled && rows[i].phase == .ready {
                rows[i].phase = .done
            }
            if result.moved > 0 { onDone() }
            close()
        }
    }
}

private struct OrganizePanelView: View {
    @ObservedObject var state: OrganizeState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").font(.system(size: 16)).foregroundStyle(.tint)
                Text(state.scanning
                     ? L("Classifying…", "분류 중…")
                     : L("\(state.rows.count) files · \(state.readyCount) to move",
                         "\(state.rows.count)개 파일 · \(state.readyCount)개 이동"))
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.secondary)
                if state.scanning { ProgressView().controlSize(.small).padding(.leading, 2) }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($state.rows) { $row in
                        OrganizeRowView(row: $row)
                        Divider()
                    }
                }
            }

            HStack {
                Spacer()
                Button(L("Cancel", "취소")) { state.close() }.controlSize(.large)
                Button(L("Move", "이동")) { state.apply() }
                    .controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled(state.readyCount == 0)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OrganizeRowView: View {
    @Binding var row: OrganizeRow

    var body: some View {
        HStack(spacing: 12) {
            switch row.phase {
            case .working: ProgressView().controlSize(.small).frame(width: 22)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 22)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: 22)
            case .ready: Toggle("", isOn: $row.enabled).labelsHidden().frame(width: 22)
            }
            Text(row.original)
                .font(.system(size: 14)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            if row.phase == .ready || row.phase == .done {
                Text(row.category)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.16), in: Capsule())
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
    }
}
