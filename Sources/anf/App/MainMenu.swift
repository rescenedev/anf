import AppKit

/// Target for the 보기 menu — holds the workspace and keeps the checkmark in sync.
@MainActor
final class ViewMenuController: NSObject, NSMenuItemValidation {
    static let shared = ViewMenuController()
    weak var workspace: WorkspaceModel?

    @objc func toggleStatusBar(_ sender: Any?) {
        workspace?.pathBarVisible.toggle()
        workspace?.save()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleStatusBar(_:)) {
            item.state = (workspace?.pathBarVisible ?? false) ? .on : .off
        }
        return workspace != nil
    }
}

/// Minimal native menu bar. Standard editing selectors keep text fields (filter,
/// rename) fully functional; the App/Window menus give Quit, Hide and zoom.
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
        appMenu.addItem(withTitle: L("Hide anf", "anf 가리기"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: L("Hide Others", "기타 가리기"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L("Show All", "모두 보기"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit anf", "anf 종료"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

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
