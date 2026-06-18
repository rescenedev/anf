import Foundation
import AppKit

struct SidebarItem: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let url: URL
    /// Removable/ejectable volume — shows an eject action in the context menu.
    var ejectable: Bool = false

    init(name: String, symbol: String, url: URL, ejectable: Bool = false) {
        self.id = url.path
        self.name = name
        self.symbol = symbol
        self.url = url
        self.ejectable = ejectable
    }
}

struct SidebarSection: Identifiable {
    let id: String
    let title: String
    let items: [SidebarItem]
}

enum SidebarBuilder {
    /// iCloud Drive's on-disk root under a home directory. The per-app ubiquity
    /// container API needs an entitlement and points elsewhere, so this fixed
    /// path is the correct one for the user's iCloud Drive.
    static func iCloudDriveURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    }

    static func favorites() -> [SidebarItem] {
        let fm = FileManager.default
        func dir(_ d: FileManager.SearchPathDirectory) -> URL? {
            fm.urls(for: d, in: .userDomainMask).first
        }
        var items: [SidebarItem] = []
        let home = fm.homeDirectoryForCurrentUser
        items.append(SidebarItem(name: L("Home", "홈"), symbol: "house", url: home))
        if let u = dir(.desktopDirectory)   { items.append(.init(name: L("Desktop", "데스크탑"), symbol: "menubar.dock.rectangle", url: u)) }
        if let u = dir(.documentDirectory)  { items.append(.init(name: L("Documents", "문서"), symbol: "doc", url: u)) }
        // iCloud Drive lives at a fixed path (the per-app ubiquity container API
        // needs an entitlement and returns the WRONG dir); show it only when the
        // user actually has iCloud Drive set up. Reported missing 2026-06-14.
        let iCloud = iCloudDriveURL(home: home)
        if fm.fileExists(atPath: iCloud.path) {
            items.append(.init(name: L("iCloud Drive", "iCloud Drive"), symbol: "icloud", url: iCloud))
        }
        if let u = dir(.downloadsDirectory) { items.append(.init(name: L("Downloads", "다운로드"), symbol: "arrow.down.circle", url: u)) }
        if let u = dir(.moviesDirectory)    { items.append(.init(name: L("Movies", "동영상"), symbol: "film", url: u)) }
        if let u = dir(.musicDirectory)     { items.append(.init(name: L("Music", "음악"), symbol: "music.note", url: u)) }
        if let u = dir(.picturesDirectory)  { items.append(.init(name: L("Pictures", "사진"), symbol: "photo", url: u)) }
        items.append(SidebarItem(name: L("Applications", "응용 프로그램"), symbol: "app.dashed", url: URL(fileURLWithPath: "/Applications")))
        if let trash = dir(.trashDirectory) {
            items.append(SidebarItem(name: L("Trash", "휴지통"), symbol: "trash", url: trash))
        }
        return items
    }

    /// URLs of the default favorites, used to seed the editable Favorites list on
    /// first run under the merged model (#61).
    static func defaultFavoriteURLs() -> [URL] { favorites().map(\.url) }

    /// Name + SF Symbol for a favorite URL: a known default folder keeps its nice
    /// localized name and icon; anything the user pinned is a generic folder.
    static func describeFavorite(_ url: URL) -> (name: String, symbol: String) {
        let path = url.standardizedFileURL.path
        if let known = favorites().first(where: { $0.url.standardizedFileURL.path == path }) {
            return (known.name, known.symbol)
        }
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        return (name, "folder")
    }

    static func locations() -> [SidebarItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey, .volumeIsLocalKey,
                                      .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        let vols = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                        options: [.skipHiddenVolumes]) ?? []
        return vols.compactMap { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.volumeIsBrowsable ?? false else { return nil }
            let name = v?.volumeName ?? url.lastPathComponent
            let local = v?.volumeIsLocal ?? true
            let ejectable = (v?.volumeIsEjectable ?? false) || (v?.volumeIsRemovable ?? false)
                || !(v?.volumeIsInternal ?? true)
            return SidebarItem(name: name,
                               symbol: local ? "internaldrive" : "externaldrive.connected.to.line.below",
                               url: url, ejectable: ejectable && url.path != "/")
        }
    }
}
