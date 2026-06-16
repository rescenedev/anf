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
    private var ws: WorkspaceModel? { WindowRegistry.current }

    /// Copy the current pinned folders + saved workspaces as JSON, ready to paste
    /// into the ⌘, settings file — for migrating to another Mac.
    @objc func exportPinsWorkspaces(_ sender: Any?) {
        guard let ws else { return }
        let pinned = ws.favorites.exportPaths().map { "    \"\($0)\"" }.joined(separator: ",\n")
        let workspaces = ws.savedViews.exportJSON()
        let json = "\"pinned\": [\n\(pinned)\n],\n\"workspaces\": \(workspaces)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        let a = NSAlert()
        a.messageText = L("Copied pins & workspaces", "핀·워크스페이스를 복사했어요")
        a.informativeText = L("Paste the JSON into the settings file (⌘,) to move them to another Mac.",
                              "설정 파일(⌘,)에 붙여넣으면 다른 Mac으로 옮길 수 있어요.")
        a.addButton(withTitle: L("Open Settings", "설정 열기"))
        a.addButton(withTitle: L("Done", "완료"))
        if a.runModal() == .alertFirstButtonReturn { Keymap.openSettingsFile() }
    }

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

    @objc func askFolder(_ sender: Any?) {
        guard let m = model else { return }
        FolderAITools.ask(url: m.currentURL, name: m.currentURL.lastPathComponent, isFolder: true)
    }

    @objc func autoTagFolder(_ sender: Any?) {
        guard let m = model else { return }
        FolderAITools.autoTagFolder(folder: m.currentURL, model: m)
    }

    @objc func toggleAI(_ sender: Any?) { AIFeatures.enabled.toggle() }

    @objc func aiProviderSettings(_ sender: Any?) { Keymap.openSettingsFile() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // The on/off toggle and the settings link are always available.
        if item.action == #selector(toggleAI(_:)) {
            item.state = AIFeatures.enabled ? .on : .off
            return true
        }
        if item.action == #selector(aiProviderSettings(_:)) { return true }
        guard model != nil else { return false }
        // The on-device-LLM actions need the feature on; the plain file-moving
        // tools (organize by kind, tidy screenshots) don't.
        let needsAI: Set<Selector> = [
            #selector(organizeByContent(_:)), #selector(autoTagFolder(_:)),
            #selector(summarizeFolder(_:)), #selector(askFolder(_:)),
        ]
        if let a = item.action, needsAI.contains(a) { return AIFeatures.enabled }
        return true
    }
}

/// Target for the AI menu — feature toggle, API-key management, provider choice.
/// The key is stored in the macOS Keychain (`AISecret`/`Keychain`), never on disk.
@MainActor
final class AIMenuController: NSObject, NSMenuItemValidation {
    static let shared = AIMenuController()

    @objc func toggleAI(_ sender: Any?) { AIFeatures.enabled.toggle() }

    @objc func setAPIKey(_ sender: Any?) {
        let replacing = AISecret.hasKey
        let msg = replacing
            ? L("Replace the key stored in your macOS Keychain. Get one at console.anthropic.com (sk-ant-api03-…).",
                "macOS 키체인에 저장된 키를 교체합니다. console.anthropic.com에서 발급 (sk-ant-api03-…).")
            : L("Pasted keys are saved to the macOS Keychain — never to a file. Get one at console.anthropic.com (sk-ant-api03-…).",
                "붙여넣은 키는 파일이 아니라 macOS 키체인에 저장됩니다. console.anthropic.com에서 발급 (sk-ant-api03-…).")
        guard let key = TextPrompt.runSecure(
            title: L("Anthropic API Key", "Anthropic API 키"),
            message: msg, placeholder: "sk-ant-api03-…",
            action: L("Save to Keychain", "키체인에 저장")) else { return }
        if AISecret.setKey(key) {
            if !AIFeatures.enabled { AIFeatures.enabled = true }   // make it usable right away
            confirm(L("API key saved to your Keychain.", "API 키를 키체인에 저장했어요."))
        } else {
            confirm(L("Couldn’t save to the Keychain.", "키체인에 저장하지 못했어요."), warning: true)
        }
    }

    @objc func removeAPIKey(_ sender: Any?) {
        AISecret.setKey(nil)
        confirm(L("API key removed from your Keychain.", "키체인에서 API 키를 삭제했어요."))
    }

    @objc func aiProviderSettings(_ sender: Any?) { Keymap.openSettingsFile() }

