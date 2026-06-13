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
    /// `key` dedupes panels, `run` produces the summary (or a reason) off the
    /// main actor.
    static func show(title: String, key: String, run: @escaping () async -> String) {
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
    private let run: () async -> String
    private let state = SummaryPanelState()
    private var task: Task<Void, Never>?

    private init(title: String, key: String, run: @escaping () async -> String) {
        self.key = key
        self.run = run
        let w = EscPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
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
        task = Task { [weak self] in
            guard let self else { return }
            let result = await run()
            if Task.isCancelled { return }
            state.loading = false
            state.text = result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? L("No response from the model. If it's a local reasoning model, raise its output length, or try another model.",
                    "모델이 응답하지 않았어요. 로컬 추론(reasoning) 모델이면 출력 길이를 늘리거나 다른 모델을 시도하세요.")
                : result
        }
    }
}

extension SummaryPanel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        task?.cancel()          // closing aborts a slow request instead of orphaning it
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
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 16)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Summary", "요약"))
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(.secondary)
                    Text(LocalLLM.providerLabel)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            Divider()
            if state.loading {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.regular)
                    Text(L("Summarizing via \(LocalLLM.providerLabel)…", "\(LocalLLM.providerLabel) 로 요약 중…"))
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(state.text)
                        .font(.system(size: 20, weight: .regular))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(22)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
