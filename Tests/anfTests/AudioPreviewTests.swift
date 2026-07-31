import Foundation
@testable import anf

/// #103: the inspector's native audio player. The playable/artwork I/O needs a
/// GUI, but the two pure parts are testable: the audio-type routing predicate
/// (which decides QL vs native player) and the hand-rolled FLAC PICTURE-block
/// parser (QL showed no art for FLAC — this is the replacement).
func runAudioPreviewTests() {
    T.group("audio routing predicate") {
        func item(_ name: String) -> FileItem? {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("anfaud-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let u = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: u.path, contents: Data("x".utf8))
            return FileItem(fastURL: u)
        }
        for name in ["a.mp3", "b.M4A", "c.flac", "d.wav", "e.opus"] {
            T.expect(item(name).map(AudioPreview.isAudio) == true, "\(name) routes to the native player")
        }
        for name in ["a.mp4", "b.txt", "c.pdf", "d.mp3.bak"] {
            T.expect(item(name).map(AudioPreview.isAudio) == false, "\(name) does NOT route to the audio player")
        }
    }

    T.group("FLAC PICTURE block parser") {
        func be32(_ n: Int) -> Data { Data([UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]) }
        let img = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4])   // fake JPEG bytes
        let mime = Data("image/jpeg".utf8)
        // PICTURE payload: type(4) mimeLen mime descLen(0) w h depth colors dataLen data
        var pic = be32(3) + be32(mime.count) + mime + be32(0)
        pic += be32(500) + be32(500) + be32(24) + be32(0)
        pic += be32(img.count) + img
        // File: magic + a STREAMINFO-ish block (type 0) + PICTURE block (type 6, last)
        let padding = Data(repeating: 0, count: 34)
        var flac = Data("fLaC".utf8)
        flac += Data([0x00]) + be32(padding.count).dropFirst() + padding          // type 0, not last
        flac += Data([0x80 | 6]) + be32(pic.count).dropFirst() + pic              // type 6, last

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anfflac-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("art.flac")
        try? flac.write(to: good)
        T.equal(AudioArtwork.flacPicture(url: good), img, "PICTURE payload extracted byte-for-byte")

        // No PICTURE block → nil, no crash.
        var bare = Data("fLaC".utf8)
        bare += Data([0x80 | 0]) + be32(padding.count).dropFirst() + padding
        let none = dir.appendingPathComponent("noart.flac")
        try? bare.write(to: none)
        T.isNil(AudioArtwork.flacPicture(url: none), "no PICTURE block → nil")

        // Truncated/garbage file → nil, no crash.
        let junk = dir.appendingPathComponent("junk.flac")
        try? Data([0x01, 0x02, 0x03]).write(to: junk)
        T.isNil(AudioArtwork.flacPicture(url: junk), "garbage input → nil")
    }
}
