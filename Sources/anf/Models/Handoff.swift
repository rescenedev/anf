import Foundation

/// One-way transfer of a non-Sendable value across an isolation boundary.
/// Correct ONLY for hand-offs: the producer builds the value, wraps it, and
/// never touches it again; the consumer unwraps once. NSAttributedString built
/// in a detached task and consumed on the main actor is the canonical case.
struct Handoff<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
