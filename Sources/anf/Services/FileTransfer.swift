import AppKit
import Observation

/// Conflict policy for copying/moving into a folder that already has an item
/// with the same name.
enum ConflictPolicy {
    case keepBoth    // auto-rename "name 2"
    case overwrite   // trash the existing item first (recoverable)
    case skip
}

/// Cross-thread cancellation checked between items WITHOUT a MainActor hop —
/// awaiting the main actor once per item costs seconds across 26k items.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// All copy/move traffic goes through here: name-conflict resolution up front,
/// the work itself off the main thread with byte-progress + cancellation, undo
/// registration and one error alert at the end. Small jobs never show UI.
@MainActor
@Observable
final class FileTransfer {
    static let shared = FileTransfer()

    // Progress HUD state (read by the SwiftUI overlay).
    private(set) var isActive = false
    private(set) var label = ""
    private(set) var fraction: Double = 0
    private var cancelRequested = false
    private var cancelFlag: CancelFlag?
    /// Bumped per job so a stale delayed-HUD task can't resurrect the overlay.
    private var jobGeneration = 0
    private var jobDone = true

    func cancel() {
        cancelRequested = true
        cancelFlag?.set()
    }

    /// Copy or move `sources` into `destination`. Asks once about name conflicts,
    /// shows a progress HUD for big jobs, records undo, reports errors, then
    /// calls `completion` on the main actor.
    func transfer(_ sources: [URL], into destination: URL, move: Bool,
                  completion: @escaping () -> Void = {}) {
        let sources = sources.filter { $0.deletingLastPathComponent().path != destination.path || !move }
        guard !sources.isEmpty else { completion(); return }

        // 1) Resolve name conflicts up front, once for the whole batch.
        let conflicts = sources.filter {
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent($0.lastPathComponent).path)
        }
        var policy: ConflictPolicy = .keepBoth
        if !conflicts.isEmpty {
            guard let chosen = Self.askConflict(count: conflicts.count,
                                                first: conflicts[0].lastPathComponent) else {
                completion(); return   // cancelled
            }
            policy = chosen
        }

        // 2) Plan: (src, dest) pairs after applying the policy.
        var plan: [(src: URL, dest: URL)] = []
        var overwriteVictims: [URL] = []
        for src in sources {
            let plain = destination.appendingPathComponent(src.lastPathComponent)
            if FileManager.default.fileExists(atPath: plain.path) {
                switch policy {
                case .skip: continue
                case .keepBoth:
                    plan.append((src, FileOperations.uniqueURL(for: src.lastPathComponent,
                                                               in: destination)))
                case .overwrite:
                    overwriteVictims.append(plain)
                    plan.append((src, plain))
                }
            } else {
                plan.append((src, plain))
            }
        }
        guard !plan.isEmpty else { completion(); return }

        // Overwrite = trash the existing items first, so it's recoverable.
        if !overwriteVictims.isEmpty {
            let victims = overwriteVictims.compactMap { FileItem(url: $0) }
            FileOperations.moveToTrash(victims)
        }

        // 3) EVERYTHING heavy runs off the main thread; the HUD is time-based —
        // it appears only if the job is still running after 400ms, so small
        // jobs never flash UI. Progress is item-count based: pre-sizing a
        // 26k-entry tree cost ~1s (and used to beachball right here) for
        // nothing more than fraction weighting.
        let verb = move ? L("Moving…", "이동 중…") : L("Copying…", "복사 중…")

