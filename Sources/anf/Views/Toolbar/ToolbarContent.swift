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

/// A segmented picker folded down to a single borderless menu button — same
/// choices, ~28pt instead of ~150pt, for when the window is too narrow (#93).
private struct ToolbarPickerMenu<Value: Hashable & Identifiable & CaseIterable>: View
where Value.AllCases: RandomAccessCollection {
    let symbol: String
    let help: String
    let title: (Value) -> String
    let itemSymbol: (Value) -> String
    @Binding var selection: Value

    var body: some View {
        Menu {
            ForEach(Value.allCases) { value in
                Button { selection = value } label: {
                    Label(title(value), systemImage: itemSymbol(value))
                }
            }
        } label: {
            Image(systemName: symbol).font(.system(size: 13))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(help)
    }
}

/// Left cluster of the window toolbar: sidebar toggle, history, view + layout switchers.
struct ToolbarLeadingView: View {
    @Bindable var workspace: WorkspaceModel
    var density: ToolbarDensity = .full
    private var model: BrowserModel { workspace.active }

    private var viewModeBinding: Binding<ViewMode> {
        Binding(get: { model.viewMode }, set: { model.viewMode = $0 })
    }
    private var layoutBinding: Binding<PaneLayout> {
        Binding(get: { workspace.layout }, set: { workspace.setLayout($0) })
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ToolbarIconButton(symbol: "chevron.left", help: L("Back (⌘[)", "뒤로 (⌘[)"), enabled: model.canGoBack) { model.goBack() }
                ToolbarIconButton(symbol: "chevron.right", help: L("Forward (⌘])", "앞으로 (⌘])"), enabled: model.canGoForward) { model.goForward() }
                ToolbarIconButton(symbol: "chevron.up", help: L("Enclosing Folder (⌘↑)", "상위 폴더 (⌘↑)"), enabled: model.canGoUp) { model.goUp() }
            }
            let viewHelp = L("View Mode (⌘[ / ⌘])", "보기 형태 (⌘[ / ⌘])")
            if density == .minimal {
                ToolbarPickerMenu(symbol: model.viewMode.symbol, help: viewHelp,
                                  title: \.title, itemSymbol: \.symbol, selection: viewModeBinding)
            } else {
                Picker("", selection: viewModeBinding) {
                    ForEach(ViewMode.allCases) { Image(systemName: $0.symbol).tag($0).help($0.title) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                .help(viewHelp)
            }

            let layoutHelp = L("Pane Layout (⌘1–4)", "창 분할 (⌘1–4)")
            if density == .full {
                Picker("", selection: layoutBinding) {
                    ForEach(PaneLayout.allCases) { Image(systemName: $0.symbol).tag($0).help($0.title) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 140)
                .help(layoutHelp)
            } else {
                ToolbarPickerMenu(symbol: workspace.layout.symbol, help: layoutHelp,
                                  title: \.title, itemSymbol: \.symbol, selection: layoutBinding)
            }
        }
        .padding(.horizontal, 6)
        .fixedSize()
    }
}

/// Right cluster of the window toolbar: favorite, arrange/options, new tab/folder,
/// trash, info, and the search/filter field.
struct ToolbarTrailingView: View {
    @Bindable var workspace: WorkspaceModel
    var density: ToolbarDensity = .full
    private var model: BrowserModel { workspace.active }

    /// True when the pane layout is split — see the comment on the button.
    private var showsWorkspaceSave: Bool { workspace.layout != .single }

    var body: some View {
        HStack(spacing: 8) {
            let on = workspace.favorites.contains(model.currentURL)
            ToolbarIconButton(symbol: on ? "star.fill" : "star",
                              help: L("Pin This Folder (⌘⇧D)", "현재 폴더 핀 (⌘⇧D)"),
                              tint: on ? .yellow : nil) {
                workspace.toggleFavoriteCurrent()
            }

            optionsMenu

            // At .minimal these four live in the options menu instead, so the
            // cluster still fits and nothing becomes unreachable.
            if density != .minimal {
                ToolbarIconButton(symbol: "plus.square.on.square", help: L("New Tab (⌘T)", "새 탭 (⌘T)")) {
                    newTab()
                }
                ToolbarIconButton(symbol: "folder.badge.plus", help: L("New Folder (⌘⇧N)", "새 폴더 (⌘⇧N)")) {
                    model.makeNewFolder()
                }
            }
            ToolbarIconButton(symbol: "trash", help: L("Move to Trash (⌘⌫)", "휴지통으로 (⌘⌫)"), enabled: !model.selection.isEmpty) {
                model.trashSelection()
            }
            if density != .minimal {
                // Workspaces capture multi-pane layouts; a single pane is just a
                // folder — pin it instead, so the star is the only affordance.
                if showsWorkspaceSave {
                    ToolbarIconButton(symbol: "macwindow", help: L("Save Layout as Workspace", "현재 레이아웃을 Workspace로 저장")) {
                        saveWorkspace()
                    }
                }
                ToolbarIconButton(symbol: "terminal", help: L("Terminal for this folder (⌃`)", "이 폴더의 터미널 (⌃`)")) {
                    workspace.openTerminalForActiveFolder()
                }
            }
            ToolbarIconButton(symbol: "sidebar.trailing", help: L("Inspector (⌘I)", "인스펙터 (⌘I)")) {
                workspace.inspectorVisible.toggle()
            }

            searchField
        }
        .padding(.horizontal, 6)
        .fixedSize()
    }

    private func newTab() { workspace.activePaneModel.newTab() }

    private func saveWorkspace() {
        if let name = TextPrompt.run(title: L("Save Workspace", "Workspace 저장"),
                                     message: L("Saves the current pane layout and tabs under this name.", "현재 pane 레이아웃과 탭을 이 이름으로 저장합니다."),
                                     defaultValue: "", action: L("Save", "저장")) {
            workspace.saveCurrentView(name: name)
        }
    }

    private var optionsMenu: some View {
        Menu {
            if density == .minimal {
                Button(L("New Tab (⌘T)", "새 탭 (⌘T)"), systemImage: "plus.square.on.square") { newTab() }
                Button(L("New Folder (⌘⇧N)", "새 폴더 (⌘⇧N)"), systemImage: "folder.badge.plus") { model.makeNewFolder() }
                Button(L("Terminal for this folder (⌃`)", "이 폴더의 터미널 (⌃`)"), systemImage: "terminal") {
                    workspace.openTerminalForActiveFolder()
                }
                if showsWorkspaceSave {
                    Button(L("Save Layout as Workspace", "현재 레이아웃을 Workspace로 저장"), systemImage: "macwindow") {
                        saveWorkspace()
                    }
                }
                Divider()
            }
            Picker(L("Sort By", "정렬 기준"), selection: Binding(get: { model.sort.key }, set: { model.sort.key = $0 })) {
                ForEach(SortKey.allCases) { Text($0.title).tag($0) }
            }
            Toggle(L("Ascending", "오름차순"), isOn: Binding(get: { model.sort.ascending }, set: { model.sort.ascending = $0 }))
            Picker(L("Arrange By", "그룹 기준"), selection: Binding(get: { model.groupKey }, set: { model.groupKey = $0 })) {
                ForEach(GroupKey.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Toggle(L("Show Hidden Files", "숨김 파일 보기"), isOn: Binding(get: { model.showHidden }, set: { model.showHidden = $0 }))
            Toggle(L("Show Status Bar", "상태 막대 보기"), isOn: Binding(get: { workspace.pathBarVisible },
                                              set: { workspace.pathBarVisible = $0; workspace.save() }))
            if model.viewMode == .icons {
                Divider()
                Text(L("Icon Size", "아이콘 크기"))
                Slider(value: Binding(get: { model.iconSize }, set: { model.iconSize = $0 }), in: 48...160)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 13))
        }
        .menuStyle(.borderlessButton).fixedSize().help(L("Sort & Options", "정렬 · 옵션"))
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(L("Filter", "필터"), text: Binding(get: { model.filterText }, set: { model.filterText = $0 }))
                .textFieldStyle(.plain)
                .frame(width: density == .full ? ToolbarWidths.searchFull : ToolbarWidths.searchCompact)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(.quaternary))
        .help(L("Filter the current folder by name", "현재 폴더를 이름으로 필터"))
    }
}
