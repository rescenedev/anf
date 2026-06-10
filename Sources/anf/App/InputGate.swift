import Foundation

/// Global gate the window-level mouse monitors consult before consuming events.
/// While a modal-ish SwiftUI overlay (the command palette) is up, the resizers
/// and the divider router must stand down so clicks reach the overlay.
@MainActor
enum InputGate {
    /// True while the command palette (or any full-cover overlay) is visible.
    static var modalActive = false
}
