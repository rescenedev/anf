import AppKit
import SwiftUI

/// "Ask this document / folder" — a chat-style panel for on-device Q&A. Loads the
/// context once (file body or folder excerpts), then answers each question
/// against it; follow-ups reuse the same context. If the context can't be read,
/// it explains why and disables input.
@MainActor
final class AskPanel: NSObject {
    private static var open: [String: AskPanel] = [:]

    static func show(title: String, key: String, url: URL, isFolder: Bool) {
        if let existing = open[key] { existing.window.makeKeyAndOrderFront(nil); return }
        let p = AskPanel(title: title, key: key, url: url, isFolder: isFolder)
        open[key] = p
        p.window.makeKeyAndOrderFront(nil)
        p.state.loadContext(url: url, isFolder: isFolder)
    }

    private let key: String
    private let window: NSPanel
    private let state = AskState()

    private init(title: String, key: String, url: URL, isFolder: Bool) {
        self.key = key
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        w.title = L("Ask — \(title)", "질문 — \(title)")
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 420, height: 320)
        self.window = w
        super.init()
        w.center()
        w.contentView = NSHostingView(rootView: AskPanelView(state: state))
        w.delegate = self
    }
}

extension AskPanel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        AskPanel.open.removeValue(forKey: key)
    }
}

private struct QA: Identifiable {
    let id = UUID()
    let question: String
    var answer: String?     // nil while generating
}

@MainActor
private final class AskState: ObservableObject {
    @Published var turns: [QA] = []
    @Published var input = ""
    @Published var loadingContext = true
    @Published var contextReason: String?   // non-nil → can't ask
    @Published var answering = false
    private var contextText = ""

    var canAsk: Bool { !loadingContext && contextReason == nil && !answering }

    func loadContext(url: URL, isFolder: Bool) {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                AskService.context(for: url, isFolder: isFolder)
            }.value
            contextText = result.text
            contextReason = result.text.isEmpty ? (result.reason ?? "") : nil
            loadingContext = false
        }
    }

    func submit() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAsk, !q.isEmpty else { return }
        input = ""
        answering = true
        let idx = turns.count
        turns.append(QA(question: q, answer: nil))
        let ctx = contextText
        Task {
            let a = await AskService.answer(question: q, context: ctx)
            if idx < turns.count { turns[idx].answer = a }
            answering = false
        }
    }
}

private struct AskPanelView: View {
    @ObservedObject var state: AskState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 15)).foregroundStyle(.tint)
                Text(L("Ask the on-device AI", "온디바이스 AI에게 질문"))
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.secondary)
                if state.loadingContext {
                    ProgressView().controlSize(.small).padding(.leading, 2)
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
            Divider()

            if let reason = state.contextReason {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.bubble").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(reason.isEmpty ? L("Nothing to ask about here.", "질문할 내용이 없어요.") : reason)
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if state.turns.isEmpty && !state.loadingContext {
                                Text(L("Ask anything about this — e.g. “What are the key points?”",
                                       "무엇이든 물어보세요 — 예: “핵심 내용이 뭐야?”"))
                                    .font(.system(size: 14)).foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                            }
                            ForEach(state.turns) { turn in
                                TurnView(turn: turn).id(turn.id)
                            }
                        }
                        .padding(18)
                    }
                    .onChange(of: state.turns.count) {
                        if let last = state.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }

            if state.contextReason == nil {
                Divider()
                HStack(spacing: 10) {
                    TextField(L("Ask a question…", "질문을 입력하세요…"), text: $state.input)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .onSubmit { state.submit() }
                        .disabled(!state.canAsk)
                    Button { state.submit() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                    }
                    .buttonStyle(.plain)
                    .disabled(!state.canAsk || state.input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TurnView: View {
    let turn: QA

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.fill").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
                Text(turn.question).font(.system(size: 15, weight: .semibold))
                    .textSelection(.enabled)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(.tint).frame(width: 18)
                if let a = turn.answer {
                    Text(a).font(.system(size: 15)).lineSpacing(4).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(L("Thinking…", "생각 중…")).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
