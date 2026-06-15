import Foundation
@testable import anf

/// Issue #3: in a split, clicking a sidebar favorite must navigate ONLY the
/// focused pane — people park a network drive in one pane and browse local
/// folders in the other, and a pin click clobbered both panes.
func runWorkspacePinTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("anfpin-\(UUID().uuidString)")
        let a = dir.appendingPathComponent("a")
        let b = dir.appendingPathComponent("b")
        let c = dir.appendingPathComponent("c")
        for d in [a, b, c] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: dir) }

        T.group("⌃` always surfaces a local shell, even over an SSH tab (#29)") {
            typealias A = WorkspaceModel.TerminalToggle
            T.equal(WorkspaceModel.terminalToggleAction(showing: false, activeIsLocalShell: false), A.showLocal,
                    "hidden drawer → show local shell")
            T.equal(WorkspaceModel.terminalToggleAction(showing: false, activeIsLocalShell: true), A.showLocal,
                    "hidden drawer (local exists) → show it")
            T.equal(WorkspaceModel.terminalToggleAction(showing: true, activeIsLocalShell: true), A.hide,
                    "visible local shell → hide")
            T.equal(WorkspaceModel.terminalToggleAction(showing: true, activeIsLocalShell: false), A.showLocal,
                    "visible SSH/SFTP tab → open local shell, don't just hide the drawer")
        }

        T.group("openPinned in a split navigates only the focused pane") {
            let ws = WorkspaceModel()
            ws.setLayout(.dual)
            ws.panes[0].current.navigate(to: a)
            ws.panes[1].current.navigate(to: b)
            ws.focusPane(1)
            ws.openPinned(c)
            T.equal(ws.panes[1].current.currentURL.path, c.path, "focused pane goes to the pin")
            T.equal(ws.panes[0].current.currentURL.path, a.path, "opposite pane is untouched")
            T.expect(ws.layout == .dual, "the split itself survives the click")
        }

        T.group("openPinned from a single pane still just navigates") {
            let ws = WorkspaceModel()
            ws.setLayout(.single)
            ws.openPinned(b)
            T.equal(ws.active.currentURL.path, b.path, "single-pane pin click navigates")
            T.expect(ws.layout == .single, "no surprise split appears")
        }
    }
}
