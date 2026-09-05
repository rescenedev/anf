import CoreGraphics

/// How much of the toolbar a cluster is allowed to spend.
///
/// The two clusters are single custom `NSToolbarItem`s wrapping SwiftUI. When
/// their combined width doesn't fit, AppKit doesn't overflow them — it silently
/// drops one (delegate still runs, frame still computed, but `view.window` stays
/// nil), so the user sees an empty toolbar half (#93). The fix is to never ask
/// for more than fits: the window feeds its available width to `ToolbarFit`,
/// which picks a density pair, and the views render a narrower variant.
enum ToolbarDensity: String, CaseIterable, Sendable {
    /// Labeled layout menu and full-width filter.
    case full
    /// Filter field shrinks, retaining the layout label.
    case compact
    /// Layout menu becomes icon-only and the filter uses its minimum width.
    case minimal
}

/// The density pair currently in effect.
struct ToolbarFit: Equatable, Sendable {
    let leading: ToolbarDensity
    let trailing: ToolbarDensity

    static let widest = ToolbarFit(leading: .full, trailing: .full)
}

/// Width bookkeeping for the two clusters.
///
/// The numbers are the SwiftUI views' own geometry, added up by hand — they have
/// to be known *before* rendering, so they can't be measured from the rendered
/// view. `ANF_TOOLBAR_PROBE=1 anf` prints the real fitting widths at every
/// density; if a cluster's contents change, re-run it and re-check these.
enum ToolbarWidths {
    static let icon: CGFloat = 28          // ToolbarIconButton
    static let gap: CGFloat = 8            // cluster HStack spacing
    static let padding: CGFloat = 12       // .padding(.horizontal, 6), both sides
    static let navGroup: CGFloat = 88      // back/forward/up at 2pt spacing
    static let layoutPicker: CGFloat = 112 // icon, current layout title, chevron
    static let menuButton: CGFloat = 28
    static let searchChrome: CGFloat = 33  // magnifier + spacing + field padding
    static let searchFull: CGFloat = 180
    static let searchCompact: CGFloat = 120
    static let searchMinimal: CGFloat = 56

    static func search(_ density: ToolbarDensity) -> CGFloat {
        switch density {
        case .full: searchFull
        case .compact: searchCompact
        case .minimal: searchMinimal
        }
    }

    static func leading(_ density: ToolbarDensity) -> CGFloat {
        let layout = density == .minimal ? menuButton : layoutPicker
        // Native menu chrome rounds the full cluster up by a few points.
        return padding + navGroup + gap + menuButton + gap + layout + 4
    }

    static func trailing(_ density: ToolbarDensity) -> CGFloat {
        // Filter, inspector, and More remain visible at every density. All
        // secondary commands live in More, independent of the pane layout.
        padding + searchChrome + search(density) + gap + icon + gap + menuButton
    }
}

extension ToolbarFit {
    /// Shrink the filter first, then collapse the layout label and shrink the
    /// filter to its minimum. Secondary actions remain in More at every width.
    static let ladder: [ToolbarFit] = [
        ToolbarFit(leading: .full, trailing: .full),
        ToolbarFit(leading: .full, trailing: .compact),
        ToolbarFit(leading: .minimal, trailing: .minimal),
    ]

    var requiredWidth: CGFloat {
        ToolbarWidths.leading(leading) + ToolbarWidths.trailing(trailing)
    }

    static func resolve(available: CGFloat) -> ToolbarFit {
        ladder.first { $0.requiredWidth <= available } ?? ladder[ladder.count - 1]
    }
}
