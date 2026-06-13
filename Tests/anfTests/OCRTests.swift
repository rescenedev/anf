import Foundation
import AppKit
@testable import anf

/// On-device OCR (Vision): rendered text must round-trip through recognition,
/// and the cache must serve repeats. Korean + English, since that's the point.
func runOCRTests() {
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

    T.group("imageContent search finds text inside an image") {
        let u = dir.appendingPathComponent("receipt.png")
        makeImage("Starbucks Receipt", to: u)
        let hits = PaletteSearch.imageContent(root: dir, needle: "starbucks", cap: 10)
        // fd may be absent in CI; only assert when the scan actually ran.
        if ExternalTools.path("fd") != nil {
            T.expect(hits.contains { $0.lastPathComponent == "receipt.png" },
                     "OCR'd image matched by its text content")
        }
    }
}
