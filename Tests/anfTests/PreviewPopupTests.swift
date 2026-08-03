import Foundation
@testable import anf

/// #103 follow-up: rapid selection changes must not queue unbounded renders in
/// the shared QuickLookUIService (it went Not Responding with 926 mach ports).
/// The pacing rule is pure: a lone load goes through instantly, bursts defer.
func runQLPacingTests() {
    T.group("QuickLook load pacing") {
        T.isNil(QLLoadPacing.delay(sinceLastLoad: 10), "idle → load immediately")
        T.isNil(QLLoadPacing.delay(sinceLastLoad: QLLoadPacing.minInterval), "exactly at the interval → immediate")
        T.equal(QLLoadPacing.delay(sinceLastLoad: 0.05), QLLoadPacing.minInterval - 0.05,
                "mid-burst → defer the remainder of the interval")
        T.equal(QLLoadPacing.delay(sinceLastLoad: -1), QLLoadPacing.minInterval,
                "clock skew (negative elapsed) → full interval, never a huge delay")
    }
}

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
            // 30s, not 5: under midnight disk load (backups + mds) a fixture
        // listing can outlive a 5s deadline — that flake killed a nightly.
        // Healthy runs pass the condition in milliseconds either way.
        let deadline = Date().addingTimeInterval(30)
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

            // Lock (#103 follow-up: 음악 틀어두고 다른 작업): the popup stops
            // following the selection until unlocked.
            popup.state.toggleLock(current: b, folderItems: m.items)
            m.select(a)
            T.equal(popup.currentItemPath, b.url.path, "locked popup ignores selection changes")
            popup.state.toggleLock(current: nil, folderItems: [])
            T.equal(popup.currentItemPath, a.url.path, "unlock resumes following the selection")

            // ⎋ close must UNMOUNT the SwiftUI tree — a retained hosting view
            // kept an AVPlayer playing after close (#103 follow-up).
            let win = popup.windowForTesting
            win.close()
            T.isNil(win.contentView, "close drops the hosting view (players stop)")
            T.expect(!PreviewPopup.isOpen, "close clears the singleton")
        }

        T.group("preview size restore and save") {
            let d = UserDefaults.standard
            let keys = ["anf.previewPopup.frame.audio", "anf.previewPopup.frame.document",
                        "anf.previewPopup.frame.other", "anf.previewPopup.frame.last"]
            let backups = keys.map { ($0, d.string(forKey: $0)) }
            defer { for (k, v) in backups { v.map { d.set($0, forKey: k) } ?? d.removeObject(forKey: k) } }

            let dir = fm.temporaryDirectory.appendingPathComponent("anfpopz-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            try? Data("x".utf8).write(to: dir.appendingPathComponent("t.mp3"))

            let ws = WorkspaceModel()
            let m = ws.active
            m.navigate(to: dir)
            pump { m.fileItems.count == 1 }
            // By name, NOT items[0] — the listing prepends the synthetic ".."
            // parent row, and selecting that buckets as "other".
            guard let mp3 = m.items.first(where: { $0.name == "t.mp3" }) else {
                T.expect(false, "fixture listed"); return
            }
            m.select(mp3)

            // Saved audio frame → the popup opens at that size.
            keys.forEach { d.removeObject(forKey: $0) }
            d.set(NSStringFromRect(NSRect(x: 80, y: 80, width: 341, height: 470)),
                  forKey: "anf.previewPopup.frame.audio")
            PreviewPopup.show(workspace: ws)
            guard let p = PreviewPopup.currentForTesting else { T.expect(false, "opened"); return }
            T.equal(p.windowForTesting.frame.size.width.rounded(), 341, "audio width restored")
            T.equal(p.windowForTesting.frame.size.height.rounded(), 470, "audio height restored")
            p.windowForTesting.close()
            T.expect(d.string(forKey: "anf.previewPopup.frame.last") != nil,
                     "close writes the generic last-size key too")

            // No per-kind frame but a generic last → that size is used.
            d.removeObject(forKey: "anf.previewPopup.frame.audio")
            d.set(NSStringFromRect(NSRect(x: 80, y: 80, width: 355, height: 480)),
                  forKey: "anf.previewPopup.frame.last")
            PreviewPopup.show(workspace: ws)
            T.equal(PreviewPopup.currentForTesting?.windowForTesting.frame.width.rounded(), 355,
                    "generic last size restores when the kind has none")
            PreviewPopup.currentForTesting?.windowForTesting.close()
        }

        T.group("preview size-memory buckets") {
            let dir = fm.temporaryDirectory.appendingPathComponent("anfpops-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            func cat(_ name: String) -> String? {
                let u = dir.appendingPathComponent(name)
                fm.createFile(atPath: u.path, contents: Data("x".utf8))
                return FileItem(fastURL: u).map(PreviewSizeClass.category)
            }
            T.equal(cat("a.flac"), "audio", "flac → audio bucket")
            T.equal(cat("b.mkv"), "video", "mkv → video bucket")
            T.equal(cat("c.cbz"), "archive", "comic archive → archive bucket")
            T.equal(cat("d.png"), "image", "png → image bucket")
            T.equal(cat("e.hwpx"), "document", "hwpx → document bucket")
            T.equal(cat("f.swift"), "other", "unknown kind → other bucket")
        }

        T.group("locked popup's continuous-play queue") {
            let dir = fm.temporaryDirectory.appendingPathComponent("anfpopq-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for n in ["01.mp3", "02.flac", "03.mp3", "cover.jpg"] {
                try? Data("x".utf8).write(to: dir.appendingPathComponent(n))
            }
            defer { try? fm.removeItem(at: dir) }
            let items = ["01.mp3", "02.flac", "03.mp3", "cover.jpg"]
                .compactMap { FileItem(fastURL: dir.appendingPathComponent($0)) }

            let s = PreviewPopupState()
            T.isNil(s.advanceLocked(after: items[0]), "no advance while unlocked")

            s.toggleLock(current: items[0], folderItems: items)
            T.equal(s.lockedQueue.map(\.name), ["01.mp3", "02.flac", "03.mp3"],
                    "lock snapshots the folder's AUDIO files only")
            T.equal(s.advanceLocked(after: items[0])?.name, "02.flac", "advances across formats")
            T.equal(s.locked?.name, "02.flac", "the lock moves with the queue")
            T.equal(s.advanceLocked(after: items[1])?.name, "03.mp3", "advances to the last track")
            T.isNil(s.advanceLocked(after: items[2]), "end of queue → nil (playback stops)")

            s.toggleLock(current: nil, folderItems: [])
            T.isNil(s.locked, "unlock clears the lock")
            T.isNil(s.advanceLocked(after: items[0]), "unlocked again → no advance")
        }
    }
}
