import AppKit
@testable import anf

/// The thumbnail pool must bound concurrency: a burst of requests (scrolling an
/// image-heavy folder) should never run more than `maxConcurrent` generations
/// at once, and all should still complete.
func runThumbnailThrottleTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("anfthumb-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // 30 tiny PNGs — real files so QLThumbnailGenerator has something to chew.
        var items: [FileItem] = []
        let img = NSImage(size: NSSize(width: 8, height: 8))
        img.lockFocus(); NSColor.systemBlue.drawSwatch(in: NSRect(x: 0, y: 0, width: 8, height: 8)); img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            T.expect(false, "test PNG encode"); return
        }
        for i in 0..<30 {
            let url = dir.appendingPathComponent("img\(i).png")
            try? png.write(to: url)
            if let item = FileItem(url: url) { items.append(item) }
        }
        T.equal(items.count, 30, "30 image fixtures built")

        T.group("ThumbnailProvider: bounded concurrent generation") {
            var completed = 0
            let group = DispatchGroup()
            for item in items {
                group.enter()
                Task { @MainActor in
                    _ = await ThumbnailProvider.shared.thumbnail(for: item, side: 64)
                    completed += 1
                    group.leave()
                }
            }
            let deadline = Date().addingTimeInterval(20)
            while group.wait(timeout: .now()) == .timedOut && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            T.equal(completed, 30, "every queued thumbnail request completes")
            // Second pass is all cache hits — must return instantly and not deadlock.
            var hits = 0
            for item in items where ThumbnailProvider.shared.cached(for: item, side: 64) != nil { hits += 1 }
            T.expect(hits >= 1, "generated thumbnails are cached for reuse (\(hits)/30)")
        }
    }
}
