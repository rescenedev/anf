import SwiftUI

/// Inspector preview for images: the Quick Look picture on top, and — when the
/// on-device OCR finds any — a selectable "text in image" panel below. The OCR
/// runs off-main and shares OCRTextCache with ⌘K search, so opening an image you
/// already searched is instant.
struct ImagePreview: View {
    let url: URL
    var fontSize: CGFloat = 14

    @State private var ocr: String?
    @State private var scanned = false

    var body: some View {
        VStack(spacing: 0) {
            QuickLookView(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let ocr, !ocr.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Label(L("Text in image", "이미지 속 텍스트"), systemImage: "text.viewfinder")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(ocr)
                            .font(.system(size: fontSize - 1))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 170)
                }
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: url) {
            ocr = nil; scanned = false
            let target = url
            let text = await Task.detached(priority: .userInitiated) {
                OCRTextCache.shared.text(for: target)
            }.value
            withAnimation(.easeOut(duration: 0.15)) { ocr = text }
            scanned = true
        }
    }
}
