import Foundation

/// Minimal assertion harness — no XCTest/Swift-Testing (unavailable with Command
/// Line Tools). Each `expect*` records a failure; the runner exits non-zero if any.
enum T {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var checks = 0

    private static func loc(_ f: String, _ l: Int) -> String {
        "\((f as NSString).lastPathComponent):\(l)"
    }

    static func expect(_ cond: Bool, _ msg: String, file: String = #fileID, line: Int = #line) {
        checks += 1
        if !cond { failures.append("✗ \(msg)  [\(loc(file, line))]") }
    }

    static func equal<V: Equatable>(_ a: V, _ b: V, _ msg: String = "",
                                    file: String = #fileID, line: Int = #line) {
        checks += 1
        if a != b { failures.append("✗ \(msg) — expected \(b), got \(a)  [\(loc(file, line))]") }
    }

    static func notNil<V>(_ v: V?, _ msg: String, file: String = #fileID, line: Int = #line) {
        checks += 1
        if v == nil { failures.append("✗ \(msg) — was nil  [\(loc(file, line))]") }
    }

    static func isNil<V>(_ v: V?, _ msg: String, file: String = #fileID, line: Int = #line) {
        checks += 1
        if v != nil { failures.append("✗ \(msg) — expected nil  [\(loc(file, line))]") }
    }

    /// Run a named group; catches throws so one group can't abort the rest.
    static func group(_ name: String, _ body: () throws -> Void) {
        do { try body() }
        catch { failures.append("✗ \(name) threw: \(error)") }
    }
}
