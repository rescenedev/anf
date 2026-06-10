import Foundation

enum Format {
    static let size: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    static func bytes(_ n: Int64) -> String { size.string(fromByteCount: n) }
    static func when(_ d: Date) -> String { d == .distantPast ? "—" : date.string(from: d) }

    static func kind(_ item: FileItem) -> String {
        if item.isApplication { return "Application" }
        if item.isBrowsableContainer { return "Folder" }
        return item.contentType?.localizedDescription
            ?? (item.ext.isEmpty ? "Document" : "\(item.ext.uppercased()) File")
    }
}
