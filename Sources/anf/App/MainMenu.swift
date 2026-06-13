import AppKit

/// Target for the 보기 menu. Resolves the workspace from the key window so the
/// menu acts on whichever window is frontmost (multi-window correct).
@MainActor
final class ViewMenuController: NSObject, NSMenuItemValidation {
    static let shared = ViewMenuController()
    private var workspace: WorkspaceModel? { WindowRegistry.current }

    @objc func newWindow(_ sender: Any?) {
        AppController.newWindow()
    }

    @objc func toggleStatusBar(_ sender: Any?) {
        workspace?.pathBarVisible.toggle()
        workspace?.save()
    }

    @objc func showWelcome(_ sender: Any?) {
        workspace?.showWelcome = true
    }

    @objc func restoreLastSplit(_ sender: Any?) {
        workspace?.restoreLastSplit()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleStatusBar(_:)) {
            item.state = (workspace?.pathBarVisible ?? false) ? .on : .off
        }
        if item.action == #selector(restoreLastSplit(_:)) {
            return workspace?.hasLastSplitBackup == true
        }
        return workspace != nil
    }
}

/// Target for the Tools menu — on-device AI folder actions, reachable from the
/// menu bar even when a packed list view leaves no empty space to right-click.
@MainActor
final class ToolsMenuController: NSObject, NSMenuItemValidation {
    static let shared = ToolsMenuController()
    private var model: BrowserModel? { WindowRegistry.current?.active }

    @objc func tidyScreenshots(_ sender: Any?) {
        guard let m = model else { return }
        FolderAITools.tidyScreenshots(folder: m.currentURL, model: m)
    }

    @objc func organizeByKind(_ sender: Any?) {
        guard let m = model else { return }
        FolderAITools.organizeByKind(folder: m.currentURL, model: m)
    }

    @objc func organizeByContent(_ sender: Any?) {
        guard let m = model else { return }
        FolderAITools.organizeByContent(folder: m.currentURL, model: m)
    }

    @objc func summarizeFolder(_ sender: Any?) {
        guard let m = model else { return }
        FolderAITools.summarizeFolder(m.currentURL, name: m.currentURL.lastPathComponent)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { model != nil }
}

/// Minimal native menu bar. Standard editing selectors keep text fields (filter,
/// rename) fully functional; the App/Window menus give Quit, Hide and zoom.
/// Target for the ⌘, settings menu item (menus need an object target).
final class SettingsMenuTarget: NSObject {
    @MainActor static let shared = SettingsMenuTarget()
    @MainActor @objc func openSettings(_ sender: Any?) { Keymap.openSettingsFile() }
}

enum MainMenu {
    static func install() {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let about = appMenu.addItem(withTitle: L("About anf", "anf에 관하여"), action: #selector(AboutController.show(_:)), keyEquivalent: "")
        about.target = AboutController.shared
        appMenu.addItem(.separator())
        // ⌘, the Ghostty way: no settings window — opens keybindings.json,
        // pre-filled with every current default binding.
        let settings = appMenu.addItem(withTitle: L("Settings…", "설정…"),
                                       action: #selector(SettingsMenuTarget.openSettings(_:)),
                                       keyEquivalent: ",")
        settings.target = SettingsMenuTarget.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Hide anf", "anf 가리기"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: L("Hide Others", "기타 가리기"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L("Show All", "모두 보기"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit anf", "anf 종료"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu — New Window (⌘N) opens an independent window.
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: L("File", "파일"))
        fileItem.submenu = fileMenu
        let newWin = fileMenu.addItem(withTitle: L("New Window", "새 창"),
                                      action: #selector(ViewMenuController.newWindow(_:)),
                                      keyEquivalent: "n")
        newWin.target = ViewMenuController.shared
        // No ⌘W here: KeyboardController owns ⌘W contextually (close tab → pane →
        // window), and its monitor consumes the event before the menu sees it.

        // Edit menu (standard responder-chain selectors)
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: L("Edit", "편집"))
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: L("Undo", "실행 취소"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("Redo", "실행 복귀"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Cut", "오려두기"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Copy", "복사하기"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste", "붙여넣기"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Select All", "전체 선택"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // View menu
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: L("View", "보기"))
        viewItem.submenu = viewMenu
        let statusBar = viewMenu.addItem(withTitle: L("Show Status Bar", "상태 막대 보기"),
                                         action: #selector(ViewMenuController.toggleStatusBar(_:)),
                                         keyEquivalent: "/")
        statusBar.target = ViewMenuController.shared
        viewMenu.addItem(.separator())
        let restoreSplit = viewMenu.addItem(withTitle: L("Restore Last Split Layout", "마지막 분할 배치 복원"),
                                            action: #selector(ViewMenuController.restoreLastSplit(_:)),
                                            keyEquivalent: "")
        restoreSplit.target = ViewMenuController.shared
        let welcome = viewMenu.addItem(withTitle: L("Shortcuts at a Glance", "단축키 한눈에 보기"),
                                       action: #selector(ViewMenuController.showWelcome(_:)),
                                       keyEquivalent: "")
        welcome.target = ViewMenuController.shared

        // Tools menu — on-device AI folder actions (also in the right-click menu,
        // but the menu bar works when the list view has no empty space to click).
        let toolsItem = NSMenuItem()
        main.addItem(toolsItem)
        let toolsMenu = NSMenu(title: L("Tools", "도구"))
        toolsItem.submenu = toolsMenu
        let byKind = toolsMenu.addItem(withTitle: L("Organize by Kind", "종류별 정리"),
                                       action: #selector(ToolsMenuController.organizeByKind(_:)),
                                       keyEquivalent: "")
        byKind.target = ToolsMenuController.shared
        let byContent = toolsMenu.addItem(withTitle: L("Organize by Content (AI)", "내용별 정리 (AI)"),
                                          action: #selector(ToolsMenuController.organizeByContent(_:)),
                                          keyEquivalent: "")
        byContent.target = ToolsMenuController.shared
        let tidy = toolsMenu.addItem(withTitle: L("Tidy Screenshots", "스크린샷 정리"),
                                     action: #selector(ToolsMenuController.tidyScreenshots(_:)),
                                     keyEquivalent: "")
        tidy.target = ToolsMenuController.shared
        toolsMenu.addItem(.separator())
        let sumFolder = toolsMenu.addItem(withTitle: L("Summarize Folder (AI)", "이 폴더 요약 (AI)"),
                                          action: #selector(ToolsMenuController.summarizeFolder(_:)),
                                          keyEquivalent: "")
        sumFolder.target = ToolsMenuController.shared

        // Window menu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: L("Window", "윈도우"))
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: L("Minimize", "최소화"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("Zoom", "확대/축소"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}
