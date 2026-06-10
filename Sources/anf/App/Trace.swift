import Foundation

/// Append-only diagnostics for the resize/move event path, written to
/// /tmp/anf-trace.log. Cheap (only logs discrete events like mouseDown), so it
/// stays on — it is the only way to see what a real mouse hits in the field.
enum Trace {
    private static let url = URL(fileURLWithPath: "/tmp/anf-trace.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
