import Foundation
@testable import anf

/// #103/#104 follow-up: the detachable preview popup. The panel must follow the
/// active pane's selection (it's a live second screen, not a snapshot) and be a
/// singleton — summoning it twice brings the same window forward.
func runPreviewPopupTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let wsKey = "anf.workspace.v1"
        let backup = UserDefaults.standard.data(forKey: wsKey)
        UserDefaults.standard.removeObject(forKey: wsKey)
        defer {
            if let backup { UserDefaults.standard.set(backup, forKey: wsKey) }
            else { UserDefaults.standard.removeObject(forKey: wsKey) }
        }
        func pump(until: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !until() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        T.group("preview popup follows the selection and stays a singleton") {
            let dir = fm.temporaryDirectory.appendingPathComponent("anfpop-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for n in ["a.txt", "b.txt"] {
                try? "x".write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8)
            }
            defer { try? fm.removeItem(at: dir) }

            let ws = WorkspaceModel()
            let m = ws.active
            m.navigate(to: dir)
            pump { m.fileItems.count == 2 }
            guard let a = m.items.first(where: { $0.name == "a.txt" }),
                  let b = m.items.first(where: { $0.name == "b.txt" }) else {
                T.expect(false, "fixture listed"); return
            }
            m.select(a)

            PreviewPopup.show(workspace: ws)
            guard let popup = PreviewPopup.currentForTesting else {
                T.expect(false, "popup opened"); return
            }
            T.expect(PreviewPopup.isOpen, "popup is open")
            T.equal(popup.currentItemPath, a.url.path, "popup shows the selected file")

            m.select(b)
            T.equal(popup.currentItemPath, b.url.path, "popup follows a selection change")

            PreviewPopup.show(workspace: ws)
            T.expect(PreviewPopup.currentForTesting === popup, "second summon reuses the same popup")
        }
    }
}
