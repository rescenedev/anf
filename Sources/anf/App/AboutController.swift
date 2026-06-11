import AppKit

/// Shows the standard About panel with clickable GitHub / feedback / sponsor links
/// in the credits area.
@MainActor
final class AboutController: NSObject {
    static let shared = AboutController()

    @objc func show(_ sender: Any?) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 5

        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .paragraphStyle: para,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(
            string: L("A fast, light native file browser for macOS\n\n", "macOS를 위한 가볍고 빠른 네이티브 파일 브라우저\n\n"), attributes: base))

        func link(_ text: String, _ url: String) {
            var attrs = base
            attrs[.link] = url
            credits.append(NSAttributedString(string: text + "\n", attributes: attrs))
        }
        link("GitHub", "https://github.com/rescenedev/anf")
        link(L("Ideas · feedback · bug reports (tellme@duck.com)", "아이디어 · 개선 의견 · 버그 제보 (tellme@duck.com)"),
             "mailto:tellme@duck.com?subject=anf%20피드백")
        link(L("Sponsor", "후원하기"), "https://fairy.hada.io/@lumen")

        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}
