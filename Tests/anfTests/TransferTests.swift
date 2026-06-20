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
            // byteTrackTotal uses logical size (a sparse file proves it: logical
            // 4MB, allocated ~0) so the fraction can actually reach 100%.
            let sparse = src.appendingPathComponent("sparse.bin")
            fm.createFile(atPath: sparse.path, contents: nil)
            if let fh = try? FileHandle(forWritingTo: sparse) {
                try? fh.truncate(atOffset: 4_000_000)   // logical EOF = 4MB, no blocks written
                try? fh.close()
            }
            T.equal(FileTransfer.byteTrackTotal(of: [sparse]), 4_000_000,
                    "byteTrackTotal uses logical size, so the fraction reaches 100%")
        }

        T.group("copyFileCancellable: correct copy + clean failure (#63)") {
            // NOTE: live progress and mid-file cancellation only happen on a REAL
            // data copy (cross-volume) — a same-volume copy here is an instant
            // APFS clone that bypasses copyfile's status callback entirely, so
            // those paths are verified cross-volume (RAM disk) by hand, not here.
            // The outer transfer loop also catches a pre-set cancel before calling
            // this, so what matters same-volume is correctness + failure handling.
            let from = src.appendingPathComponent("f2.txt")
            try? "hello copyfile".write(to: from, atomically: true, encoding: .utf8)
            let to = destDir.appendingPathComponent("f2-copy.txt")
            let ok = FileTransfer.copyFileCancellable(from: from, to: to, cancel: CancelFlag()) { _ in }
            T.equal(ok, .copied, "copy reports success")
            T.equal((try? String(contentsOf: to, encoding: .utf8)), "hello copyfile", "content matches the source")
            // A bad destination (missing parent dir) → .failed, no file created.
            let bad = src.appendingPathComponent("nope-dir/x.txt")
            if case .failed = FileTransfer.copyFileCancellable(from: from, to: bad, cancel: CancelFlag(), onProgress: { _ in }) {
                T.expect(true, "copy into a missing directory fails cleanly")
            } else {
                T.expect(false, "expected .failed for a missing destination directory")
            }
            T.expect(!fm.fileExists(atPath: bad.path), "no partial left after a failed copy")
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
