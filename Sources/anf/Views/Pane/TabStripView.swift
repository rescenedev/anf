import SwiftUI

/// Horizontal tab bar for one pane: a chip per tab plus a New Tab button.
struct TabStripView: View {
    @Bindable var workspace: WorkspaceModel
    let index: Int

    private var pane: PaneModel { workspace.panes[index] }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { i, tab in
                    TabChip(
                        title: title(tab),
                        active: i == pane.activeIndex,
                        closable: pane.tabs.count > 1,
                        onSelect: { workspace.focusPane(index); pane.select(i) },
                        onClose: { pane.closeTab(i) }
                    )
                }
                Button {
                    workspace.focusPane(index); pane.newTab()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("New Tab (⌘T)")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 30)
        .background(.bar)
    }

    private func title(_ tab: BrowserModel) -> String {
        let name = tab.currentURL.lastPathComponent
        return name.isEmpty ? "/" : name
    }
}

private struct TabChip: View {
    let title: String
    let active: Bool
    let closable: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
            if closable && (hovering || active) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 13, height: 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .frame(maxWidth: 160)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Color.accentColor.opacity(0.22) : (hovering ? Color.primary.opacity(0.06) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}
