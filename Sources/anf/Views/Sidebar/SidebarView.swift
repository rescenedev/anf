import SwiftUI

/// Source list: built-in Favorites, user-pinned folders, and mounted Locations.
/// Clicking navigates the active pane's active tab. Selection is drawn explicitly
/// so it stays visible regardless of keyboard focus.
struct SidebarView: View {
    @Bindable var workspace: WorkspaceModel
    @State private var builtins = SidebarBuilder.favorites()
    @State private var locations: [SidebarItem] = []
    @State private var sshHosts: [SSHHost] = []

    // Drawer state per section, remembered across launches.
    @AppStorage("anf.sidebar.open.favorites") private var openFavorites = true
    @AppStorage("anf.sidebar.open.pinned") private var openPinned = true
    @AppStorage("anf.sidebar.open.views") private var openViews = true
    @AppStorage("anf.sidebar.open.locations") private var openLocations = true
    @AppStorage("anf.sidebar.open.ssh") private var openSSH = true
    @State private var renamingView: SavedView?
    @State private var renameText = ""

    private var model: BrowserModel { workspace.active }

    /// `~/.ssh/config` hosts plus user-added (+ button) targets, de-duplicated.
    /// Tuple: (display SSHHost, CustomSSHHost if user-added else nil)
    private var allSSHHosts: [(SSHHost, CustomSSHHost?)] {
        var seen = Set<String>()
        var merged: [(SSHHost, CustomSSHHost?)] = sshHosts.compactMap { host in
            seen.insert(host.alias).inserted ? (host, nil) : nil
        }
        for custom in workspace.customSSH.hosts where seen.insert(custom.target).inserted {
            merged.append((SSHHost(alias: custom.target, hostName: custom.host), custom))
        }
        return merged
    }

    var body: some View {
        List {
            Section {
                if openFavorites {
                    ForEach(builtins) { row(name: $0.name, symbol: $0.symbol, url: $0.url, removable: false) }
                }
            } header: {
                sectionHeader("Favorites", isOpen: $openFavorites)
            }
            if !workspace.favorites.items.isEmpty {
                Section {
                    if openPinned {
                        ForEach(workspace.favorites.items, id: \.self) { url in
                            row(name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                                symbol: "star.fill", url: url, removable: true)
                        }
                    }
                } header: {
                    sectionHeader("Pinned", isOpen: $openPinned)
                }
            }
            if !workspace.savedViews.views.isEmpty {
                Section {
                    if openViews {
                        ForEach(workspace.savedViews.views) { viewRow($0) }
                    }
                } header: {
                    sectionHeader("Workspace", isOpen: $openViews)
                }
            }
            if !locations.isEmpty {
                Section {
                    if openLocations {
                        ForEach(locations) { row(name: $0.name, symbol: $0.symbol, url: $0.url, removable: false) }
                    }
                } header: {
                    sectionHeader("Locations", isOpen: $openLocations)
                }
            }
            Section {
                if openSSH {
                    ForEach(allSSHHosts, id: \.0.id) { (sshHost, customData) in
                        sshRow(sshHost, customData: customData)
                    }
                }
            } header: {
                sectionHeader("SSH", isOpen: $openSSH) {
                    // NOTE: accessory is placed OUTSIDE the toggle button so tapping
                    // it never accidentally collapses/expands the section.
                    Button { addSSHHost() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("SSH Host 추가")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 24)
        .task {
            locations = await Task.detached(priority: .utility) { SidebarBuilder.locations() }.value
            sshHosts = await Task.detached(priority: .utility) { SSHConfig.hosts() }.value
        }
        .alert("Workspace 이름 변경", isPresented: Binding(
            get: { renamingView != nil },
            set: { if !$0 { renamingView = nil } })) {
            TextField("이름", text: $renameText)
            Button("취소", role: .cancel) { renamingView = nil }
            Button("저장") {
                if let v = renamingView { workspace.savedViews.rename(id: v.id, to: renameText) }
                renamingView = nil
            }
        }
    }

    /// Drawer-style section header: the title + chevron area is a Button (toggle),
    /// and any accessory (like "+") sits to the right as a *separate* tappable
    /// target — so tapping the accessory never fires the toggle.
    private func sectionHeader(_ title: String, isOpen: Binding<Bool>,
                               @ViewBuilder accessory: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isOpen.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                    Image(systemName: isOpen.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            accessory().padding(.trailing, 6)
        }
    }

    private func addSSHHost() {
        guard let custom = SSHPrompt.run() else { return }
        workspace.customSSH.add(custom)
    }

    /// A saved window arrangement. Tap recalls it; the context menu updates,
    /// renames or deletes it. The icon mirrors the layout it captured.
    private func viewRow(_ view: SavedView) -> some View {
        let symbol = PaneLayout(rawValue: view.snapshot.layout)?.symbol ?? "square.grid.2x2"
        let selected = workspace.activeViewID == view.id
        return Label {
            Text(view.name).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(1)
        } icon: {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Color.accentColor)
        }
            .padding(.vertical, 2)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.12) : .clear)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { workspace.applyView(view) }
            .contextMenu {
                Button("이 레이아웃으로 전환") { workspace.applyView(view) }
                Button("현재 레이아웃으로 덮어쓰기") {
                    workspace.savedViews.update(id: view.id, snapshot: workspace.captureSnapshot())
                }
                Button("이름 변경…") { renameText = view.name; renamingView = view }
                Divider()
                Button("삭제", role: .destructive) { workspace.savedViews.remove(id: view.id) }
            }
    }

