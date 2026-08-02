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

    T.group("seek-bar scrub state machine") {
        // Playerless engine: the state transitions are what desynced lyrics/
        // slider from the audio (#103 — a seek fired per drag tick).
        MainActor.assumeIsolated {
            let e = AudioPreviewEngine()
            e.beginScrub()
            T.expect(e.scrubbing, "drag start enters scrub mode")
            e.scrub(to: 30)
            T.equal(e.position, 30, "mid-drag only the display position moves")
            e.scrub(to: 45)
            e.endScrub()
            T.expect(!e.scrubbing, "release leaves scrub mode")
            T.equal(e.position, 45, "release seeks to the last dragged position")
            e.scrub(to: 10)
            T.equal(e.position, 10, "a set with no drag session seeks immediately")
            e.endScrub()
            T.equal(e.position, 10, "endScrub outside a session is a no-op")
        }
    }

    T.group("LRC synced-lyrics parser") {
        // Typical embedded LRC: metadata tags, stamped lines, out-of-order OK.
        let lrc = """
        [ti:사랑하게 될 거야]
        [ar:한로로]
        [00:12.50]첫 번째 줄
        [00:20]두 번째 줄
        [00:05.1]인트로
        [00:31.00]세 번째 줄
        """
        let synced = AudioLyrics.parseSynced(lrc)
        T.equal(synced?.count, 4, "stamped lines parsed, metadata tags dropped")
        T.equal(synced?.first?.text, "인트로", "sorted by time (out-of-order input)")
        T.equal(synced?.first?.time, 5.1, "mm:ss.x stamp → seconds")
        T.equal(synced?[1].time, 12.5, "mm:ss.xx stamp → seconds")
        T.equal(synced?[2].time, 20, "bare mm:ss stamp → seconds")

        // Repeated chorus: several stamps on one line fan out to one entry each.
        let chorus = "[00:10]a\n[00:30][01:30]후렴\n[00:50]b\n[01:10]c"
        let fan = AudioLyrics.parseSynced(chorus)
        T.equal(fan?.count, 5, "multi-stamp line fans out per stamp")
        T.equal(fan?.last?.text, "후렴", "fanned entry keeps the shared text")

        // [offset:+ms] shifts every stamp earlier (lyrics show sooner).
        let shifted = AudioLyrics.parseSynced("[offset:+500]\n[00:10]a\n[00:20]b\n[00:30]c\n[00:40]d")
        T.equal(shifted?.first?.time, 9.5, "positive offset pulls stamps earlier")

        // Plain lyrics (no stamps) and near-plain (one stray stamp) stay unsynced.
        T.isNil(AudioLyrics.parseSynced("그냥 가사\n두 번째 줄"), "no stamps → nil (plain view)")
        T.isNil(AudioLyrics.parseSynced("[00:01]한 줄만\n나머지는 평문\n셋\n넷\n다섯"),
                "a stray stamp in plain lyrics → still nil")

        // Brackets that aren't tags belong to the text, not the parser.
        let bracket = AudioLyrics.parseSynced("[00:01]a\n[00:02][Verse 1] 시작\n[00:03]b\n[00:04]c")
        T.equal(bracket?[1].text, "[Verse 1] 시작", "non-tag bracket survives as lyric text")
    }

    T.group("FLAC VORBIS_COMMENT lyrics parser") {
        func be24(_ n: Int) -> Data { Data([UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]) }
        func le32(_ n: Int) -> Data { Data([UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)]) }
        // Vorbis comment: vendor + 2 fields, LITTLE-endian lengths (the one
        // part of FLAC that isn't big-endian — the parser must not mix them up).
        let vendor = Data("anf-test".utf8)
        let artist = Data("ARTIST=한로로".utf8)
        let lyric = Data("LYRICS=사랑하게 될 거야\n두 번째 줄".utf8)
        var vc = le32(vendor.count) + vendor + le32(2)
        vc += le32(artist.count) + artist
        vc += le32(lyric.count) + lyric

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anfflac2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var flac = Data("fLaC".utf8)
        flac += Data([0x80 | 4]) + be24(vc.count) + vc          // type 4, last
        let f = dir.appendingPathComponent("lyr.flac")
        try? flac.write(to: f)
        T.equal(AudioLyrics.flacLyrics(url: f), "사랑하게 될 거야\n두 번째 줄",
                "LYRICS field extracted (UTF-8, little-endian lengths honored)")

        // No lyrics field → nil; garbage → nil, no crash.
        var bare = Data("fLaC".utf8)
        let vc2 = le32(vendor.count) + vendor + le32(1) + le32(artist.count) + artist
        bare += Data([0x80 | 4]) + be24(vc2.count) + vc2
        let g = dir.appendingPathComponent("nolyr.flac")
        try? bare.write(to: g)
        T.isNil(AudioLyrics.flacLyrics(url: g), "no LYRICS field → nil")
        let junk2 = dir.appendingPathComponent("junk2.flac")
        try? Data([0xFF, 0x00]).write(to: junk2)
        T.isNil(AudioLyrics.flacLyrics(url: junk2), "garbage → nil")
    }
}
