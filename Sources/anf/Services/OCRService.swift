import Foundation
import Vision
import CoreGraphics
import ImageIO

/// On-device text recognition for images, via the system Vision framework.
/// No model to bundle, no network — Apple's OCR runs entirely on the Mac and
/// supports Korean + English, so this keeps the "telemetry 0" promise while
/// making the text inside screenshots/scans/photos searchable.
enum OCRService {

    /// Image extensions we run OCR on. (PDFs go through PDFKit's text layer in
    /// DocumentText; scanned-PDF OCR is a later refinement.)
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp",
    ]

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Languages, most-preferred first. Korean then English covers the common
    /// domestic case (KakaoTalk caps, 공문 스캔) without losing Latin text.
    static let languages = ["ko-KR", "en-US"]

    /// Recognized text for an image, or nil when there's none / it can't be read.
    /// Downscales very large images first: OCR accuracy plateaus well below
    /// phone-camera resolution, and full-size CGImages make Vision crawl.
    nonisolated static func recognizeText(in url: URL, fast: Bool = false) -> String? {
        guard let cg = loadCGImage(url, maxPixel: 3000) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// Decode (and optionally downscale) an image to a CGImage via ImageIO —
    /// cheaper than NSImage and avoids loading a 48-megapixel file in full.
    nonisolated static func loadCGImage(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
