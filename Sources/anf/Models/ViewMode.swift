import SwiftUI

enum ViewMode: String, CaseIterable, Identifiable {
    case icons, list, columns, gallery
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .icons:   return "square.grid.2x2"
        case .list:    return "list.bullet"
        case .columns: return "rectangle.split.3x1"
        case .gallery: return "square.stack"
        }
    }

    var title: String {
        switch self {
        case .icons:   return "Icons"
        case .list:    return "List"
        case .columns: return "Columns"
        case .gallery: return "Gallery"
        }
    }
}

enum SortKey: String, CaseIterable, Identifiable {
    case name, dateModified, size, kind
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "Name"
        case .dateModified: return "Date Modified"
        case .size: return "Size"
        case .kind: return "Kind"
        }
    }
}

struct SortOrder: Equatable {
    var key: SortKey = .name
    var ascending: Bool = true
}
