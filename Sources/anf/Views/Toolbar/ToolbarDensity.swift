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
    /// Everything inline, as designed.
    case full
    /// Segmented layout switcher folds into a menu; filter field shrinks.
    case compact
    /// View-mode switcher folds too; secondary actions move into the options menu.
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
    static let viewPicker: CGFloat = 150   // segmented view-mode switcher
    static let layoutPicker: CGFloat = 140 // segmented pane-layout switcher
    static let menuButton: CGFloat = 28    // a Picker folded into a borderless menu
    static let optionsMenu: CGFloat = 41   // sort/options menu incl. its chevron
    static let searchChrome: CGFloat = 33  // magnifier + spacing + capsule padding
    static let searchFull: CGFloat = 120
    static let searchCompact: CGFloat = 56

    /// One icon button plus the gap that precedes it.
    private static let slot = icon + gap

    static func leading(_ density: ToolbarDensity) -> CGFloat {
        let switcher = density == .minimal ? menuButton : viewPicker
        let layout = density == .full ? layoutPicker : menuButton
        return padding + navGroup + gap + switcher + gap + layout
    }

    /// Assumes the pane-layout is split, i.e. the "save workspace" button is
    /// present — the widest the cluster ever gets. Sizing for the narrower
    /// single-pane case would drop the cluster the moment the user splits.
    static func trailing(_ density: ToolbarDensity) -> CGFloat {
        let search = density == .full ? searchFull : searchCompact
        // star, options, trash, inspector, search are never folded away.
        let core = padding + icon + gap + optionsMenu + slot + slot
            + gap + searchChrome + search
        // new tab, new folder, terminal, save-workspace fold into the menu.
        return density == .minimal ? core : core + slot * 4
    }
}

extension ToolbarFit {
    /// Degradation ladder, least disruptive first: shrink the filter field, then
    /// fold the layout switcher, then the secondary actions, then the view-mode
    /// switcher. The first rung that fits wins; if nothing fits we still return
    /// the narrowest rung, because a squeezed toolbar beats a missing one.
    static let ladder: [ToolbarFit] = [
        ToolbarFit(leading: .full, trailing: .full),
        ToolbarFit(leading: .full, trailing: .compact),
        ToolbarFit(leading: .compact, trailing: .compact),
        ToolbarFit(leading: .compact, trailing: .minimal),
        ToolbarFit(leading: .minimal, trailing: .minimal),
    ]

    var requiredWidth: CGFloat {
        ToolbarWidths.leading(leading) + ToolbarWidths.trailing(trailing)
    }

    static func resolve(available: CGFloat) -> ToolbarFit {
        ladder.first { $0.requiredWidth <= available } ?? ladder[ladder.count - 1]
    }
}
