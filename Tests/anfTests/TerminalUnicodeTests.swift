import Foundation

/// Regression test for issue #9: emoji rendered by powerlevel10k appear
/// garbled in the embedded xterm.js terminal.
///
/// Root cause: xterm.js defaults to Unicode 6 wide-char tables, which
/// classify many modern emoji as 1-column wide.  Powerlevel10k expects
/// them to occupy 2 columns, so the cursor misaligns.  The fix registers
/// a Unicode 11 provider (via xterm.js's proposed unicode API) that has
/// the correct double-width designations for emoji.
func runTerminalUnicodeTests() {
    T.group("terminal.html unicode11 configuration") {
        let html = try String(
            contentsOfFile: "Sources/anf/Resources/xterm/terminal.html",
            encoding: .utf8
        )
        T.expect(
            html.contains("allowProposedApi: true"),
            "Terminal must set allowProposedApi:true so term.unicode is accessible"
        )
        T.expect(
            html.contains("term.unicode.register"),
            "terminal.html must register a Unicode 11 width provider"
        )
        T.expect(
            html.contains("activeVersion = '11'"),
            "terminal.html must activate the Unicode 11 provider"
        )
    }

    T.group("unicode11 wcwidth correctness") {
        // Verify the binary-search table in terminal.html produces correct
        // widths for characters that tripped up powerlevel10k.  We mirror
        // the same JS logic in Swift so the test runs offline without WebKit.
        T.expect(wcwidth11(0x1F4C1) == 2, "📁 FILE FOLDER must be 2-wide")
        T.expect(wcwidth11(0x1F40D) == 2, "🐍 SNAKE must be 2-wide")
        T.expect(wcwidth11(0x1F511) == 2, "🔑 KEY must be 2-wide")
        T.expect(wcwidth11(0x1F680) == 2, "🚀 ROCKET must be 2-wide")
        T.expect(wcwidth11(0x26A1)  == 2, "⚡ HIGH VOLTAGE must be 2-wide")
        T.expect(wcwidth11(0x2728)  == 2, "✨ SPARKLES must be 2-wide")
        T.expect(wcwidth11(0x2714)  == 2, "✔ HEAVY CHECK MARK must be 2-wide")
        T.expect(wcwidth11(0x1F33F) == 2, "🌿 HERB must be 2-wide")
        T.expect(wcwidth11(0x1FA70) == 2, "🩰 (U+1FA70) must be 2-wide")
        // ASCII and control chars must remain 1-wide / 0-wide
        T.expect(wcwidth11(0x41)  == 1, "ASCII 'A' is 1-wide")
        T.expect(wcwidth11(0x09)  == 0, "tab control char is 0-wide")
        T.expect(wcwidth11(0x1B)  == 0, "ESC control char is 0-wide")
    }
}

/// Swift mirror of the wcwidth function registered in terminal.html.
/// Must stay in sync with the JavaScript implementation.
private func wcwidth11(_ ucs: Int) -> Int {
    if ucs < 0x20 || (ucs >= 0x7f && ucs < 0xa0) { return 0 }
    let W: [Int] = [
        0x1100,0x115f, 0x231a,0x231b, 0x2329,0x232a, 0x23e9,0x23f3,
        0x23f8,0x23fa, 0x25aa,0x25ab, 0x25b6,0x25b6, 0x25c0,0x25c0,
        0x25fb,0x25fe, 0x2600,0x2604, 0x260e,0x260e, 0x2611,0x2611,
        0x2614,0x2615, 0x2618,0x2618, 0x261d,0x261d, 0x2620,0x2620,
        0x2622,0x2623, 0x2626,0x2626, 0x262a,0x262a, 0x262e,0x262f,
        0x2638,0x263a, 0x2640,0x2640, 0x2642,0x2642, 0x2648,0x2653,
        0x265f,0x2660, 0x2663,0x2663, 0x2665,0x2666, 0x2668,0x2668,
        0x267b,0x267b, 0x267e,0x267f, 0x2692,0x2697, 0x2699,0x2699,
        0x269b,0x269c, 0x26a0,0x26a1, 0x26aa,0x26ab, 0x26b0,0x26b1,
        0x26bd,0x26be, 0x26c4,0x26c5, 0x26ce,0x26cf, 0x26d1,0x26d1,
        0x26d3,0x26d4, 0x26e9,0x26ea, 0x26f0,0x26f5, 0x26f7,0x26fa,
        0x26fd,0x26fd, 0x2702,0x2702, 0x2705,0x2705, 0x2708,0x270d,
        0x270f,0x270f, 0x2712,0x2712, 0x2714,0x2714, 0x2716,0x2716,
        0x271d,0x271d, 0x2721,0x2721, 0x2728,0x2728, 0x2733,0x2734,
        0x2744,0x2744, 0x2747,0x2747, 0x274c,0x274c, 0x274e,0x274e,
        0x2753,0x2755, 0x2757,0x2757, 0x2763,0x2764, 0x2795,0x2797,
        0x27a1,0x27a1, 0x27b0,0x27b0, 0x27bf,0x27bf, 0x2934,0x2935,
        0x2b05,0x2b07, 0x2b1b,0x2b1c, 0x2b50,0x2b50, 0x2b55,0x2b55,
        0x2e80,0x303e, 0x3041,0xa4cf, 0xa960,0xa97f, 0xac00,0xd7ff,
        0xf900,0xfaff, 0xfe10,0xfe1f, 0xfe30,0xfe4f, 0xff01,0xff60,
        0xffe0,0xffe6,
        0x16fe0,0x16fe3, 0x17000,0x18aff, 0x1b000,0x1b12f, 0x1b170,0x1b2ff,
        0x1f004,0x1f004, 0x1f0cf,0x1f0cf, 0x1f18e,0x1f18e, 0x1f191,0x1f19a,
        0x1f1e6,0x1f1ff, 0x1f201,0x1f202, 0x1f21a,0x1f21a, 0x1f22f,0x1f22f,
        0x1f232,0x1f23a, 0x1f250,0x1f251,
        0x1f300,0x1f64f, 0x1f680,0x1f6ff,
        0x1f700,0x1f77f, 0x1f780,0x1f7ff, 0x1f800,0x1f8ff,
        0x1f900,0x1f9ff, 0x1fa00,0x1fa6f, 0x1fa70,0x1faff,
        0x20000,0x2fffd, 0x30000,0x3fffd,
    ]
    var lo = 0, hi = (W.count / 2) - 1
    while lo <= hi {
        let mid = (lo + hi) / 2
        if ucs < W[mid * 2] { hi = mid - 1 }
        else if ucs > W[mid * 2 + 1] { lo = mid + 1 }
        else { return 2 }
    }
    return 1
}
