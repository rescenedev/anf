import SwiftUI
import AppKit

/// Finder-style in-place rename field. A focused `NSTextField` that selects the
/// base name (without extension) on appear, commits on Return or focus loss, and
/// cancels on Escape — no modal popup.
struct InlineRenameField: NSViewRepresentable {
    let initialName: String
    let isDirectory: Bool
    let fontSize: CGFloat
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: initialName)
        field.font = .systemFont(ofSize: fontSize)
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.lineBreakMode = .byTruncatingMiddle
        field.delegate = context.coordinator
        field.cell?.usesSingleLineMode = true
        // Focus + select the base name (Finder selects everything before the dot).
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                let ns = initialName as NSString
                let extLen = (ns.pathExtension as NSString).length
                let baseLen = (!isDirectory && extLen > 0)
                    ? ns.length - extLen - 1 : ns.length
                editor.selectedRange = NSRange(location: 0, length: max(0, baseLen))
            }
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {}

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: InlineRenameField
        private var done = false

        init(_ parent: InlineRenameField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                finish { self.parent.onCommit(control.stringValue) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish { self.parent.onCancel() }
                return true
            default:
                return false
            }
        }

        // Clicking elsewhere ends editing → commit (Finder behaviour).
        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            finish { self.parent.onCommit(field.stringValue) }
        }

        private func finish(_ action: () -> Void) {
            guard !done else { return }
            done = true
            action()
        }
    }
}
