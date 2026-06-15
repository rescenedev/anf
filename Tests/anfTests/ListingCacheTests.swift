import Foundation
@testable import anf

/// Re-entering a cached folder must paint the previous listing immediately
/// (before the fresh read lands), and the fresh read must still replace it.
func runListingCacheTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("anfcache-\(UUID().uuidString)")
        let other = fm.temporaryDirectory.appendingPathComponent("anfcache2-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.createDirectory(at: other, withIntermediateDirectories: true)
            for i in 1...5 {
                try "x".write(to: dir.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
            }
        } catch { T.expect(false, "fixture setup threw: \(error)"); return }
        defer { try? fm.removeItem(at: dir); try? fm.removeItem(at: other) }

        func pump(until cond: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !cond() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }

        T.group("ListingCache: instant re-entry") {
            let model = BrowserModel(start: dir)
            pump { model.fileItems.count == 5 }
            T.equal(model.fileItems.count, 5, "first visit loads fresh")

            model.navigate(to: other)
            pump { model.fileItems.isEmpty }

            // A new file appears while we're away.
            try? "y".write(to: dir.appendingPathComponent("f6.txt"), atomically: true, encoding: .utf8)

            model.goBack()
            T.equal(model.fileItems.count, 5, "cached listing paints synchronously (no read yet)")
            pump { model.fileItems.count == 6 }
            T.equal(model.fileItems.count, 6, "fresh read replaces the cache with the new file")
        }
    }
}
