// MARK: - Tab
import Foundation

struct Tab: Identifiable {
    let id = UUID()
    var name: String
    var url: URL
    var isLocked: Bool = false

    mutating func lock() {
        isLocked = true
    }

    mutating func unlock() {
        isLocked = false
    }
}
