import SwiftUI

/// Breadcrumb trail at the bottom edge. Each component is clickable; the current
/// folder is emphasised. A trailing status segment shows counts/selection.
///
/// The bar doubles as an inline path editor (issue #14): ⌘L, the "Go to Folder"
/// action, or a click on the empty area swaps the crumbs for a focused text
/// field pre-filled with the current path. Return navigates; Escape cancels.
struct PathBarView: View {
    let model: BrowserModel
    /// Called before navigating so clicking a crumb also focuses the owning pane
    /// (the pane-focus gesture is intentionally kept off the path bar).
    var onFocus: (() -> Void)? = nil

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Group {
            if editing {
                editor
            } else {
                breadcrumbs
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
        // ⌘L / "Go to Folder" bumps this counter — begin (or restart) editing.
        .onChange(of: model.pathEditRequests) { _, _ in beginEditing() }
        // If the folder changes out from under an open editor (navigation from a
        // crumb click, sidebar, etc.), drop the stale draft.
        .onChange(of: model.currentURL) { _, _ in if editing { endEditing() } }
    }

    // MARK: Breadcrumbs (default)

    private var breadcrumbs: some View {
        let comps = model.pathComponents
        return HStack(spacing: 2) {
            ForEach(Array(comps.enumerated()), id: \.element) { idx, url in
                if idx > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    onFocus?()
                    model.navigate(to: url)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: idx == 0 ? "macwindow" : "folder")
                            .font(.system(size: 10))
                        Text(label(url))
                    }
                    .font(.system(size: 11, weight: idx == comps.count - 1 ? .semibold : .regular))
                    .foregroundStyle(idx == comps.count - 1 ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
            // The empty area is a click target that starts inline editing — a
            // discoverable mouse affordance alongside ⌘L.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onFocus?(); beginEditing() }
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help(L("Edit path (⌘L)", "경로 편집 (⌘L)"))
        }
    }

    // MARK: Inline editor

    private var editor: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField(L("Enter or paste a path", "경로를 입력하거나 붙여넣기"), text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($fieldFocused)
                .onSubmit { commit() }
                // Escape cancels and restores the breadcrumbs.
                .onExitCommand { endEditing() }
            Button { endEditing() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(L("Cancel (Esc)", "취소 (Esc)"))
        }
    }

    // MARK: Actions

    private func beginEditing() {
        draft = model.currentURL.path
        editing = true
        fieldFocused = true
    }

    private func endEditing() {
        editing = false
        fieldFocused = false
    }

    private func commit() {
        let path = draft
        endEditing()
        model.navigateToTypedPath(path)
    }

    private func label(_ url: URL) -> String {
        BrowserModel.displayName(for: url)
    }

    private var status: String {
        let total = model.items.count
        let sel = model.selection.count
        if sel > 0 {
            let bytes = model.selectedItems.reduce(Int64(0)) { $0 + $1.size }
            return L("\(sel) of \(total) selected · \(Format.bytes(bytes))", "\(total)개 중 \(sel)개 선택됨 · \(Format.bytes(bytes))")
        }
        let items = L("\(total) item\(total == 1 ? "" : "s")", "\(total)개 항목")
        let free = model.freeSpaceLabel
        return free.isEmpty ? items : "\(items)  ·  \(free)"
    }
}
