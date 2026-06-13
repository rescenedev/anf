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
        if model.selection.count <= 1 {
            if item.hasSummarizableText {
                menu.addItem(.separator())
                add(L("Summarize (AI)", "AI 요약")) { summarizeFile(item.url, name: item.name) }
                add(L("Suggest Name (AI)", "AI 이름 제안")) { suggestNames([item.url], title: item.name, model: model) }
            } else if OCRService.isImage(item.url) {
                menu.addItem(.separator())
                add(L("Suggest Name (AI)", "AI 이름 제안")) { suggestNames([item.url], title: item.name, model: model) }
            } else if item.isBrowsableContainer {
                menu.addItem(.separator())
                add(L("Summarize Folder (AI)", "이 폴더 요약 (AI)")) {
                    summarizeFolder(item.url, name: item.name)
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
        // Right-click the empty area of a folder → AI actions for the folder.
        let folder = model.currentURL
        add(L("Summarize Folder (AI)", "이 폴더 요약 (AI)")) {
            summarizeFolder(folder, name: folder.lastPathComponent)
        }
        add(L("Tidy Screenshots (AI)", "스크린샷 정리 (AI)")) { tidyScreenshots(folder, model: model) }
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

    /// Open the summary panel for a single file. Shows the unavailable hint
    /// straight away instead of spinning when Apple Intelligence is off/missing.
    private static func summarizeFile(_ url: URL, name: String) {
        if !LocalLLM.isAvailable {
            let hint = LocalLLM.unavailableHint(LocalLLM.status)
            SummaryPanel.show(title: name, key: url.path) { hint }
            return
        }
        SummaryPanel.show(title: name, key: url.path) {
            await SummaryService.summarize(url: url)
        }
    }

    /// Open the summary panel for a folder (overview of its documents).
    private static func summarizeFolder(_ url: URL, name: String) {
        if !LocalLLM.isAvailable {
            let hint = LocalLLM.unavailableHint(LocalLLM.status)
            SummaryPanel.show(title: name, key: "folder:" + url.path) { hint }
            return
        }
        SummaryPanel.show(title: name, key: "folder:" + url.path) {
            await SummaryService.summarizeFolder(url: url)
        }
    }

    /// Open the rename-suggestion panel for one or more files.
    private static func suggestNames(_ urls: [URL], title: String, model: BrowserModel) {
        guard ensureLLM(title: title) else { return }
        RenamePanel.show(title: L("Suggest Name — \(title)", "AI 이름 제안 — \(title)"),
                         urls: urls) { model.reload() }
    }

    /// Find screenshots in `folder` and open the batch rename panel for them.
    private static func tidyScreenshots(_ folder: URL, model: BrowserModel) {
        guard ensureLLM(title: folder.lastPathComponent) else { return }
        let shots = ScreenshotTidy.find(in: folder)
        guard !shots.isEmpty else {
            let a = NSAlert()
            a.messageText = L("No screenshots found", "스크린샷을 찾지 못했어요")
            a.informativeText = L("Nothing here looks like a screenshot.",
                                  "이 폴더에는 스크린샷으로 보이는 파일이 없어요.")
            a.runModal()
            return
        }
        RenamePanel.show(title: L("Tidy Screenshots — \(shots.count)", "스크린샷 정리 — \(shots.count)개"),
                         urls: shots) { model.reload() }
    }

    /// True if the on-device LLM is ready; otherwise show its hint and return false.
    private static func ensureLLM(title: String) -> Bool {
        if LocalLLM.isAvailable { return true }
        let a = NSAlert()
        a.messageText = L("On-device AI unavailable", "온디바이스 AI를 쓸 수 없어요")
        a.informativeText = LocalLLM.unavailableHint(LocalLLM.status)
        a.runModal()
        return false
    }
}
