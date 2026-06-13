import AppKit

/// Retains a closure for an NSMenuItem target.
final class MenuTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

/// Small filled circle for a tag menu item.
@MainActor func tagSwatch(_ color: NSColor) -> NSImage {
    let img = NSImage(size: NSSize(width: 12, height: 12))
    img.lockFocus()
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 10, height: 10)).fill()
    img.unlockFocus()
    return img
}

/// Shared right-click menus (AppKit `NSMenu`) used by the list table and the
/// icon-grid collection view, so both views behave identically.
@MainActor
enum FileItemMenu {

    /// Menu for a clicked item. Selects it first if it isn't in the selection.
    static func build(for item: FileItem, model: BrowserModel) -> NSMenu {
        if !model.selection.contains(item.id) { model.selection = [item.id] }
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let mi = NSMenuItem(title: title, action: #selector(MenuTarget.fire), keyEquivalent: "")
            let t = MenuTarget(action); mi.target = t; mi.representedObject = t
            menu.addItem(mi)
        }
        add(L("Open", "열기")) { model.open(item) }
        if item.isBrowsableContainer {
            add(L("Open Terminal Here", "여기서 터미널 열기")) { FileOperations.openInTerminal(item.url) }
        }
        add(L("Get Info", "정보 가져오기")) { model.showGetInfo() }

        // On-device AI summary (single selection): a summarizable file, or a
        // folder (overview of its documents). Shown in a floating panel.
        if model.selection.count <= 1 && AIFeatures.enabled {
            if item.hasSummarizableText {
                menu.addItem(.separator())
                add(L("Summarize (AI)", "AI 요약")) { FolderAITools.summarizeFile(item.url, name: item.name) }
                add(L("Ask… (AI)", "질문하기… (AI)")) { FolderAITools.ask(url: item.url, name: item.name, isFolder: false) }
                add(L("Suggest Name (AI)", "AI 이름 제안")) { FolderAITools.suggestNames([item.url], title: item.name, model: model) }
                add(L("Auto-Tag (AI)", "AI 태그 추가")) { FolderAITools.autoTag(taggableSelection(item, model), title: item.name, model: model) }
            } else if OCRService.isImage(item.url) {
                menu.addItem(.separator())
                add(L("Suggest Name (AI)", "AI 이름 제안")) { FolderAITools.suggestNames([item.url], title: item.name, model: model) }
                add(L("Auto-Tag (AI)", "AI 태그 추가")) { FolderAITools.autoTag(taggableSelection(item, model), title: item.name, model: model) }
            } else if item.isBrowsableContainer {
                menu.addItem(.separator())
                add(L("Summarize Folder (AI)", "이 폴더 요약 (AI)")) {
                    FolderAITools.summarizeFolder(item.url, name: item.name)
                }
                add(L("Ask This Folder… (AI)", "이 폴더에 질문하기… (AI)")) {
                    FolderAITools.ask(url: item.url, name: item.name, isFolder: true)
                }
            }
        }

        // Vault: protect the clicked folder itself (one folder at a time).
        if item.isBrowsableContainer && model.selection.count <= 1 {
            menu.addItem(.separator())
            if VaultWatcher.shared.isVault(item.url) {
                add(L("Vault Timeline…", "Vault 타임라인…")) { VaultTimelinePanel.show(for: item.url) }
                add(L("Snapshot Now", "지금 스냅샷")) { VaultWatcher.shared.snapshotNow(item.url) }
                add(L("Turn Off Vault…", "Vault 끄기…")) { model.confirmDisableVault(item.url) }
            } else {
                add(L("Protect with Vault…", "Vault로 보호하기…")) { model.enableVault(item.url) }
            }
        }
        menu.addItem(.separator())

        // Colour tags submenu (Finder parity).
        let tagItem = NSMenuItem(title: L("Tags", "태그"), action: nil, keyEquivalent: "")
        let tagMenu = NSMenu()
        let active = Set(model.selectedItems.flatMap { FileTags.tags(of: $0.url) })
        for (name, color) in FileTags.standard {
            let mi = NSMenuItem(title: name, action: #selector(MenuTarget.fire), keyEquivalent: "")
            let t = MenuTarget { model.toggleTag(name) }
            mi.target = t; mi.representedObject = t
            mi.state = active.contains(name) ? .on : .off
            mi.image = tagSwatch(color)
            tagMenu.addItem(mi)
        }
        tagItem.submenu = tagMenu
        menu.addItem(tagItem)
        menu.addItem(.separator())
        if model.selection.count > 1 {
            add(L("Rename \(model.selection.count) Items…", "\(model.selection.count)개 항목 이름 변경…")) { model.batchRename() }
        } else {
            add(L("Rename", "이름 변경")) { model.beginRename() }
        }
        add(L("Duplicate", "복제")) { model.duplicateSelection() }
        menu.addItem(.separator())
        if item.isArchive && model.selection.count <= 1 {
            add(L("Extract", "압축 풀기")) { ArchiveService.extract(item) { model.reload() } }
        } else {
            add(model.selection.count > 1
                ? L("Compress \(model.selection.count) Items", "\(model.selection.count)개 항목 압축")
                : L("Compress", "압축")) {
                ArchiveService.compress(model.selectedItems) { model.reload() }
            }
        }
        menu.addItem(.separator())
        add(L("Copy", "복사")) { model.copySelectionToPasteboard() }
        add(L("Copy Path", "경로 복사")) { model.copyPathToPasteboard() }
        add(L("Paste", "붙여넣기")) { model.pasteFromPasteboard() }
        add(L("Reveal in Finder", "Finder에서 보기")) { model.revealSelection() }
        menu.addItem(.separator())
        add(L("Move to Trash", "휴지통으로 이동")) { model.trashSelection() }
        return menu
    }

    /// Menu for empty space inside a folder.
    static func background(model: BrowserModel) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let mi = NSMenuItem(title: title, action: #selector(MenuTarget.fire), keyEquivalent: "")
            let t = MenuTarget(action); mi.target = t; mi.representedObject = t
            menu.addItem(mi)
        }
        add(L("New Folder", "새 폴더")) { model.makeNewFolder() }
        add(L("Open Terminal Here", "여기서 터미널 열기")) { FileOperations.openInTerminal(model.currentURL) }
        menu.addItem(.separator())
        // Right-click the empty area of a folder → folder tools. The plain
        // file-movers are always here; the on-device-AI actions only when enabled.
        let folder = model.currentURL
        add(L("Tidy Screenshots", "스크린샷 정리")) { FolderAITools.tidyScreenshots(folder: folder, model: model) }
        add(L("Organize by Kind", "종류별 정리")) { FolderAITools.organizeByKind(folder: folder, model: model) }
        if AIFeatures.enabled {
            add(L("Summarize Folder (AI)", "이 폴더 요약 (AI)")) {
                FolderAITools.summarizeFolder(folder, name: folder.lastPathComponent)
            }
            add(L("Ask This Folder… (AI)", "이 폴더에 질문하기… (AI)")) {
                FolderAITools.ask(url: folder, name: folder.lastPathComponent, isFolder: true)
            }
            add(L("Organize by Content (AI)", "내용별 정리 (AI)")) { FolderAITools.organizeByContent(folder: folder, model: model) }
            add(L("Auto-Tag Folder (AI)", "폴더 자동 태그 (AI)")) { FolderAITools.autoTagFolder(folder: folder, model: model) }
        }
        menu.addItem(.separator())
        // Vault: time-travel protection for this folder.
        if VaultWatcher.shared.isVault(model.currentURL) {
            add(L("Vault Timeline…", "Vault 타임라인…")) { VaultTimelinePanel.show(for: model.currentURL) }
            add(L("Snapshot Now", "지금 스냅샷")) { VaultWatcher.shared.snapshotNow(model.currentURL) }
            add(L("Turn Off Vault…", "Vault 끄기…")) { model.confirmDisableVault() }
        } else {
            add(L("Protect with Vault…", "Vault로 보호하기…")) { model.enableVault() }
        }
        menu.addItem(.separator())
        add(L("Paste", "붙여넣기")) { model.pasteFromPasteboard() }
        add(L("Go to Folder…", "폴더로 이동…")) { model.goToFolderPrompt() }
        // Empty-space click = the folder itself, not the (auto-)selected row.
        add(L("Copy Folder Path", "현재 폴더 경로 복사")) { model.copyCurrentFolderPath() }
        menu.addItem(.separator())
        add(model.showHidden ? L("Hide Hidden Files", "숨김 파일 가리기")
                             : L("Show Hidden Files", "숨김 파일 보기")) {
            model.showHidden.toggle()
        }
        return menu
    }

    /// URLs to auto-tag: the whole selection when multiple taggable files are
    /// selected, otherwise just the clicked item.
    private static func taggableSelection(_ item: FileItem, _ model: BrowserModel) -> [URL] {
        if model.selection.count > 1 {
            let urls = model.selectedItems
                .filter { $0.hasSummarizableText || OCRService.isImage($0.url) }
                .map(\.url)
            if !urls.isEmpty { return urls }
        }
        return [item.url]
    }
}
