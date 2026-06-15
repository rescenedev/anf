import Foundation
@testable import anf

func runSavedViewTests() {
    T.group("split divider HUD label (issue #12)") {
        // Halves always sum to 100 — rounding must never show e.g. "60% · 41%".
        T.equal(WorkspaceModel.splitLabel(0.5), "50% · 50%", "even split")
        T.equal(WorkspaceModel.splitLabel(0.6), "60% · 40%", "60/40")
        T.equal(WorkspaceModel.splitLabel(0.333), "33% · 67%", "rounds and complements to 100")
        T.equal(WorkspaceModel.splitLabel(0.666), "67% · 33%", "rounding stays consistent")
        T.equal(WorkspaceModel.splitLabel(0.15), "15% · 85%", "min clamp edge")
        T.equal(WorkspaceModel.splitLabel(0.85), "85% · 15%", "max clamp edge")
    }

    T.group("SavedView codable") {
        let snap = ViewSnapshot(
            layout: "quad", activePane: 1, splitRatioH: 0.4, splitRatioV: 0.6,
            panes: [ViewSnapshot.Pane(
                tabs: [ViewSnapshot.Tab(path: "/a", viewMode: "list"),
                       ViewSnapshot.Tab(path: "/b", viewMode: "icons")],
                activeIndex: 1)])
        let view = SavedView(name: "작업공간", snapshot: snap)

        do {
            let data = try JSONEncoder().encode(view)
            let back = try JSONDecoder().decode(SavedView.self, from: data)
            T.equal(back.id, view.id, "id round-trips")
            T.equal(back.name, "작업공간", "name round-trips")
            T.equal(back.snapshot.layout, "quad", "layout round-trips")
            T.equal(back.snapshot.activePane, 1, "activePane round-trips")
            T.equal(back.snapshot.panes.first?.tabs.count, 2, "tabs round-trip")
            T.equal(back.snapshot.panes.first?.tabs[1].path, "/b", "tab path round-trips")
            T.equal(back.snapshot.panes.first?.tabs[1].viewMode, "icons", "tab viewMode round-trips")
        } catch { T.expect(false, "encode/decode threw: \(error)") }

        let s2 = ViewSnapshot(layout: "single", activePane: 0,
                              splitRatioH: 0.5, splitRatioV: 0.5, panes: [])
        T.expect(SavedView(name: "a", snapshot: s2).id != SavedView(name: "a", snapshot: s2).id,
                 "distinct views get distinct ids")
    }
}
