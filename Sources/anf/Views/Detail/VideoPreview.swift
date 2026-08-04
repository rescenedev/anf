import SwiftUI
import AVKit

/// Native video surface for AVFoundation-friendly containers (#103: "영상파일을
/// 뷰어로 열었을때 자동 플레이"). AVPlayerView brings real inline controls and
/// an autoplay we control — the Quick Look surface offers neither. Exotic
/// containers AVFoundation can't open (mkv 등) stay on the QL route, where
/// third-party QL extensions can render them.
struct VideoPreview: NSViewRepresentable {
    let url: URL
    var autoplay = false

    static let exts: Set<String> = ["mp4", "mov", "m4v"]
    static func isNativeVideo(_ item: FileItem) -> Bool { exts.contains(item.ext) }

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .inline
        v.showsFullScreenToggleButton = true
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if (v.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            let p = AVPlayer(url: url)
            v.player = p
            if autoplay { p.play() }
        }
    }

    // Same lesson as the popup's audio (#119): waiting for deinit leaves the
    // player running after the hosting view is dropped.
    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) {
        v.player?.pause()
        v.player = nil
    }
}
