import SwiftUI
import AppKit

/// Bridges an `NSImage` (system icon / Quick Look thumbnail) into SwiftUI without
/// re-decoding. Used everywhere a file glyph is drawn.
struct IconImage: View {
    let image: NSImage
    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}

/// Native Quick Look preview surface for the inspector / gallery. Reuses one
/// `QLPreviewView` and just swaps the previewed URL.
struct QuickLookView: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> QLPreviewWrapper {
        QLPreviewWrapper()
    }

    func updateNSView(_ view: QLPreviewWrapper, context: Context) {
        view.setURL(url)
    }
}