    private func row(name: String, symbol: String, url: URL, removable: Bool) -> some View {
        // A folder row highlights only when no Workspace is the active sidebar
        // selection — so a folder and a Workspace pointing at the same path never
        // both light up. Clicking a folder clears the Workspace selection.
        let selected = workspace.activeViewID == nil
            && url.standardizedFileURL.path == model.currentURL.standardizedFileURL.path
        return Label {
            Text(name).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(1)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
        }
            .padding(.vertical, 2)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.12) : .clear)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { workspace.activeViewID = nil; model.navigate(to: url) }
            .contextMenu {
                Button("Open in New Tab") { workspace.activePaneModel.newTab(at: url) }
                if removable {
                    Divider()
                    Button("Remove from Sidebar", role: .destructive) { workspace.favorites.remove(url) }
                }
            }
            .onDrag { NSItemProvider(object: url as NSURL) }
    }

    private func sshRow(_ host: SSHHost, customData: CustomSSHHost?) -> some View {
        let session = workspace.terminal?.sshHost == host.alias ? workspace.terminal : nil
        let connected = session?.isRunning == true
        let selected = workspace.showTerminal && workspace.terminal?.sshHost == host.alias
        return HStack(spacing: 0) {
            Label {
                Text(host.alias).font(.system(size: 13)).lineLimit(1)
            } icon: {
                Image(systemName: "terminal").foregroundStyle(.green)
            }
            Spacer(minLength: 4)
            if connected {
                Circle().fill(.green).frame(width: 7, height: 7).help("연결됨")
            } else if session != nil {
                Circle().fill(.secondary.opacity(0.5)).frame(width: 7, height: 7).help("연결 끊김")
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.12) : .clear)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let custom = customData {
                workspace.openSSH(custom)
            } else {
                workspace.openSSH(host.alias)
            }
        }
        .help("ssh \(host.subtitle)")
        .contextMenu {
            if let custom = customData {
                Button("SFTP로 열기") { workspace.openRemote(custom.target) }
                Button("Connect in anf") { workspace.openSSH(custom) }
                Button("SFTP (터미널)") { workspace.openSFTP(custom.target) }
                Button("SFTP 마운트해서 열기") { workspace.mountSFTP(custom.target) }
                Button("Connect with Ghostty") { TerminalLauncher.ssh(custom.target) }
                Divider()
                Button("Remove from Sidebar", role: .destructive) {
                    workspace.customSSH.remove(target: host.alias)
                }
            } else {
                Button("SFTP로 열기") { workspace.openRemote(host.alias) }
                Button("Connect in anf") { workspace.openSSH(host.alias) }
                Button("SFTP (터미널)") { workspace.openSFTP(host.alias) }
                Button("SFTP 마운트해서 열기") { workspace.mountSFTP(host.alias) }
                Button("Connect with Ghostty") { TerminalLauncher.ssh(host.alias) }
            }
        }
    }
}
