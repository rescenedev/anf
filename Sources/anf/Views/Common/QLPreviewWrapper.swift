import AppKit
import Quartz

/// Hosts one reusable `QLPreviewView`. Quick Look computes the document zoom
/// when the item (re)loads — if that happens while our frame is still zero (a
/// SwiftUI representable mounts before layout) or the inspector is later
/// resized, wide pages (docx) render cropped. So: pin the preview's frame in
/// layout() and refresh the item (debounced) whenever the width changes, which
/// makes QL re-fit the page to the current width — always.
final class QLPreviewWrapper: NSView {
    private let preview = QLPreviewView(frame: .zero, style: .normal)!
    private var currentURL: URL?
    private var lastFitWidth: CGFloat = 0
    private var refreshWork: DispatchWorkItem?
    private var loadWork: DispatchWorkItem?
    private var lastLoad: Double = 0
    private var closed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        preview.shouldCloseWithWindow = false
        addSubview(preview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        preview.frame = bounds
        guard currentURL != nil, bounds.width > 1,
              abs(bounds.width - lastFitWidth) > 0.5 else { return }
        lastFitWidth = bounds.width
        // Debounced: a divider drag fires layout per frame; refresh once settled.
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.preview.refreshPreviewItem() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// All QLPreviewViews render in ONE per-app QuickLookUIService process.
    /// Feeding it every intermediate file during held-arrow-key navigation
    /// queues renders faster than it can finish them — the service bloats and
    /// goes Not Responding (#103 follow-up screenshot: 926 mach ports). So a
    /// lone selection loads instantly, but rapid successors coalesce: only the
    /// newest URL is handed over, at most once per pacing interval.
    func setURL(_ url: URL?) {
        guard url != currentURL, !closed else { return }
        currentURL = url
        loadWork?.cancel()
        let elapsed = Date.timeIntervalSinceReferenceDate - lastLoad
        guard let wait = QLLoadPacing.delay(sinceLastLoad: elapsed) else {
            apply(url)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.apply(self.currentURL)
        }
        loadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func apply(_ url: URL?) {
        lastLoad = Date.timeIntervalSinceReferenceDate
        lastFitWidth = bounds.width   // the load computes fit for the CURRENT width
        preview.previewItem = url.map { $0 as NSURL }
    }

    /// Deterministic release of the remote render connection. SwiftUI can keep
    /// a dismantled representable's NSView alive well past removal — waiting
    /// for deinit leaves orphaned preview items loaded in QuickLookUIService.
    func tearDown() {
        guard !closed else { return }
        closed = true
        refreshWork?.cancel()
        loadWork?.cancel()
        preview.close()
    }

    deinit {
        refreshWork?.cancel()
        loadWork?.cancel()
        if !closed { preview.close() }
    }
}

/// Pure pacing rule for `setURL` (tested): given the seconds since the last
/// hand-off to Quick Look, load now (nil) or defer by the returned delay.
enum QLLoadPacing {
    static let minInterval: Double = 0.25
    static func delay(sinceLastLoad elapsed: Double) -> Double? {
        elapsed >= minInterval ? nil : minInterval - max(elapsed, 0)
    }
}
