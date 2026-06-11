import AppKit

/// Modal form for adding a custom SSH host. Returns nil on cancel.
@MainActor
enum SSHPrompt {
    static func run() -> CustomSSHHost? {
        let alert = NSAlert()
        alert.messageText = L("Add SSH Host", "SSH Host 추가")
        alert.addButton(withTitle: L("Add", "추가"))
        alert.addButton(withTitle: L("Cancel", "취소"))

        // Form container: 4 rows of label + field
        let formWidth: CGFloat = 320
        let labelWidth: CGFloat = 72
        let fieldX: CGFloat = labelWidth + 8
        let fieldWidth: CGFloat = formWidth - fieldX
        let rowHeight: CGFloat = 24
        let rowGap: CGFloat = 8
        let rows = 4
        let formHeight = CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowGap

        let container = NSView(frame: NSRect(x: 0, y: 0, width: formWidth, height: formHeight))

        func makeLabel(_ text: String, row: Int) {
            let y = formHeight - CGFloat(row + 1) * rowHeight - CGFloat(row) * rowGap
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 0, y: y + 3, width: labelWidth, height: 18)
            l.alignment = .right
            l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            container.addSubview(l)
        }

        func makeField(row: Int, placeholder: String) -> NSTextField {
            let y = formHeight - CGFloat(row + 1) * rowHeight - CGFloat(row) * rowGap
            let f = NSTextField(frame: NSRect(x: fieldX, y: y, width: fieldWidth, height: 22))
            f.placeholderString = placeholder
            f.font = .systemFont(ofSize: 13)
            container.addSubview(f)
            return f
        }

        func makeSecureField(row: Int, placeholder: String) -> NSSecureTextField {
            let y = formHeight - CGFloat(row + 1) * rowHeight - CGFloat(row) * rowGap
            let f = NSSecureTextField(frame: NSRect(x: fieldX, y: y, width: fieldWidth, height: 22))
            f.placeholderString = placeholder
            f.font = .systemFont(ofSize: 13)
            container.addSubview(f)
            return f
        }

        makeLabel("Host / IP", row: 0)
        makeLabel("User", row: 1)
        makeLabel("Password", row: 2)
        makeLabel("Key File", row: 3)

        let hostField = makeField(row: 0, placeholder: L("hostname or IP", "hostname 또는 IP"))
        let userField = makeField(row: 1, placeholder: L("user (optional)", "사용자명 (선택)"))
        let passField = makeSecureField(row: 2, placeholder: L("password (optional)", "비밀번호 (선택)"))

        // Key file row: field + browse "…" button side by side
        let browseWidth: CGFloat = 28
        let keyFieldWidth = fieldWidth - browseWidth - 4
        let keyRow = 3
        let keyY = formHeight - CGFloat(keyRow + 1) * rowHeight - CGFloat(keyRow) * rowGap
        let keyField = NSTextField(frame: NSRect(x: fieldX, y: keyY, width: keyFieldWidth, height: 22))
        keyField.placeholderString = L("~/.ssh/id_rsa (optional)", "~/.ssh/id_rsa (선택)")
        keyField.font = .systemFont(ofSize: 13)
        container.addSubview(keyField)

        let browse = NSButton(title: "…", target: nil, action: nil)
        browse.frame = NSRect(x: fieldX + keyFieldWidth + 4, y: keyY, width: browseWidth, height: 22)
        browse.bezelStyle = .rounded
        browse.font = .systemFont(ofSize: 12)
        container.addSubview(browse)

        alert.accessoryView = container
        alert.window.initialFirstResponder = hostField

        let coordinator = BrowseButtonCoordinator(field: keyField, window: alert.window)
        browse.target = coordinator
        browse.action = #selector(BrowseButtonCoordinator.browse(_:))

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        let user    = userField.stringValue.trimmingCharacters(in: .whitespaces)
        let pass    = passField.stringValue.trimmingCharacters(in: .whitespaces)
        let keyPath = keyField.stringValue.trimmingCharacters(in: .whitespaces)
        _ = coordinator

        return CustomSSHHost(
            host: host,
            user: user.isEmpty ? nil : user,
            password: pass.isEmpty ? nil : pass,
            keyFile: keyPath.isEmpty ? nil : keyPath
        )
    }
}

private final class BrowseButtonCoordinator: NSObject {
    weak var field: NSTextField?
    weak var window: NSWindow?

    init(field: NSTextField, window: NSWindow?) {
        self.field = field; self.window = window
    }

    @objc func browse(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.title = L("Choose Key File", "키 파일 선택")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        field?.stringValue = url.path
    }
}
