import SwiftUI
import AppKit

/// A real `NSVisualEffectView` background. With `.behindWindow` blending and a
/// non-opaque window, this blurs the **desktop behind** the window (true macOS
/// translucency), not just content within the window.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    /// 0 = fully translucent, 1 = opaque tint on top (to dial back the see-through).
    var tint: Double = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}