        cancelRequested = false
        let flag = CancelFlag()
        cancelFlag = flag
        jobGeneration &+= 1
        let gen = jobGeneration
        jobDone = false
        fraction = 0
        label = L("Preparing…", "준비 중…")

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, self.jobGeneration == gen, !self.jobDone else { return }
            self.isActive = true
        }

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                () -> (done: [(from: URL, to: URL)], undoCreated: [URL], failures: [String]) in
                let fm = FileManager.default
                var failures: [String] = []

                // A single big folder copies child-by-child: APFS clones per
                // file either way, but this gives real progress and lets cancel
                // actually stop mid-tree instead of after the whole folder.
                var work = plan
                var expandedRoot: URL?
                if !move, plan.count == 1,
                   (try? plan[0].src.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                   let kids = try? fm.contentsOfDirectory(at: plan[0].src,
                                                          includingPropertiesForKeys: nil,
                                                          options: []),
                   kids.count >= 16,
                   (try? fm.createDirectory(at: plan[0].dest,
                                            withIntermediateDirectories: false)) != nil {
                    expandedRoot = plan[0].dest
                    work = kids.map { ($0, plan[0].dest.appendingPathComponent($0.lastPathComponent)) }
                }

                await MainActor.run {
                    self?.label = verb + L(" (\(work.count) items)", " (\(work.count)개 항목)")
                }

                var done: [(URL, URL)] = []
                // Concurrency by volume: a same-volume move is an instant metadata
                // rename → serial. A local APFS copy clones cheaply → every core. But
                // a NETWORK copy/move (real bytes over one SMB connection) thrashes if
                // we open dozens of streams → cap at 4. Cross-volume move = real
                // copy+delete (moveItem does it internally), so it's capped too — and
                // now actually parallel instead of serial (N-006).
                let destDir = plan[0].dest.deletingLastPathComponent()
                let sameVolume = Self.volumeID(of: plan[0].src) == Self.volumeID(of: destDir)
                let destLocal = Self.isLocalVolume(destDir)
                let cap = (move && sameVolume) ? 1 : (destLocal ? ProcessInfo.processInfo.activeProcessorCount : 4)
                let lock = NSLock()
                var completed = 0
                var lastPushed = ContinuousClock.now
                Self.boundedForEach(work.count, maxConcurrent: cap) { i in
                    if flag.isSet { return }
                    let (src, dest) = work[i]
                    var okPair: (URL, URL)?
                    var failure: String?
                    do {
                        if move { try FileManager.default.moveItem(at: src, to: dest) }
                        else    { try FileManager.default.copyItem(at: src, to: dest) }
                        okPair = (src, dest)
                    } catch {
                        failure = "\(src.lastPathComponent): \(error.localizedDescription)"
                    }
                    lock.lock()
                    if let okPair { done.append(okPair) }
                    if let failure { failures.append(failure) }
                    completed += 1
                    let n = completed
                    let now = ContinuousClock.now
                    let push = now - lastPushed > .milliseconds(80) || n == work.count
                    if push { lastPushed = now }
                    lock.unlock()
                    if push {
                        let f = Double(n) / Double(work.count)
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            MainActor.assumeIsolated { self.fraction = min(f, 1) }
                        }
                    }
                }
                // Undo for an expanded folder targets the top-level destination,
                // not 26k children.
                let undoCreated = expandedRoot.map { [$0] } ?? done.map(\.1)
                return (done, undoCreated, failures)
            }.value

            guard let self else { return }
            self.jobDone = true
            self.isActive = false
            if !result.done.isEmpty {
                FileUndo.shared.record(move
                    ? .move(result.done.map { (from: $0.from, to: $0.to) })
                    : .created(result.undoCreated))
            }
            if self.cancelRequested {
                FileOperations.presentFailures(
                    move ? L("Move cancelled", "이동이 취소되었습니다") : L("Copy cancelled", "복사가 취소되었습니다"),
                    [L("\(result.done.count) completed item(s) were kept.", "완료된 \(result.done.count)개 항목은 유지됩니다.")])
            }
            FileOperations.presentFailures(move ? L("Couldn’t move", "이동하지 못했습니다") : L("Couldn’t copy", "복사하지 못했습니다"),
                                           result.failures)
            completion()
        }
    }

    // MARK: - Helpers

    /// One batch-level question, Finder-style.
    private static func askConflict(count: Int, first: String) -> ConflictPolicy? {
        let alert = NSAlert()
        alert.messageText = count == 1
            ? L("An item named ‘\(first)’ already exists", "‘\(first)’ 항목이 이미 있습니다")
            : L("\(count) items with the same names already exist", "같은 이름의 항목이 \(count)개 있습니다")
        alert.informativeText = L("Keep Both numbers the copies. Overwritten items are moved to the Trash.", "둘 다 유지하면 복사본에 번호가 붙습니다. 덮어쓰기한 기존 항목은 휴지통으로 이동합니다.")
        alert.addButton(withTitle: L("Keep Both", "둘 다 유지"))
        alert.addButton(withTitle: L("Overwrite", "덮어쓰기"))
        alert.addButton(withTitle: L("Skip", "건너뛰기"))
        alert.addButton(withTitle: L("Cancel", "취소"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .overwrite
        case .alertThirdButtonReturn: return .skip
        default: return nil
        }
    }

    /// Volume identifier for cross-volume move detection (nil on failure). Uses the
    /// device number (`st_dev`) — `URLResourceValues.volumeIdentifier` is an opaque
    /// object, never an `Int`, so the old `as? Int` cast was always nil (and made
    /// every move look same-volume → N-006 never parallelized). Walks up to the
    /// nearest existing ancestor so a not-yet-created destination still resolves.
    nonisolated static func volumeID(of url: URL) -> Int? {
        var dir = url
        while true {
            var s = stat()
            if stat(dir.path, &s) == 0 { return Int(s.st_dev) }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }   // reached "/" without a hit
            dir = parent
        }
    }

    /// Whether `url`'s volume is local (vs a network share). Defaults to local when
    /// unknown. Off-main only — `resourceValues` blocks on a stale mount.
    nonisolated static func isLocalVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? true
    }

    /// Run `body(0..<count)` with at most `maxConcurrent` running at once. Full-core
    /// → `concurrentPerform`; capped → a semaphore-bounded dispatch (so a network
    /// copy/move doesn't open dozens of byte streams over one SMB connection).
    /// Blocks the caller until done — call OFF the main thread.
    nonisolated static func boundedForEach(_ count: Int, maxConcurrent: Int,
                                           _ body: @escaping (Int) -> Void) {
        let cap = Swift.max(1, maxConcurrent)
        if count <= 1 || cap == 1 {
            for i in 0..<count { body(i) }
            return
        }
        if cap >= ProcessInfo.processInfo.activeProcessorCount {
            DispatchQueue.concurrentPerform(iterations: count, execute: body)
            return
        }
        let sem = DispatchSemaphore(value: cap)
        let group = DispatchGroup()
        let q = DispatchQueue.global(qos: .userInitiated)
        for i in 0..<count {
            sem.wait()
            group.enter()
            q.async { body(i); sem.signal(); group.leave() }
        }
        group.wait()
    }

    /// Recursive size of `urls` (files + directory contents).
    nonisolated static func totalSize(of urls: [URL]) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isDirectoryKey]
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: keys) else { continue }
            if v.isDirectory == true {
                guard let en = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                             options: []) else { continue }
                for case let f as URL in en {
                    let fv = try? f.resourceValues(forKeys: keys)
                    if fv?.isRegularFile == true { total += Int64(fv?.fileSize ?? 0) }
                }
            } else {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }
}
