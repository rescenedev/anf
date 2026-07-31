import Foundation
@testable import anf

/// #101: network drives must survive a reboot. Two halves — the remount
/// memory's pure merge/forget logic, and the workspace-restore rule that KEEPS
/// a network tab whose share isn't mounted yet (the old dead-path filter
/// dropped it, then save() cemented the loss: the user's pin was gone forever).
func runNetworkRemountTests() {
    typealias E = NetworkRemount.Entry

    T.group("remount memory: merge keeps unmounted shares and caps") {
        let remembered = [E(remountURL: "smb://nas/a", mountPath: "/Volumes/a"),
                          E(remountURL: "smb://nas/b", mountPath: "/Volumes/b")]
        // After a reboot only `a` is mounted again.
        let merged = NetworkRemount.merge(remembered: remembered,
                                          current: [E(remountURL: "smb://nas/a", mountPath: "/Volumes/a")],
                                          cap: 8)
        T.equal(merged.count, 2, "the unmounted share stays remembered")
        T.equal(merged.first?.remountURL, "smb://nas/a", "current mounts move to the front")

        let many = (0..<12).map { E(remountURL: "smb://nas/v\($0)", mountPath: "/Volumes/v\($0)") }
        T.equal(NetworkRemount.merge(remembered: many, current: [], cap: 8).count, 8,
                "no current mounts → memory preserved (capped), never wiped")
        T.equal(NetworkRemount.merge(remembered: many, current: [many[0]], cap: 8).count, 8,
                "memory is capped")
    }

    T.group("remount memory: stored/forget round-trip") {
        let backup = UserDefaults.standard.array(forKey: NetworkRemount.defaultsKey)
        defer {
            if let backup { UserDefaults.standard.set(backup, forKey: NetworkRemount.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: NetworkRemount.defaultsKey) }
        }
        UserDefaults.standard.set([["smb://nas/a", "/Volumes/a"], ["smb://nas/b", "/Volumes/b"]],
                                  forKey: NetworkRemount.defaultsKey)
        T.equal(NetworkRemount.stored().count, 2, "entries decode")
        NetworkRemount.forget(mountPath: "/Volumes/a")   // the user ejected `a`
        T.equal(NetworkRemount.stored().map(\.remountURL), ["smb://nas/b"],
                "eject removes exactly that share from the memory")
    }

    MainActor.assumeIsolated {
        T.group("restore keeps a network tab whose share isn't mounted (#101)") {
            let key = "anf.workspace.v1"
            let backup = UserDefaults.standard.data(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
            defer {
                if let backup { UserDefaults.standard.set(backup, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }

            let fm = FileManager.default
            let localDir = fm.temporaryDirectory.appendingPathComponent("anfnet-\(UUID().uuidString)")
            try? fm.createDirectory(at: localDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: localDir) }

            // Handcraft a saved state: one live local tab, one network tab whose
            // path does NOT exist (share not mounted), one dead LOCAL tab.
            let state: [String: Any] = [
                "layout": "single", "activePane": 0, "sidebarVisible": true, "inspectorVisible": false,
                "panes": [[
                    "tabs": [
                        ["path": localDir.path, "viewMode": "list"],
                        ["path": "/Volumes/anf-test-share/photos", "viewMode": "list", "network": true],
                        ["path": "/tmp/anf-gone-\(UUID().uuidString)", "viewMode": "list"],
                    ],
                    "activeIndex": 0,
                ]],
            ]
            let data = try! JSONSerialization.data(withJSONObject: state)
            UserDefaults.standard.set(data, forKey: key)

            let ws = WorkspaceModel()
            let paths = ws.panes[0].tabs.map(\.currentURL.path)
            T.expect(paths.contains(localDir.path), "live local tab restored")
            T.expect(paths.contains("/Volumes/anf-test-share/photos"),
                     "network tab KEPT although its share isn't mounted — was dropped before")
            T.expect(!paths.contains { $0.hasPrefix("/tmp/anf-gone-") },
                     "genuinely dead local tab still filtered out")
        }
    }
}
