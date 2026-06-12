import AppKit
@testable import anf

/// Tags round-trip through the real macOS tag xattrs.
func runFileTagsTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("anftag-\(UUID().uuidString).txt")
        try? "x".write(to: url, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: url) }

        T.group("FileTags round-trip") {
            T.expect(FileTags.tags(of: url).isEmpty, "starts with no tags")

            FileTags.toggle("Red", on: url)
            T.expect(FileTags.tags(of: url).contains("Red"), "toggle adds the tag")
            T.equal(FileTags.color(for: "Red"), .systemRed, "Red maps to the system colour")

            FileTags.toggle("Blue", on: url)
            let names = Set(FileTags.tags(of: url))
            T.expect(names.contains("Red") && names.contains("Blue"), "second tag adds, doesn't replace")

            FileTags.toggle("Red", on: url)
            T.expect(!FileTags.tags(of: url).contains("Red"), "toggle again removes")
            T.expect(FileTags.tags(of: url).contains("Blue"), "Blue still present")

            // Cache returns the first standard colour and survives clears.
            FileTags.clearColorCache()
            T.equal(FileTags.primaryColor(of: url), .systemBlue, "primary colour is the remaining tag")
        }
    }
}
