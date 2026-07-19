import Foundation
@testable import anf

/// Bursts the volume-detection that N-005/N-006 rely on. `FileTransfer` chooses
/// copy/move concurrency by volume; if `volumeID` can't actually distinguish two
/// volumes, a cross-volume (local↔network) move silently stays serial — the exact
/// slowness N-006 claimed to fix.
///
/// Traced 2026-06-14: `volumeID(of:)` does `resourceValues(.volumeIdentifierKey)
/// .volumeIdentifier as? Int`, but `volumeIdentifier` is an opaque
/// `NSCopying & NSSecureCoding & NSObject` (e.g. `<67456400 00000000>`), NOT an
/// Int — so the cast is ALWAYS nil. Then `sameVolume = nil == nil = true` for every
/// pair, and the move path always picks `cap = 1` (serial). N-006 is a no-op.
func runVolumeDetectionTests() {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory

    T.group("FileTransfer.isLocalVolume") {
        // This part works (uses volumeIsLocalKey, not the broken Int cast).
        T.expect(FileTransfer.isLocalVolume(tmp), "temp dir reports local")
        T.expect(FileTransfer.isLocalVolume(URL(fileURLWithPath: "/")), "root reports local")
    }

    T.group("FileTransfer.volumeID — N-006 burst (expected RED until fixed)") {
        // Must identify the volume. Currently nil → cross-volume move never
        // parallelized. This assertion fails today; it is the regression guard.
        T.notNil(FileTransfer.volumeID(of: tmp),
                 "volumeID must identify a volume (nil ⇒ sameVolume always true ⇒ cross-volume move stays serial, N-006)")

        // Two dirs on the SAME volume must compare equal AND non-nil. With the bug
        // they compare equal only because both are nil — a false positive.
        let a = tmp.appendingPathComponent("vol-a")
        let b = tmp.appendingPathComponent("vol-b")
        let ia = FileTransfer.volumeID(of: a), ib = FileTransfer.volumeID(of: b)
        T.expect(ia != nil && ia == ib, "same-volume dirs share a non-nil volumeID")
    }

    // The actual N-006 requirement: a DIFFERENT mounted volume must get a
    // different id, so a cross-volume (local↔network) move is detected and
    // parallelized. Deliberately NOT scanning /Volumes: statting every external/
    // network mount fires a TCC removable-volume prompt per disk, and the rebuilt
    // test binary re-asks on every run. A tiny attached disk image is a real
    // second volume with no TCC prompt — and unlike the old scan (which silently
    // skipped single-volume machines), it exists everywhere.
    T.group("FileTransfer.volumeID — cross-volume detection") {
        let img = tmp.appendingPathComponent("anf-vol-\(UUID().uuidString).dmg")
        defer { try? fm.removeItem(at: img) }
        ExternalTools.run("/usr/bin/hdiutil",
                          ["create", "-size", "4m", "-fs", "HFS+J",
                           "-volname", "anf-test-vol", "-quiet", img.path],
                          timeout: 30)
        // Attach output: "/dev/diskN <tab> Apple_HFS <tab> /Volumes/anf-test-vol"
        let mount = ExternalTools.run("/usr/bin/hdiutil",
                                      ["attach", img.path, "-nobrowse"], timeout: 30)
            .compactMap { $0.components(separatedBy: "\t").last?
                .trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/Volumes/") }
        guard let mount else { return }   // hdiutil unavailable — skip, not a failure
        defer { ExternalTools.run("/usr/bin/hdiutil", ["detach", mount, "-quiet"], timeout: 30) }

        let rootID = FileTransfer.volumeID(of: URL(fileURLWithPath: "/"))
        let otherID = FileTransfer.volumeID(of: URL(fileURLWithPath: mount))
        T.notNil(otherID, "attached image volume gets an id")
        T.expect(otherID != rootID,
                 "a separate volume gets a distinct id (⇒ cross-volume move parallelizes, N-006)")
    }
}
