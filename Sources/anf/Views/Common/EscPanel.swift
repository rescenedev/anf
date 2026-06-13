import AppKit

/// An NSPanel that closes on Esc (and ⌘W) without needing a mouse click — used
/// by the floating info/AI panels. Esc reaches a window as `cancelOperation`
/// only when no field consumes it, which is exactly what we want for these
/// button/list panels.
final class EscPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { performClose(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { performClose(nil); return }                 // Esc
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "w" { performClose(nil); return }  // ⌘W
        super.keyDown(with: event)
    }
}
