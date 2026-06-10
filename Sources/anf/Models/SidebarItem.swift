import Foundation
import AppKit

struct SidebarItem: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let url: URL

    init(name: String, symbol: String, url: URL) {
        self.id = url.path
        self.name = name
        self.symbol = symbol
        self.url = url
    }
}

struct SidebarSection: Identifiable {
    let id: String
    let title: String
    let items: [SidebarItem]
}

enum SidebarBuilder {
    static func favorites() -> [SidebarItem] {
        let fm = FileManager.default
        func dir(_ d: FileManager.SearchPathDirectory) -> URL? {
            fm.urls(for: d, in: .userDomainMask).first
        }
        var items: [SidebarItem] = []
        let home = fm.homeDirectoryForCurrentUser
        items.append(SidebarItem(name: "Home", symbol: "house", url: home))
        if let u = dir(.desktopDirectory)   { items.append(.init(name: "Desktop", symbol: "menubar.dock.rectangle", url: u)) }
        if let u = dir(.documentDirectory)  { items.append(.init(name: "Documents", symbol: "doc", url: u)) }
        if let u = dir(.downloadsDirectory) { items.append(.init(name: "Downloads", symbol: "arrow.down.circle", url: u)) }
        if let u = dir(.moviesDirectory)    { items.append(.init(name: "Movies", symbol: "film", url: u)) }
        if let u = dir(.musicDirectory)     { items.append(.init(name: "Music", symbol: "music.note", url: u)) }
        if let u = dir(.picturesDirectory)  { items.append(.init(name: "Pictures", symbol: "photo", url: u)) }
        items.append(SidebarItem(name: "Applications", symbol: "app.dashed", url: URL(fileURLWithPath: "/Applications")))
        return items
    }

    static func locations() -> [SidebarItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey, .volumeIsLocalKey]
        let vols = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                        options: [.skipHiddenVolumes]) ?? []
        return vols.compactMap { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.volumeIsBrowsable ?? false else { return nil }
            let name = v?.volumeName ?? url.lastPathComponent
            let local = v?.volumeIsLocal ?? true
            return SidebarItem(name: name, symbol: local ? "internaldrive" : "externaldrive.connected.to.line.below", url: url)
        }
    }
}
