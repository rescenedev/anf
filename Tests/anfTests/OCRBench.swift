import Foundation
@testable import anf

/// OCR timing harness — "measure the AI too." Run with
///   ANF_BENCH_OCR=/path/to/images swift run anfTests
/// Recognizes text in every image under the root, reports per-image ms and the
/// slowest files, so the search-indexing cost is a known number, not a guess.
func runOCRBench(root: String) {
    let clock = ContinuousClock()
    @inline(__always) func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
    }

    let fm = FileManager.default
    var images: [URL] = []
    if let e = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil) {
        for case let u as URL in e where OCRService.isImage(u) { images.append(u) }
    }
    guard !images.isEmpty else { print("OCRBENCH: no images under \(root)"); return }

    print("OCRBENCH images=\(images.count) (accurate, ko+en, downscale≤3000px)")
    var times: [(ms: Double, chars: Int, path: String)] = []
    let t0 = clock.now
    for u in images {
        let t = clock.now
        let text = OCRService.recognizeText(in: u)
        times.append((ms(clock.now - t), text?.count ?? 0, u.lastPathComponent))
    }
    let total = ms(clock.now - t0)

    times.sort { $0.ms > $1.ms }
    let all = times.map(\.ms).sorted()
    let median = all[all.count / 2]
    let mean = all.reduce(0, +) / Double(all.count)
    print(String(format: "OCRBENCH total %.0fms · mean %.0fms · median %.0fms · per image",
                 total, mean, median))
    for t in times.prefix(8) {
        print(String(format: "  %6.0fms  %4d chars  %@", t.ms, t.chars, t.path))
    }
}
