import Foundation
@testable import anf

/// The async tag-display pipeline. `FileTags.display` must NEVER read the file
/// system — it runs per row inside main-thread cell drawing, and the xattr read
/// is a blocking network round-trip on SMB/NFS (the photo-NAS beachball).
/// Contract: miss → immediate "untagged" + queued background read; batch lands →
/// cache filled, `tagsResolvedNote` posted, `TagVersion` bumped; a cache clear
/// mid-flight discards the stale batch.
///
/// `readOverride` stands in for the xattr read, so this runs headless without
/// the metadata daemon (the ANF_SKIP_TAGS hang class) and can PROVE display
/// never touches the real reader.
func runTagPipelineTests() {
    MainActor.assumeIsolated {
        func pump(until: () -> Bool) {
            // 30s, not 5: under midnight disk load (backups + mds) a fixture
        // listing can outlive a 5s deadline — that flake killed a nightly.
        // Healthy runs pass the condition in milliseconds either way.
        let deadline = Date().addingTimeInterval(30)
            while !until() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        defer { FileTags.readOverride = nil; FileTags.clearColorCache() }

        T.group("display never reads inline — miss is instant and untagged") {
            FileTags.clearColorCache()
            final class Count: @unchecked Sendable { var n = 0; let lock = NSLock() }
            let reads = Count()
            FileTags.readOverride = { url in
                reads.lock.lock(); reads.n += 1; reads.lock.unlock()
                return url.lastPathComponent.hasPrefix("tagged") ? ["Red", "invoice"] : []
            }

            let a = URL(fileURLWithPath: "/tmp/anf-tagpipe/tagged-a.png")
            let first = FileTags.display(of: a)
            T.isNil(first.color, "cache miss paints untagged immediately")
            T.equal(reads.n, 0, "no read happened on the draw path")

            // The queued batch resolves off-main and fills the cache.
            pump { FileTags.display(of: a).color != nil }
            T.notNil(FileTags.display(of: a).color, "resolved batch fills the colour")
            T.equal(FileTags.display(of: a).named, ["invoice"], "named tags resolved too")
            T.expect(reads.n >= 1, "the background reader ran")
        }

        T.group("a burst coalesces into batches and bumps TagVersion once per batch") {
            FileTags.clearColorCache()
            FileTags.readOverride = { _ in ["Blue"] }
            let v0 = TagVersion.shared.n
            let urls = (0..<50).map { URL(fileURLWithPath: "/tmp/anf-tagpipe/burst-\($0).png") }
            for u in urls { _ = FileTags.display(of: u) }   // one scroll frame's misses
            pump { FileTags.display(of: urls[49]).color != nil }
            for u in urls {
                if FileTags.display(of: u).color == nil {
                    T.expect(false, "every queued path resolved"); break
                }
            }
            let bumps = TagVersion.shared.n - v0
            T.expect(bumps >= 1 && bumps <= 5,
                     "the 50-row burst resolved in a few coalesced batches (\(bumps) bumps), not 50")
        }

        T.group("clearColorCache discards an in-flight batch (stale-tag guard)") {
            FileTags.clearColorCache()
            final class Gate: @unchecked Sendable {
                let lock = NSLock(); var open = false
                func wait() { while true { lock.lock(); let o = open; lock.unlock()
                    if o { return }; Thread.sleep(forTimeInterval: 0.01) } }
            }
            let gate = Gate()
            FileTags.readOverride = { _ in gate.wait(); return ["Green"] }
            let u = URL(fileURLWithPath: "/tmp/anf-tagpipe/stale.png")
            _ = FileTags.display(of: u)
            // Let the drain wake (30ms), snapshot the batch and start the read
            // (which blocks on the gate) — then invalidate mid-flight.
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            FileTags.clearColorCache()   // e.g. a tag edit reloaded the listing
            gate.lock.lock(); gate.open = true; gate.lock.unlock()
            // The stale batch must NOT land in the fresh cache.
            let deadline = Date().addingTimeInterval(0.5)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            FileTags.readOverride = { _ in [] }   // re-fetch path resolves empty now
            T.isNil(FileTags.display(of: u).color,
                    "pre-clear read result was discarded, not written into the fresh cache")
        }
    }
}
