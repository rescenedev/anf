import Foundation
@testable import anf

/// PDF body-extraction latency breakdown. Run with
///   ANF_BENCH_PDF=/folder/with/pdfs swift run anfTests
/// Prints per-file size/pages/ms plus the worst case and the wall-clock of the
/// same parallel sweep `docContent` performs during a palette search.
func runPDFBench(path: String) {
    let clock = ContinuousClock()
    @inline(__always) func ms(_ d: Duration) -> Double {
        Double(d.components.attoseconds) / 1e15
    }
    let fm = FileManager.default
    var pdfs: [URL] = []
    if let walker = fm.enumerator(at: URL(fileURLWithPath: path),
                                  includingPropertiesForKeys: [.fileSizeKey]) {
        for case let url as URL in walker where url.pathExtension.lowercased() == "pdf" {
            pdfs.append(url)
        }
    }
    print("pdf bench: \(pdfs.count) files under \(path)")
    var total = 0.0, worst = (0.0, "")
    for url in pdfs {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let t0 = clock.now
        let body = DocumentText.extract(url)
        let elapsed = ms(clock.now - t0)
        total += elapsed
        if elapsed > worst.0 { worst = (elapsed, url.lastPathComponent) }
        print(String(format: "  %7.1fms  %6.1fKB  %7d chars  %@",
                     elapsed, Double(size) / 1024, body?.count ?? 0, url.lastPathComponent))
    }
    print(String(format: "serial total %.0fms, worst %.0fms (%@)", total, worst.0, worst.1))

    // The palette path: parallel sweep through the cache, same as docContent.
    // Cold = first query of a session; warm = every following keystroke.
    for label in ["cold", "warm"] {
        let t0 = clock.now
        DispatchQueue.concurrentPerform(iterations: pdfs.count) { i in
            _ = DocumentTextCache.shared.text(for: pdfs[i])?
                .localizedCaseInsensitiveContains("zz없는단어zz")
        }
        print(String(format: "parallel sweep (%@ cache): %.0fms wall", label, ms(clock.now - t0)))
    }
}

/// Folder-entry latency breakdown. Not part of the pass/fail suite — run with
///   ANF_BENCH=/path/to/big/folder swift run anfTests
/// and it prints where the milliseconds go (bulk read → FileItem build → sort).
func runNavBench(path: String) {
    @inline(__always) func ms(_ t: ContinuousClock.Instant, _ u: ContinuousClock.Instant) -> String {
        String(format: "%6.1fms", Double((u - t).components.attoseconds) / 1e15)
    }
    let clock = ContinuousClock()
    print("bench: \(path)")

    for round in 1...3 {
        let t0 = clock.now
        let raw = FastDirRead.list(path: path) ?? []
        let t1 = clock.now

        let url = URL(fileURLWithPath: path)
        let items: [FileItem] = MainActor.assumeIsolated {
            var sem: [FileItem] = []
            let group = DispatchGroup()
            group.enter()
            Task { @MainActor in
                sem = await FileSystemService().contentsFast(of: url, showHidden: false)
                group.leave()
            }
            while group.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            return sem
        }
        let t2 = clock.now

        let sorted = MainActor.assumeIsolated {
            FileSystemService().filteredSorted(items, filter: "", by: SortOrder())
        }
        let t3 = clock.now

        print("  #\(round) raw=\(raw.count) bulkRead=\(ms(t0, t1))  contentsFast=\(ms(t1, t2))  sort=\(ms(t2, t3))  total=\(ms(t0, t3))  (\(sorted.count) items)")
    }
}
