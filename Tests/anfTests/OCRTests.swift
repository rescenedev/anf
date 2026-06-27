import Foundation
import AppKit
@testable import anf

/// On-device OCR (Vision): rendered text must round-trip through recognition,
/// and the cache must serve repeats. Korean + English, since that's the point.
func runOCRTests() {
    AIFeatures.enabled = true        // image-content search is gated behind the AI switch
    defer { AIFeatures.enabled = false }
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("anfocr-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    // Render text to a PNG so the test is self-contained (no fixture files).
    func makeImage(_ text: String, to url: URL, size: NSSize = NSSize(width: 900, height: 240)) {
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        (text as NSString).draw(at: NSPoint(x: 40, y: 80), withAttributes: attrs)
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    T.group("OCRService recognizes rendered text") {
        let en = dir.appendingPathComponent("en.png")
        makeImage("Invoice Total 2026", to: en)
        let t = OCRService.recognizeText(in: en) ?? ""
        T.expect(t.localizedCaseInsensitiveContains("Invoice"), "English word recognized (got: \(t))")
        T.expect(t.contains("2026"), "number recognized")

        let ko = dir.appendingPathComponent("ko.png")
        makeImage("금융위원회 공고", to: ko)
        let tk = OCRService.recognizeText(in: ko) ?? ""
        T.expect(tk.contains("금융") || tk.contains("공고"), "Korean recognized (got: \(tk))")

        T.expect(OCRService.isImage(en), ".png is an image")
        T.expect(!OCRService.isImage(dir.appendingPathComponent("x.txt")), ".txt is not")
    }

    T.group("OCRTextCache serves and gates") {
        let u = dir.appendingPathComponent("cache.png")
        makeImage("CacheTest Alpha", to: u)
        T.expect(OCRTextCache.shared.cached(for: u) == nil, "cold: nothing cached yet")
        let first = OCRTextCache.shared.text(for: u) ?? ""
        T.expect(first.localizedCaseInsensitiveContains("CacheTest"), "recognized on first call")
        T.expect(OCRTextCache.shared.cached(for: u) != nil, "warm: now cached")

        // A blank image caches empty (nil) and isn't re-OCR'd forever.
        let blank = dir.appendingPathComponent("blank.png")
        makeImage("", to: blank)
        T.expect(OCRTextCache.shared.text(for: blank) == nil, "text-free image → nil")
    }

    T.group("imageContent OCR path finds text inside an image (bounded)") {
        let u = dir.appendingPathComponent("receipt.png")
        makeImage("Starbucks Receipt", to: u)
        // OCR path is on-the-fly (the visual path is the persistent index).
        let hits = PaletteSearch.imageContent(root: dir, needle: "starbucks", cap: 10)
        T.expect(hits.contains { $0.lastPathComponent == "receipt.png" },
                 "OCR'd image matched by its text content")
    }

    T.group("confidence floor rejects near-zero noise labels") {
        // The DSC05651 false-positive bug: canine@0.0004 passed the old filter.
        T.expect(ImageClassifier.confidenceFloor >= 0.25,
                 "floor high enough to drop ~0 noise (was hasMinimumRecall, useless)")
    }

    T.group("ImageClassifier query matching (Korean aliases + English)") {
        let labels = ["labrador retriever", "dog", "domestic animal", "pet"]
        T.expect(ImageClassifier.matches(query: "강아지", labels: labels), "강아지 → dog labels")
        T.expect(ImageClassifier.matches(query: "개", labels: labels), "개 → dog")
        T.expect(ImageClassifier.matches(query: "dog", labels: labels), "English query direct")
        T.expect(ImageClassifier.matches(query: "retriever", labels: labels), "substring of a label")
        T.expect(!ImageClassifier.matches(query: "고양이", labels: labels), "고양이 ≠ dog image")
        // The most common Korean words for cat/dog must POSITIVELY match their own
        // labels — regression for the particle stripper mangling "고양이"→"고양"
        // (and "멍멍이"→"멍멍") before the alias lookup, so the search returned
        // nothing for the very word that is an explicit alias key.
        let catLabels = ["cat", "kitten", "feline", "domestic animal"]
        T.expect(ImageClassifier.matches(query: "고양이", labels: catLabels), "고양이 → cat labels")
        T.expect(ImageClassifier.matches(query: "고양이 사진", labels: ["cat"]), "'고양이 사진' → cat")
        T.expect(ImageClassifier.matches(query: "고양이가", labels: ["cat"]), "particle on an alias ('고양이가') still → cat")
        T.expect(ImageClassifier.matches(query: "멍멍이", labels: ["dog"]), "멍멍이 → dog")
        T.equal(ImageClassifier.contentTokens("고양이"), ["고양이"], "alias word kept whole, not particle-stripped")
        T.expect(!ImageClassifier.matches(query: "강아지", labels: []), "no labels → no match")
        T.expect(ImageClassifier.matches(query: "음식", labels: ["food", "dish"]), "음식 → food")
        T.expect(ImageClassifier.matches(query: "문서", labels: ["document", "text"]), "문서 → document")
        // Multi-word queries tokenize (the bug 런던에서-찍은-사진 surfaced).
        T.expect(ImageClassifier.matches(query: "강아지 사진", labels: labels), "'강아지 사진' tokenizes")
        T.expect(ImageClassifier.matches(query: "음식 사진", labels: ["food"]), "'음식 사진' → food")
        T.expect(ImageClassifier.matches(query: "런던에서 찍은 강아지", labels: labels),
                 "particle-stripped token (강아지) still matches")
        // Location ('런던') isn't in the visual taxonomy — honestly no match.
        T.expect(!ImageClassifier.matches(query: "런던에서 찍은 사진", labels: ["building", "sky"]),
                 "location query can't match visual labels (needs EXIF geo, later)")
        T.equal(ImageClassifier.contentTokens("런던에서 찍은 사진"), ["런던"], "filler/particles dropped")
    }

    T.group("imageFiles walk: bounded, recursive, skips non-images") {
        let sub = dir.appendingPathComponent("nested/deep")
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        makeImage("A", to: dir.appendingPathComponent("a.png"))
        makeImage("B", to: sub.appendingPathComponent("b.png"))
        try? "x".write(to: dir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let found = PaletteSearch.imageFiles(under: dir, limit: 50)
        let names = Set(found.map(\.lastPathComponent))
        T.expect(names.contains("a.png"), "top-level image found")
        T.expect(names.contains("b.png"), "nested image found (recursive)")
        T.expect(!names.contains("note.txt"), "non-image skipped")
        T.expect(PaletteSearch.imageFiles(under: dir, limit: 1).count == 1, "limit honored")
    }
}
