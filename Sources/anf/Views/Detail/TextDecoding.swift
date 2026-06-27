import Foundation

/// Decode a text file's bytes into a String by DETECTING the encoding instead of
/// assuming UTF-8. A Korean .txt/.md saved as CP949/EUC-KR or UTF-16 (common on
/// Windows, and for the app's Korean audience) decoded as raw UTF-8 became a wall
/// of U+FFFD replacement characters in the text/markdown previews.
///
/// Order: BOM'd UTF-16 → strict UTF-8 (tolerating a multibyte char cut off by the
/// preview byte cap) → legacy Korean CP949 → NSString heuristic → lossy UTF-8.
enum TextDecoding {
    static func string(from raw: Data) -> String {
        let data = Data(raw)   // normalize a possible slice to a 0-based buffer
        guard !data.isEmpty else { return "" }

        // 1) Explicit UTF-16 BOM.
        if data.count >= 2 {
            let b0 = data[0], b1 = data[1]
            if (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF),
               let s = String(data: data, encoding: .utf16) { return s }
        }
        // 2) Strict UTF-8, but tolerate the preview cap slicing through a trailing
        //    multibyte char — drop up to 3 trailing bytes before giving up, so a
        //    valid (merely truncated) UTF-8 file is NOT misrouted to CP949 below.
        for drop in 0...3 where data.count > drop {
            if let s = String(data: data.prefix(data.count - drop), encoding: .utf8) { return s }
        }
        // 3) Legacy Korean CP949 (a superset of EUC-KR) — the common Windows case.
        let cp949 = String.Encoding(rawValue:
            CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        if let s = String(data: data, encoding: cp949) { return s }
        // 4) Heuristic detection (BOM-less UTF-16, other code pages).
        var converted: NSString?
        let enc = NSString.stringEncoding(for: data, encodingOptions: nil,
                                          convertedString: &converted, usedLossyConversion: nil)
        if enc != 0, let converted { return converted as String }
        // 5) Last resort: lossy UTF-8, so something always shows.
        return String(decoding: data, as: UTF8.self)
    }
}