    private func confirm(_ text: String, warning: Bool = false) {
        let a = NSAlert()
        a.messageText = text
        a.alertStyle = warning ? .warning : .informational
        a.addButton(withTitle: L("OK", "확인"))
        a.runModal()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleAI(_:)): item.state = AIFeatures.enabled ? .on : .off; return true
        case #selector(removeAPIKey(_:)): return AISecret.hasKey
        default: return true
        }
    }
}

/// Minimal native menu bar. Standard editing selectors keep text fields (filter,
/// rename) fully functional; the App/Window menus give Quit, Hide and zoom.
/// Target for the ⌘, settings menu item (menus need an object target).
final class SettingsMenuTarget: NSObject {
    @MainActor static let shared = SettingsMenuTarget()
    @MainActor @objc func openSettings(_ sender: Any?) { Keymap.openSettingsFile() }
}

/// Target for the "Check for Updates…" App-menu item (issue #38).
final class UpdateMenuTarget: NSObject {
    @MainActor static let shared = UpdateMenuTarget()
    @MainActor @objc func checkForUpdates(_ sender: Any?) { UpdateChecker.shared.checkNow() }
}

enum MainMenu {
    @MainActor static func install() {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let about = appMenu.addItem(withTitle: L("About anf", "anf에 관하여"), action: #selector(AboutController.show(_:)), keyEquivalent: "")
        about.target = AboutController.shared
        let update = appMenu.addItem(withTitle: L("Check for Updates…", "업데이트 확인…"),
                                     action: #selector(UpdateMenuTarget.checkForUpdates(_:)),
                                     keyEquivalent: "")
        update.target = UpdateMenuTarget.shared
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

        // AI menu — feature toggle, API-key management (stored in the Keychain),
        // and provider selection. The on-device folder actions live in Tools.
        let aiItem = NSMenuItem()
        main.addItem(aiItem)
        let aiMenu = NSMenu(title: L("AI", "AI"))
        aiItem.submenu = aiMenu
        let aiToggle = aiMenu.addItem(withTitle: L("Enable AI Features", "AI 기능 사용"),
                                      action: #selector(AIMenuController.toggleAI(_:)), keyEquivalent: "")
        aiToggle.target = AIMenuController.shared
        aiMenu.addItem(.separator())
        let setKey = aiMenu.addItem(withTitle: L("Set Anthropic API Key…", "Anthropic API 키 설정…"),
                                    action: #selector(AIMenuController.setAPIKey(_:)), keyEquivalent: "")
        setKey.target = AIMenuController.shared
        let removeKey = aiMenu.addItem(withTitle: L("Remove API Key", "API 키 삭제"),
                                       action: #selector(AIMenuController.removeAPIKey(_:)), keyEquivalent: "")
        removeKey.target = AIMenuController.shared
        aiMenu.addItem(.separator())
        let aiProvider = aiMenu.addItem(withTitle: L("AI Provider… (Apple / Local / Claude)", "AI 모델 연결… (Apple / 로컬 / Claude)"),
                                        action: #selector(AIMenuController.aiProviderSettings(_:)), keyEquivalent: "")
        aiProvider.target = AIMenuController.shared

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
        let autoTag = toolsMenu.addItem(withTitle: L("Auto-Tag Folder (AI)", "폴더 자동 태그 (AI)"),
                                        action: #selector(ToolsMenuController.autoTagFolder(_:)),
                                        keyEquivalent: "")
        autoTag.target = ToolsMenuController.shared
        let tidy = toolsMenu.addItem(withTitle: L("Tidy Screenshots", "스크린샷 정리"),
                                     action: #selector(ToolsMenuController.tidyScreenshots(_:)),
                                     keyEquivalent: "")
        tidy.target = ToolsMenuController.shared
        toolsMenu.addItem(.separator())
        let sumFolder = toolsMenu.addItem(withTitle: L("Summarize Folder (AI)", "이 폴더 요약 (AI)"),
                                          action: #selector(ToolsMenuController.summarizeFolder(_:)),
                                          keyEquivalent: "")
        sumFolder.target = ToolsMenuController.shared
        let askFolder = toolsMenu.addItem(withTitle: L("Ask This Folder… (AI)", "이 폴더에 질문하기… (AI)"),
                                          action: #selector(ToolsMenuController.askFolder(_:)),
                                          keyEquivalent: "")
        askFolder.target = ToolsMenuController.shared
        toolsMenu.addItem(.separator())
        let exportPins = toolsMenu.addItem(withTitle: L("Copy Pins & Workspaces (JSON)…", "핀·워크스페이스 복사 (JSON)…"),
                                           action: #selector(ToolsMenuController.exportPinsWorkspaces(_:)),
                                           keyEquivalent: "")
        exportPins.target = ToolsMenuController.shared

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
