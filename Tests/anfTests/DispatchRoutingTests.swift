import AppKit
@testable import anf

/// #42 P1 (last piece): KeyAction dispatch routing through the REAL
/// KeyboardController switch, with the workspace injected via
/// WindowRegistry.testOverride. Pins the contextual ⌘W order — tab first,
/// then pane, then window — and the layout/panel toggles.
func runDispatchRoutingTests() {
    MainActor.assumeIsolated {
        let wsKey = "anf.workspace.v1"
        let backup = UserDefaults.standard.data(forKey: wsKey)
        UserDefaults.standard.removeObject(forKey: wsKey)
        defer {
            if let backup { UserDefaults.standard.set(backup, forKey: wsKey) }
            else { UserDefaults.standard.removeObject(forKey: wsKey) }
            WindowRegistry.testOverride = .none
        }

        let ws = WorkspaceModel()
        WindowRegistry.testOverride = ws
        let kb = KeyboardController()

        T.group("dispatch: layout actions route to setLayout") {
            kb.dispatch(.layoutDual)
            T.equal(ws.layout, .dual, "⌘2 → dual")
            kb.dispatch(.layoutQuad)
            T.equal(ws.layout, .quad, "⌘4 → quad")
            kb.dispatch(.layoutSingle)
            T.equal(ws.layout, .single, "⌘1 → single")
        }

        T.group("dispatch: contextual ⌘W closes tab → pane → window in order") {
            ws.setLayout(.dual)
            ws.activePane = 0
            kb.dispatch(.newTab)
            T.equal(ws.activePaneModel.tabs.count, 2, "⌘T added a tab")

            kb.dispatch(.closeTab)
            T.equal(ws.activePaneModel.tabs.count, 1, "1st ⌘W closes the extra TAB, not the pane")
            T.equal(ws.layout, .dual, "layout untouched while tabs remain")

            kb.dispatch(.closeTab)
            T.equal(ws.layout, .single, "2nd ⌘W collapses the PANE (single tab left)")

            // Last tab, single pane, headless (no key window): the window branch
            // is a no-op here — the point is it must NOT eat tabs or crash.
            kb.dispatch(.closeTab)
            T.equal(ws.activePaneModel.tabs.count, 1, "final ⌘W targets the window, never the last tab")
        }

        T.group("dispatch: F3 opens the preview popup (#103)") {
            T.expect(!PreviewPopup.isOpen, "popup closed before")
            kb.dispatch(.previewPopup)
            T.expect(PreviewPopup.isOpen, "F3 action opens the popup")
            T.equal(Keymap.shared.action(flags: [], key: "f3"), .previewPopup,
                    "default keymap binds F3 to the popup")
        }

        T.group("dispatch: panel toggles flip workspace state") {
            let insp = ws.inspectorVisible
            kb.dispatch(.toggleInspector)
            T.equal(ws.inspectorVisible, !insp, "⌘I toggles the inspector")
            kb.dispatch(.toggleInspector)
            T.equal(ws.inspectorVisible, insp, "…and back")

            let bar = ws.pathBarVisible
            kb.dispatch(.togglePathBar)
            T.equal(ws.pathBarVisible, !bar, "⌘/ toggles the status bar")
            kb.dispatch(.togglePathBar)
            T.equal(ws.pathBarVisible, bar, "…and back")
        }
    }
}
