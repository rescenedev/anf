import AppKit
@testable import anf

/// #42 P1: menu-item validation gating. The three menu controllers resolve
/// their workspace through WindowRegistry.current, which is window-driven —
/// the new `testOverride` seam injects one headless, so the enable/disable and
/// checkmark rules are finally pinned: restoreLastSplit needs a backup,
/// removeAPIKey needs a stored key, the AI folder tools need the feature on.
func runMenuValidationTests() {
    MainActor.assumeIsolated {
        let wsKey = "anf.workspace.v1"
        let wsBackup = UserDefaults.standard.data(forKey: wsKey)
        UserDefaults.standard.removeObject(forKey: wsKey)
        let aiWas = AIFeatures.enabled
        defer {
            if let wsBackup { UserDefaults.standard.set(wsBackup, forKey: wsKey) }
            else { UserDefaults.standard.removeObject(forKey: wsKey) }
            AIFeatures.enabled = aiWas
            AISecret.testOverride = .none
            WindowRegistry.testOverride = .none
        }
        func item(_ action: Selector) -> NSMenuItem {
            let it = NSMenuItem(title: "t", action: action, keyEquivalent: "")
            return it
        }

        T.group("View menu: restoreLastSplit needs a backup; status bar shows state") {
            let ws = WorkspaceModel()
            WindowRegistry.testOverride = ws
            let c = ViewMenuController.shared

            let restore = item(#selector(ViewMenuController.restoreLastSplit(_:)))
            T.expect(!c.validateMenuItem(restore),
                     "no split backup yet → 복원 disabled")
            ws.setLayout(.dual)
            ws.setLayout(.single)   // shrinking a multi-pane arrangement records the backup
            T.expect(c.validateMenuItem(restore),
                     "after a destructive shrink → 복원 enabled")

            let bar = item(#selector(ViewMenuController.toggleStatusBar(_:)))
            ws.pathBarVisible = false
            _ = c.validateMenuItem(bar)
            T.equal(bar.state, .off, "status-bar checkmark mirrors hidden state")
            ws.pathBarVisible = true
            _ = c.validateMenuItem(bar)
            T.equal(bar.state, .on, "status-bar checkmark mirrors visible state")

            // No workspace (all windows gone) → everything workspace-driven off.
            WindowRegistry.testOverride = .some(nil)
            T.expect(!c.validateMenuItem(item(#selector(ViewMenuController.connectToServer(_:)))),
                     "no workspace → workspace-driven items disabled")
        }

        T.group("AI menu: removeAPIKey gated on a stored key; toggle mirrors state") {
            let c = AIMenuController.shared
            let remove = item(#selector(AIMenuController.removeAPIKey(_:)))
            AISecret.testOverride = .some(nil)
            T.expect(!c.validateMenuItem(remove), "no key in the Keychain → 삭제 disabled")
            AISecret.testOverride = "sk-ant-api03-test"
            T.expect(c.validateMenuItem(remove), "key present → 삭제 enabled")

            let toggle = item(#selector(AIMenuController.toggleAI(_:)))
            AIFeatures.enabled = true
            _ = c.validateMenuItem(toggle)
            T.equal(toggle.state, .on, "AI checkmark on")
            AIFeatures.enabled = false
            _ = c.validateMenuItem(toggle)
            T.equal(toggle.state, .off, "AI checkmark off")
        }

        T.group("Tools menu: LLM actions need AI on; plain file tools don't") {
            let ws = WorkspaceModel()
            WindowRegistry.testOverride = ws
            let c = ToolsMenuController.shared
            AIFeatures.enabled = false
            T.expect(!c.validateMenuItem(item(#selector(ToolsMenuController.summarizeFolder(_:)))),
                     "AI off → summarize disabled")
            T.expect(c.validateMenuItem(item(#selector(ToolsMenuController.organizeByKind(_:)))),
                     "AI off → plain organize-by-kind still enabled")
            AIFeatures.enabled = true
            T.expect(c.validateMenuItem(item(#selector(ToolsMenuController.summarizeFolder(_:)))),
                     "AI on → summarize enabled")
            WindowRegistry.testOverride = .some(nil)
            T.expect(!c.validateMenuItem(item(#selector(ToolsMenuController.organizeByKind(_:)))),
                     "no workspace → folder tools disabled")
        }
    }
}
