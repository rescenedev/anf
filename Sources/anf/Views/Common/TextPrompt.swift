import AppKit

/// A simple modal text prompt (rename, go-to-folder). Returns the entered string,
/// or nil if cancelled. Runs on the main actor — AppKit modal.
@MainActor
enum TextPrompt {
    static func run(title: String, message: String, defaultValue: String, action: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: L("Cancel", "취소"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultValue
        field.lineBreakMode = .byTruncatingMiddle
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Secure (masked) single-field prompt — for secrets like the API key. The
    /// typed value is never echoed and never logged. Returns nil if cancelled.
    static func runSecure(title: String, message: String, placeholder: String, action: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: L("Cancel", "취소"))

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Two-field prompt (used for batch rename find/replace). Returns (find, replace).
    static func runPair(title: String, message: String,
                        label1: String, label2: String, action: String) -> (String, String)? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: L("Cancel", "취소"))

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        let f1 = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 22))
        f1.placeholderString = label1
        let f2 = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        f2.placeholderString = label2
        container.addSubview(f1); container.addSubview(f2)
        alert.accessoryView = container
        alert.window.initialFirstResponder = f1

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (f1.stringValue, f2.stringValue)
    }
}
