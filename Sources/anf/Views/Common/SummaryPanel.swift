import AppKit
import SwiftUI

/// Floating panel that runs an on-device AI summary and shows the result with
/// large, selectable text. Used by the right-click menus (file "AI 요약" and the
/// folder "이 폴더 요약"), which — unlike the inspector — have no state-driven
/// card to render into. One panel per key (file/folder path); re-invoking
/// refocuses the existing one.
@MainActor
final class SummaryPanel: NSObject {
    private static var open: [String: SummaryPanel] = [:]

    /// Show a summary panel. `title` is the window title (file/folder name),
    /// `key` dedupes panels, `run` produces the summary off the main actor.
    static func show(title: String, key: String, run: @escaping () async -> String?) {
        if let existing = open[key] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let p = SummaryPanel(title: title, key: key, run: run)
        open[key] = p
        p.window.makeKeyAndOrderFront(nil)
        p.start()
    }

    private let key: String
    private let window: NSPanel
    private let run: () async -> String?
    private let state = SummaryPanelState()

    private init(title: String, key: String, run: @escaping () async -> String?) {
        self.key = key
        self.run = run
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        w.title = L("Summary — \(title)", "요약 — \(title)")
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false   // we own the lifetime (avoids double-free)
        w.minSize = NSSize(width: 320, height: 200)
        self.window = w
        super.init()
        w.center()
        w.contentView = NSHostingView(rootView: SummaryPanelView(state: state))
        w.delegate = self
    }

    private func start() {
        Task { [weak self] in
            guard let self else { return }
            let result = await run()
            state.loading = false
            state.text = result ?? L("Couldn’t summarize this.", "요약하지 못했습니다.")
        }
    }
}

extension SummaryPanel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        SummaryPanel.open.removeValue(forKey: key)
    }
}

/// Observable backing for the panel's SwiftUI body.
@MainActor
private final class SummaryPanelState: ObservableObject {
    @Published var loading = true
    @Published var text = ""
}

private struct SummaryPanelView: View {
    @ObservedObject var state: SummaryPanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text(L("On-device summary", "온디바이스 요약"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            Divider()
            if state.loading {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L("Summarizing on-device…", "온디바이스로 요약 중…"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(state.text)
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
