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
    // parallelized. Machine-independent: scan /Volumes for any mount whose id
    // differs from root; skip if the machine has no second volume.
    T.group("FileTransfer.volumeID — cross-volume detection") {
        let rootID = FileTransfer.volumeID(of: URL(fileURLWithPath: "/"))
        let mounts = (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? []
        let other = mounts
            .map { FileTransfer.volumeID(of: URL(fileURLWithPath: "/Volumes/\($0)")) }
            .first { $0 != nil && $0 != rootID }
        if let other {
            T.expect(other != rootID,
                     "a separate volume gets a distinct id (⇒ cross-volume move parallelizes, N-006)")
        }
        // else: single-volume machine — nothing to compare, not a failure.
    }
}
