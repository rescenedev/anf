import Foundation
@testable import anf

/// FileTransfer correctness: the expanded child-by-child copy of a single big
/// folder must produce an identical tree and register a single top-level undo
/// target (not one per child).
func runTransferTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("anfxfer-\(UUID().uuidString)")
        let src = base.appendingPathComponent("big")
        let destDir = base.appendingPathComponent("dest")
        do {
            try fm.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            for i in 0..<40 {   // ≥16 children triggers the expansion path
                try "data-\(i)".write(to: src.appendingPathComponent("f\(i).txt"),
                                      atomically: true, encoding: .utf8)
            }
            try "deep".write(to: src.appendingPathComponent("sub/deep.txt"),
                             atomically: true, encoding: .utf8)
        } catch { T.expect(false, "fixture setup threw: \(error)"); return }
        defer { try? fm.removeItem(at: base) }

        T.group("FileTransfer: expanded folder copy") {
            var finished = false
            FileTransfer.shared.transfer([src], into: destDir, move: false) { finished = true }
            let deadline = Date().addingTimeInterval(10)
            while !finished && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            T.expect(finished, "transfer completed")

            let copied = destDir.appendingPathComponent("big")
            let names = (try? fm.contentsOfDirectory(atPath: copied.path)) ?? []
            T.equal(names.count, 41, "all 41 children copied")
            let deep = copied.appendingPathComponent("sub/deep.txt")
            T.equal((try? String(contentsOf: deep, encoding: .utf8)), "deep",
                    "nested content survives the child-by-child copy")

            // Undo removes the single top-level destination, not 41 leftovers.
            T.expect(FileUndo.shared.undo(), "undo reports success")
            T.expect(!fm.fileExists(atPath: copied.path), "undo removed the copied folder root")
            T.expect(fm.fileExists(atPath: src.path), "source untouched by undo")
        }

        T.group("byte-progress tracking applies to small file batches only (#63)") {
            let fileA = src.appendingPathComponent("f0.txt")   // exists from fixture
            let fileB = src.appendingPathComponent("f1.txt")
            // A regular file → byte-trackable, with a positive total.
            let one = FileTransfer.byteTrackTotal(of: [fileA])
            T.expect(one != nil && one! > 0, "a single regular file is byte-trackable")
            T.expect(FileTransfer.byteTrackTotal(of: [fileA, fileB]) != nil, "a few files are byte-trackable")
            // A directory → fall back to item-count progress (avoid sizing a tree).
            T.equal(FileTransfer.byteTrackTotal(of: [src]), nil, "a directory is NOT byte-tracked")
            T.equal(FileTransfer.byteTrackTotal(of: []), nil, "empty input → nil")
            // bytesPresent sums what's on disk.
            T.expect(FileTransfer.bytesPresent(at: [fileA]) > 0, "bytesPresent reads a real file")
            T.equal(FileTransfer.bytesPresent(at: [src.appendingPathComponent("nope")]), 0,
                    "a missing path contributes 0 bytes")
            // Progress MUST follow logical size (EOF), not allocated blocks: a
            // copy's destination has its allocated size preallocated full up
            // front, so allocated size would peg the bar near 100% the whole copy
            // (the reported display bug). A sparse file proves which one we read:
            // logical 4MB, allocated ~0.
            let sparse = src.appendingPathComponent("sparse.bin")
            fm.createFile(atPath: sparse.path, contents: nil)
            if let fh = try? FileHandle(forWritingTo: sparse) {
                try? fh.truncate(atOffset: 4_000_000)   // logical EOF = 4MB, no blocks written
                try? fh.close()
            }
            T.equal(FileTransfer.bytesPresent(at: [sparse]), 4_000_000,
                    "bytesPresent reports the logical EOF, not the (near-zero) allocated size")
            T.equal(FileTransfer.byteTrackTotal(of: [sparse]), 4_000_000,
                    "byteTrackTotal uses logical size too, so the fraction reaches 100%")
        }

        T.group("transfer HUD label: name for one item, count for many (#63)") {
            let f = src.appendingPathComponent("report.zip")
            T.equal(FileTransfer.transferLabel(verb: "Copying", count: 1, first: f),
                    "Copying report.zip", "single item shows its name")
            let many = FileTransfer.transferLabel(verb: "Copying", count: 7, first: f)
            T.expect(many.contains("7"), "a batch shows the count")
            T.expect(!many.contains("report.zip"), "a batch does not show a single name")
        }
    }
}
