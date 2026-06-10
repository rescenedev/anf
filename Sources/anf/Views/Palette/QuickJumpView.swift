import SwiftUI

/// ⌘K / ⌘P command palette: fuzzy-filter favorites, the current folder's
/// contents, and (for 2+ character queries) a capped recursive search below the
/// current folder. Return navigates to a folder or reveals a file.
struct QuickJumpView: View {
    @Bindable var workspace: WorkspaceModel
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var selected = 0
    @State private var deepResults: [Target] = []

    struct Target: Identifiable {
        let id = UUID()
        let name: String
        let url: URL
        let symbol: String
        var isFile = false
    }

    private var candidates: [Target] {
        var all: [Target] = []
        for f in SidebarBuilder.favorites() { all.append(.init(name: f.name, url: f.url, symbol: f.symbol)) }
        for u in workspace.favorites.items {
            all.append(.init(name: u.lastPathComponent.isEmpty ? u.path : u.lastPathComponent, url: u, symbol: "star.fill"))
        }
        for item in workspace.active.items {
            all.append(.init(name: item.name, url: item.url,
                             symbol: item.isBrowsableContainer ? "folder" : "doc",
                             isFile: !item.isBrowsableContainer))
        }
        all.append(contentsOf: deepResults)
        // de-dup by path
        var seen = Set<String>()
        let unique = all.filter { seen.insert($0.url.path).inserted }
        guard !query.isEmpty else { return Array(unique.prefix(40)) }
        return unique.filter { $0.name.localizedCaseInsensitiveContains(query)
            || $0.url.path.localizedCaseInsensitiveContains(query) }
            .prefix(40).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search files & folders…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { go() }
                    .onChange(of: query) { _, _ in selected = 0 }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, candidates.count - 1); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .onKeyPress(.escape) { workspace.paletteVisible = false; return .handled }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { i, t in
                            HStack(spacing: 9) {
                                Image(systemName: t.symbol).frame(width: 18).foregroundStyle(.secondary)
                                Text(t.name)
                                Spacer()
                                Text(t.url.deletingLastPathComponent().path)
                                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(i == selected ? Color.accentColor.opacity(0.85) : .clear)
                            .foregroundStyle(i == selected ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .id(i)
                            .onTapGesture { selected = i; go() }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 320)
                .onChange(of: selected) { _, v in withAnimation { proxy.scrollTo(v) } }
            }
        }
        .frame(width: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .onAppear { focused = true; selected = 0 }
        .task(id: query) {
            // Recursive search below the current folder for real queries —
            // capped so a giant tree can't stall the palette.
            guard query.count >= 2 else { deepResults = []; return }
            let root = workspace.active.currentURL
            let needle = query
            let found = await Task.detached(priority: .userInitiated) { () -> [Target] in
                PaletteSearch.scan(root: root, needle: needle)
            }.value
            if !Task.isCancelled { deepResults = found }
        }
    }

    private func go() {
        let list = candidates
        guard list.indices.contains(selected) else { return }
        let target = list[selected]
        if target.isFile {
            workspace.active.revealFile(target.url)
        } else {
            workspace.active.navigate(to: target.url)
        }
        workspace.paletteVisible = false
        query = ""
    }
}

/// Bounded recursive filename search used by the palette.
enum PaletteSearch {
    static func scan(root: URL, needle: String, maxDepth: Int = 4, cap: Int = 120) -> [QuickJumpView.Target] {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var results: [QuickJumpView.Target] = []
        for case let url as URL in en {
            if en.level > maxDepth { en.skipDescendants(); continue }
            if Task.isCancelled || results.count >= cap { break }
            let name = url.lastPathComponent
            guard name.localizedCaseInsensitiveContains(needle) else { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            results.append(.init(name: name, url: url,
                                 symbol: isDir ? "folder" : "doc", isFile: !isDir))
        }
        return results
    }
}
