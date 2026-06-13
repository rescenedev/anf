import AppKit
import SwiftUI

/// Reviews an AI auto-tag run: suggests topic tags per file (filling the list
/// live — the on-device model is serial), lets the user uncheck any file, then
/// writes the tags as Finder tags (merging, never clobbering colour labels).
@MainActor
final class TagPanel: NSObject {
    private static var current: TagPanel?

    static func show(title: String, urls: [URL], onDone: @escaping () -> Void) {
        current?.window.close()
        let p = TagPanel(title: title, urls: urls, onDone: onDone)
        current = p
        p.window.makeKeyAndOrderFront(nil)
        p.state.start()
    }

    private let window: NSPanel
    private let state: TagState

    private init(title: String, urls: [URL], onDone: @escaping () -> Void) {
        let st = TagState(urls: urls, onDone: onDone)
        self.state = st
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        w.title = title
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 460, height: 300)
        self.window = w
        super.init()
        w.center()
        st.close = { [weak w] in w?.close() }
        w.contentView = NSHostingView(rootView: TagPanelView(state: st))
        w.delegate = self
    }
}

extension TagPanel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        state.cancel()
        if TagPanel.current?.window === (notification.object as? NSWindow) {
            TagPanel.current = nil
        }
    }
}

private struct TagRow: Identifiable {
    let url: URL
    var id: URL { url }
    let original: String
    var tags: [String]
    var enabled: Bool
    enum Phase { case working, ready, none, done }
    var phase: Phase
}

@MainActor
private final class TagState: ObservableObject {
    @Published var rows: [TagRow]
    @Published var scanning = true
    private let onDone: () -> Void
    private var task: Task<Void, Never>?
    var close: () -> Void = {}

    init(urls: [URL], onDone: @escaping () -> Void) {
        self.onDone = onDone
        self.rows = urls.map {
            TagRow(url: $0, original: $0.lastPathComponent, tags: [], enabled: true, phase: .working)
        }
    }

    var readyCount: Int { rows.filter { $0.enabled && $0.phase == .ready }.count }

    func start() {
        task = Task {
            for i in rows.indices {
                if Task.isCancelled { return }
                let tags = await TagService.suggest(for: rows[i].url)
                if Task.isCancelled { return }
                rows[i].tags = tags
                rows[i].enabled = !tags.isEmpty
                rows[i].phase = tags.isEmpty ? .none : .ready
            }
            scanning = false
        }
    }

    func cancel() { task?.cancel() }

    func apply() {
        var applied: [URL] = []
        for i in rows.indices where rows[i].enabled && rows[i].phase == .ready {
            TagService.apply(rows[i].tags, to: rows[i].url)
            rows[i].phase = .done
            applied.append(rows[i].url)
        }
        if !applied.isEmpty {
            FileTags.reindex(applied)   // make Finder/Spotlight pick the tags up now
            onDone()
        }
        if !rows.contains(where: { $0.enabled && $0.phase == .ready }) { close() }
    }
}

private struct TagPanelView: View {
    @ObservedObject var state: TagState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tag").font(.system(size: 16)).foregroundStyle(.tint)
                Text(state.scanning
                     ? L("Suggesting tags…", "태그 제안 중…")
                     : L("\(state.rows.count) files · \(state.readyCount) to tag",
                         "\(state.rows.count)개 파일 · \(state.readyCount)개 태그"))
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.secondary)
                if state.scanning { ProgressView().controlSize(.small).padding(.leading, 2) }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($state.rows) { $row in
                        TagRowView(row: $row)
                        Divider()
                    }
                }
            }

            HStack {
                Spacer()
                Button(L("Cancel", "취소")) { state.close() }.controlSize(.large)
                Button(L("Apply Tags", "태그 적용")) { state.apply() }
                    .controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled(state.readyCount == 0)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TagRowView: View {
    @Binding var row: TagRow

    var body: some View {
        HStack(spacing: 12) {
            switch row.phase {
            case .working: ProgressView().controlSize(.small).frame(width: 22)
            case .none: Image(systemName: "minus.circle").foregroundStyle(.tertiary).frame(width: 22)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 22)
            case .ready: Toggle("", isOn: $row.enabled).labelsHidden().frame(width: 22)
            }
            Text(row.original)
                .font(.system(size: 14)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
            Spacer(minLength: 8)
            if row.phase == .ready || row.phase == .done {
                HStack(spacing: 6) {
                    ForEach(row.tags, id: \.self) { t in
                        Text(t)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.16), in: Capsule())
                    }
                }
            } else if row.phase == .none {
                Text(L("no tags", "태그 없음")).font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
    }
}
