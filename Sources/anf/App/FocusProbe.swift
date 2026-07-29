import AppKit

/// Reproduces the "enter a huge directory, come back out, keyboard focus is
/// gone" report: `ANF_FOCUS_PROBE=/path/to/bigdir anf` navigates to the dir's
/// parent, opens the big dir, waits for the (slow) listing, sends a REAL ⌘↑
/// keyDown through NSApp.sendEvent — the same path a user's keypress takes,
/// local monitor and all — then reports where the first responder ended up and
/// whether a ↓ arrow still moves the selection. Exits 0 when keyboard flow
/// survives the round trip, 1 when it died.
@MainActor
enum FocusProbe {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["ANF_FOCUS_PROBE"] != nil
    }

    static func run(window: NSWindow, workspace: WorkspaceModel) {
        guard let raw = ProcessInfo.processInfo.environment["ANF_FOCUS_PROBE"] else { return }
        let big = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        let parent = big.deletingLastPathComponent()
        Task { @MainActor in
            func settle(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
            func pump(until cond: () -> Bool, timeout: Double = 30) async {
                let deadline = Date().addingTimeInterval(timeout)
                while !cond() && Date() < deadline { await settle(0.1) }
            }
            @MainActor func key(_ code: UInt16, _ chars: String, flags: NSEvent.ModifierFlags = []) {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil,
                                                characters: chars, charactersIgnoringModifiers: chars,
                                                isARepeat: false, keyCode: code) {
                        NSApp.sendEvent(e)
                    }
                }
            }
            @MainActor func report(_ stage: String) {
                let fr = window.firstResponder
                let m = workspace.active
                print("FOCUSPROBE \(stage): url=\(m.currentURL.lastPathComponent)"
                      + " items=\(m.items.count) sel=\(m.selectedItems.map(\.name).prefix(2))"
                      + " firstResponder=\(fr.map { String(describing: type(of: $0)) } ?? "nil")"
                      + " modal=\(InputGate.modalActive)")
            }

            await settle(2)
            let m = workspace.active
            m.viewMode = .list
            m.navigate(to: parent)
            await pump(until: { !m.isLoading && !m.fileItems.isEmpty })
            await settle(0.5)
            guard let bigItem = m.items.first(where: { $0.url.lastPathComponent == big.lastPathComponent }) else {
                print("FOCUSPROBE FAIL — \(big.lastPathComponent) not found in \(parent.path)")
                exit(1)
            }
            m.select(bigItem)
            report("in-parent")

            m.open(bigItem)
            await pump(until: { !m.isLoading && m.currentURL.lastPathComponent == big.lastPathComponent })
            await settle(1.0)   // let the big listing finish painting
            report("in-bigdir")

            key(126, "\u{F700}", flags: .command)   // ⌘↑ — the real go-up path
            await pump(until: { m.currentURL.lastPathComponent == parent.lastPathComponent })
            await settle(1.0)
            report("back-in-parent")

            // The keyboard-flow verdict: does ↓ move the selection?
            let before = m.selectedItems.map(\.id)
            key(125, "\u{F701}")                    // ↓
            await settle(0.4)
            let after = m.selectedItems.map(\.id)
            report("after-arrow")
            let moved = before != after && !after.isEmpty

            // Phase 2 — the reported gesture: dive into the big dir and ⌘↑ back
            // OUT while its listing is still loading. The abandoned bulk read
            // clogs the (NFS) connection, so the parent's re-list can take well
            // over the old 1s selection-restore window.
            guard let again = m.items.first(where: { $0.url.lastPathComponent == big.lastPathComponent }) else {
                print("FOCUSPROBE FAIL — big dir vanished from parent"); exit(1)
            }
            m.open(again)
            await settle(0.25)                       // mid-load — don't wait
            key(126, "\u{F700}", flags: .command)    // ⌘↑ immediately
            await pump(until: { m.currentURL.lastPathComponent == parent.lastPathComponent })
            await pump(until: { !m.selectedItems.isEmpty }, timeout: 15)
            report("quick-bounce")
            let restored = m.selectedItems.first?.url.lastPathComponent == big.lastPathComponent
            print(restored ? "FOCUSPROBE ok2 — quick-bounce restored the selection"
                           : "FOCUSPROBE FAIL — quick-bounce left no/wrong selection")
            exit(moved && restored ? 0 : 1)
        }
    }
}
