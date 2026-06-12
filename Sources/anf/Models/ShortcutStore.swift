import AppKit

/// A recorded key binding: physical key code + modifier flags (device-independent).
struct KeyBinding: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt   // NSEvent.ModifierFlags.deviceIndependentFlagsMask subset

    var flags: NSEvent.ModifierFlags { .init(rawValue: modifiers) }

    /// Human-readable label, e.g. "⌘⇧K".
    var displayString: String {
        let f = flags
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        s += Self.keyLabel(for: keyCode)
        return s
    }

    static func keyLabel(for code: UInt16) -> String {
        let letters: [UInt16: String] = [
            0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",
            11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",31:"O",32:"U",
            34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M"
        ]
        let symbols: [UInt16: String] = [
            33:"[", 30:"]", 44:"/", 47:".", 41:";", 43:",", 39:"'",
            27:"-", 24:"=",
            123:"←", 124:"→", 125:"↓", 126:"↑",
            36:"↩", 48:"⇥", 49:"Space", 51:"⌫", 53:"⎋",
            96:"F5", 97:"F6", 116:"PgUp", 121:"PgDn", 115:"Home", 119:"End"
        ]
        if let l = letters[code] { return l }
        if let s = symbols[code] { return s }
        return "?\(code)"
    }
}

/// All actions whose keyboard shortcut can be customised by the user.
enum ShortcutAction: String, CaseIterable, Codable {
    case commandPalette
    case newTab
    case closeTabPaneWindow
    case newFolder
    case goToFolder
    case reload
    case duplicate
    case toggleFavorite
    case copyPath
    case copyFolderPath
    case getInfo
    case toggleInspector
    case togglePathBar
    case toggleHidden
    case cycleViewBack
    case cycleViewForward
    case toggleSidebar
    case undo
    case redo

    var displayName: String {
        switch self {
        case .commandPalette:      return L("Command Palette", "커맨드 팔레트")
        case .newTab:              return L("New Tab", "새 탭")
        case .closeTabPaneWindow:  return L("Close Tab / Pane / Window", "탭 / 패인 / 윈도우 닫기")
        case .newFolder:           return L("New Folder", "새 폴더")
        case .goToFolder:          return L("Go to Folder", "폴더로 이동")
        case .reload:              return L("Reload", "새로 고침")
        case .duplicate:           return L("Duplicate", "복제")
        case .toggleFavorite:      return L("Toggle Favorite", "즐겨찾기 토글")
        case .copyPath:            return L("Copy Path", "경로 복사")
        case .copyFolderPath:      return L("Copy Folder Path", "폴더 경로 복사")
        case .getInfo:             return L("Get Info", "정보 가져오기")
        case .toggleInspector:     return L("Toggle Inspector", "인스펙터 토글")
        case .togglePathBar:       return L("Toggle Path Bar", "경로 막대 토글")
        case .toggleHidden:        return L("Show/Hide Hidden Files", "숨긴 파일 표시/숨기기")
        case .cycleViewBack:       return L("Cycle View Mode Back", "보기 모드 뒤로")
        case .cycleViewForward:    return L("Cycle View Mode Forward", "보기 모드 앞으로")
        case .toggleSidebar:       return L("Toggle Sidebar", "사이드바 토글")
        case .undo:                return L("Undo File Operation", "파일 작업 실행 취소")
        case .redo:                return L("Redo File Operation", "파일 작업 다시 실행")
        }
    }

    var defaultBinding: KeyBinding {
        let cmd      = NSEvent.ModifierFlags.command.rawValue
        let cmdShift = NSEvent.ModifierFlags([.command, .shift]).rawValue
        let cmdOpt   = NSEvent.ModifierFlags([.command, .option]).rawValue
        let cmdOptS  = NSEvent.ModifierFlags([.command, .option, .shift]).rawValue
        switch self {
        case .commandPalette:      return KeyBinding(keyCode: 40, modifiers: cmd)      // ⌘K
        case .newTab:              return KeyBinding(keyCode: 17, modifiers: cmd)      // ⌘T
        case .closeTabPaneWindow:  return KeyBinding(keyCode: 13, modifiers: cmd)      // ⌘W
        case .newFolder:           return KeyBinding(keyCode: 45, modifiers: cmdShift) // ⌘⇧N
        case .goToFolder:          return KeyBinding(keyCode: 37, modifiers: cmd)      // ⌘L
        case .reload:              return KeyBinding(keyCode: 15, modifiers: cmd)      // ⌘R
        case .duplicate:           return KeyBinding(keyCode: 2,  modifiers: cmd)      // ⌘D
        case .toggleFavorite:      return KeyBinding(keyCode: 2,  modifiers: cmdShift) // ⌘⇧D
        case .copyPath:            return KeyBinding(keyCode: 8,  modifiers: cmdOpt)   // ⌘⌥C
        case .copyFolderPath:      return KeyBinding(keyCode: 8,  modifiers: cmdOptS)  // ⌘⌥⇧C
        case .getInfo:             return KeyBinding(keyCode: 34, modifiers: cmdOpt)   // ⌘⌥I
        case .toggleInspector:     return KeyBinding(keyCode: 34, modifiers: cmd)      // ⌘I
        case .togglePathBar:       return KeyBinding(keyCode: 44, modifiers: cmd)      // ⌘/
        case .toggleHidden:        return KeyBinding(keyCode: 47, modifiers: cmdShift) // ⌘⇧.
        case .cycleViewBack:       return KeyBinding(keyCode: 33, modifiers: cmd)      // ⌘[
        case .cycleViewForward:    return KeyBinding(keyCode: 30, modifiers: cmd)      // ⌘]
        case .toggleSidebar:       return KeyBinding(keyCode: 33, modifiers: cmdShift) // ⌘⇧[
        case .undo:                return KeyBinding(keyCode: 6,  modifiers: cmd)      // ⌘Z
        case .redo:                return KeyBinding(keyCode: 6,  modifiers: cmdShift) // ⌘⇧Z
        }
    }
}

/// Persists user-customised key bindings. Falls back to each action's
/// `defaultBinding` for any action not yet overridden.
@MainActor
final class ShortcutStore {
    static let shared = ShortcutStore()
    private static let udKey = "anf.shortcuts.v1"

    private var overrides: [String: KeyBinding] = [:]

    private init() { load() }

    func binding(for action: ShortcutAction) -> KeyBinding {
        overrides[action.rawValue] ?? action.defaultBinding
    }

    func set(_ binding: KeyBinding, for action: ShortcutAction) {
        overrides[action.rawValue] = binding
        persist()
    }

    func reset(_ action: ShortcutAction) {
        overrides.removeValue(forKey: action.rawValue)
        persist()
    }

    func resetAll() {
        overrides.removeAll()
        persist()
    }

    /// True when the given action's binding differs from the built-in default.
    func isCustomised(_ action: ShortcutAction) -> Bool {
        overrides[action.rawValue] != nil
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.udKey),
              let decoded = try? JSONDecoder().decode([String: KeyBinding].self, from: data)
        else { return }
        overrides = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: Self.udKey)
        }
    }
}
