import SwiftUI

/// Reusable square toolbar icon button (Finder-style, borderless).
struct ToolbarIconButton: View {
    let symbol: String
    var help: String = ""
    var enabled: Bool = true
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(tint ?? (enabled ? Color.primary : Color.secondary.opacity(0.4)))
        .disabled(!enabled)
        .help(help)
    }
}

/// Left cluster of the window toolbar: sidebar toggle, history, view + layout switchers.
struct ToolbarLeadingView: View {
    @Bindable var workspace: WorkspaceModel
    private var model: BrowserModel { workspace.active }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ToolbarIconButton(symbol: "chevron.left", help: "Back (⌘[)", enabled: model.canGoBack) { model.goBack() }
                ToolbarIconButton(symbol: "chevron.right", help: "Forward (⌘])", enabled: model.canGoForward) { model.goForward() }
                ToolbarIconButton(symbol: "chevron.up", help: "Enclosing Folder (⌘↑)", enabled: model.canGoUp) { model.goUp() }
            }
            Picker("", selection: Binding(get: { model.viewMode }, set: { model.viewMode = $0 })) {
                ForEach(ViewMode.allCases) { Image(systemName: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150)

            Picker("", selection: Binding(get: { workspace.layout }, set: { workspace.setLayout($0) })) {
                ForEach(PaneLayout.allCases) { Image(systemName: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 140).help("Pane Layout")
        }
        .padding(.horizontal, 6)
        .fixedSize()
    }
}

/// Right cluster of the window toolbar: favorite, arrange/options, new tab/folder,
/// trash, info, and the search/filter field.
struct ToolbarTrailingView: View {
    @Bindable var workspace: WorkspaceModel
    private var model: BrowserModel { workspace.active }

    var body: some View {
        HStack(spacing: 8) {
            let on = workspace.favorites.contains(model.currentURL)
            ToolbarIconButton(symbol: on ? "star.fill" : "star",
                              help: "Favorite this Folder (⌘⇧D)",
                              tint: on ? .yellow : nil) {
                workspace.toggleFavoriteCurrent()
            }

            optionsMenu

            ToolbarIconButton(symbol: "plus.square.on.square", help: "New Tab (⌘T)") {
                workspace.activePaneModel.newTab()
            }
            ToolbarIconButton(symbol: "folder.badge.plus", help: "New Folder (⌘⇧N)") {
                model.makeNewFolder()
            }
            ToolbarIconButton(symbol: "trash", help: "Move to Trash (⌘⌫)", enabled: !model.selection.isEmpty) {
                model.trashSelection()
            }
            ToolbarIconButton(symbol: "macwindow", help: "현재 레이아웃을 Workspace로 저장") {
                if let name = TextPrompt.run(title: "Workspace 저장",
                                             message: "현재 pane 레이아웃과 탭을 이 이름으로 저장합니다.",
                                             defaultValue: "", action: "저장") {
                    workspace.saveCurrentView(name: name)
                }
            }
            ToolbarIconButton(symbol: "terminal", help: "Terminal (⌃`)") {
                workspace.toggleTerminal()
            }
            ToolbarIconButton(symbol: "sidebar.trailing", help: "Info (⌘I)") {
                workspace.inspectorVisible.toggle()
            }

            searchField
        }
        .padding(.horizontal, 6)
        .fixedSize()
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Sort by", selection: Binding(get: { model.sort.key }, set: { model.sort.key = $0 })) {
                ForEach(SortKey.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Ascending", isOn: Binding(get: { model.sort.ascending }, set: { model.sort.ascending = $0 }))
            Divider()
            Toggle("Show Hidden Files", isOn: Binding(get: { model.showHidden }, set: { model.showHidden = $0 }))
            if model.viewMode == .icons {
                Divider()
                Text("Icon Size")
                Slider(value: Binding(get: { model.iconSize }, set: { model.iconSize = $0 }), in: 48...160)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 13))
        }
        .menuStyle(.borderlessButton).fixedSize().help("Sort & Options")
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search", text: Binding(get: { model.filterText }, set: { model.filterText = $0 }))
                .textFieldStyle(.plain).frame(width: 120)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(.quaternary))
    }
}
