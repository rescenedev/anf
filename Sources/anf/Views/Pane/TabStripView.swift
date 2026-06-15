import SwiftUI

/// macOS Finder-style tab bar for one pane: equal-width segments that fill the
/// bar, a neutral rounded highlight on the active tab, centred names, hairline
/// separators between inactive tabs, and a New Tab (+) button at the trailing
/// edge. PaneView hides this entirely when a pane has a single tab (Finder
/// shows the bar only with 2+ tabs).
struct TabStripView: View {
    @Bindable var workspace: WorkspaceModel
    let index: Int

    private var pane: PaneModel { workspace.panes[index] }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { i, tab in
                // Hairline between adjacent tabs — but not on the edges touching
                // the active tab, whose highlight reads as the separator there.
                if i > 0 {
                    Divider()
                        .frame(height: 14)
                        .opacity(i == pane.activeIndex || i == pane.activeIndex + 1 ? 0 : 0.4)
                }
                TabChip(
                    title: title(tab),
                    active: i == pane.activeIndex,
                    closable: pane.tabs.count > 1,
                    locked: tab.isLocked,
                    onSelect: { workspace.focusPane(index); pane.select(i) },
                    onClose: { pane.closeTab(i) },
                    onToggleLock: { tab.toggleLock() }
                )
                .frame(maxWidth: .infinity)   // equal-width: tabs fill the bar
            }
            Button {
                workspace.focusPane(index); pane.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(L("New Tab (⌘T)", "새 탭 (⌘T)"))
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        // Match the column header / window surface (not the lighter `.bar`
        // material) so the toolbar → tabs → list header read as one continuous
        // piece instead of three stacked bands.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func title(_ tab: BrowserModel) -> String {
        BrowserModel.tabTitle(current: tab.currentURL, locked: tab.lockedURL)
    }
}

private struct TabChip: View {
    let title: String
    let active: Bool
    let closable: Bool
    let locked: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onToggleLock: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack {
            // Finder's selected segment: a neutral (not accent) rounded fill,
            // slightly inset from the bar. Hover gets a fainter wash.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active ? Color.primary.opacity(0.12)
                             : (hovering ? Color.primary.opacity(0.05) : .clear))
                .padding(.vertical, 3)
                .padding(.horizontal, 2)

            // Centred name (no folder glyph, Finder-style); the lock pin stays.
            HStack(spacing: 4) {
                if locked {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(active ? .primary : .secondary)
            }
            .padding(.horizontal, 22)   // keep the title clear of the close button

            // Close (×) on the LEFT, shown on hover/active — the Finder placement.
            if closable && (hovering || active) {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help(L("Close Tab", "탭 닫기"))
                    Spacer(minLength: 0)
                }
                .padding(.leading, 6)
            }
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(locked ? L("Unlock Tab", "탭 고정 해제")
                          : L("Lock Tab to This Folder", "이 폴더에 탭 고정"),
                   action: onToggleLock)
        }
    }
}
