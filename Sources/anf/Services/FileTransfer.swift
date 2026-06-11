import AppKit
import Observation

/// Conflict policy for copying/moving into a folder that already has an item
/// with the same name.
enum ConflictPolicy {
    case keepBoth    // auto-rename "name 2"
    case overwrite   // trash the existing item first (recoverable)
    case skip
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

    /// Jobs smaller than this finish silently (no HUD flash).
    private let hudThresholdBytes: Int64 = 64 * 1024 * 1024   // 64 MB

    func cancel() { cancelRequested = true }

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

        // 3) Size each top-level item ONCE (the per-item progress loop reuses the
        // same numbers — sizing twice doubled the enumeration of big trees).
        // A same-volume move is metadata-only (instant, no HUD); a cross-volume
        // move degrades to copy+delete, so it gets sized + a HUD like a copy.
        let crossVolume = move && Self.volumeID(of: destination) != Self.volumeID(of: plan[0].src)
        let needsSizing = !move || crossVolume
        let itemSizes: [Int64] = needsSizing ? plan.map { Self.totalSize(of: [$0.src]) } : []
        let totalBytes = itemSizes.reduce(0, +)
        let showHUD = needsSizing && totalBytes > hudThresholdBytes

        if showHUD {
            isActive = true
            fraction = 0
            cancelRequested = false
            label = (move ? "이동 중…" : "복사 중…") + " (\(plan.count)개 항목)"
        }

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                () -> (done: [(from: URL, to: URL)], failures: [String]) in
                var done: [(URL, URL)] = []
                var failures: [String] = []
                var copied: Int64 = 0
                var lastPushed = ContinuousClock.now
                let fm = FileManager.default
                for (i, pair) in plan.enumerated() {
                    let (src, dest) = pair
                    if await self?.cancelRequested == true { break }
                    do {
                        if move { try fm.moveItem(at: src, to: dest) }
                        else { try fm.copyItem(at: src, to: dest) }
                        done.append((src, dest))
                    } catch {
                        failures.append("\(src.lastPathComponent): \(error.localizedDescription)")
                    }
                    if showHUD {
                        copied += itemSizes[i]
                        // Throttle main-actor hops: thousands of small files would
                        // otherwise queue thousands of UI updates.
                        let now = ContinuousClock.now
                        if now - lastPushed > .milliseconds(80) || i == plan.count - 1 {
                            lastPushed = now
                            let f = totalBytes > 0 ? Double(copied) / Double(totalBytes) : 1
                            await MainActor.run { self?.fraction = min(f, 1) }
                        }
                    }
                }
                return (done, failures)
            }.value

            guard let self else { return }
            self.isActive = false
            if !result.done.isEmpty {
                FileUndo.shared.record(move
                    ? .move(result.done.map { (from: $0.from, to: $0.to) })
                    : .created(result.done.map(\.to)))
            }
            if self.cancelRequested {
                FileOperations.presentFailures(
                    "복사가 취소되었습니다",
                    ["완료된 \(result.done.count)개 항목은 유지됩니다."])
            }
            FileOperations.presentFailures(move ? "이동하지 못했습니다" : "복사하지 못했습니다",
                                           result.failures)
            completion()
        }
    }

    // MARK: - Helpers

    /// One batch-level question, Finder-style.
    private static func askConflict(count: Int, first: String) -> ConflictPolicy? {
        let alert = NSAlert()
        alert.messageText = count == 1
            ? "‘\(first)’ 항목이 이미 있습니다"
            : "같은 이름의 항목이 \(count)개 있습니다"
        alert.informativeText = "둘 다 유지하면 복사본에 번호가 붙습니다. 덮어쓰기한 기존 항목은 휴지통으로 이동합니다."
        alert.addButton(withTitle: "둘 다 유지")
        alert.addButton(withTitle: "덮어쓰기")
        alert.addButton(withTitle: "건너뛰기")
        alert.addButton(withTitle: "취소")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .overwrite
        case .alertThirdButtonReturn: return .skip
        default: return nil
        }
    }

    /// Volume identifier for cross-volume move detection (nil on failure).
    nonisolated static func volumeID(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?
            .volumeIdentifier as? Int
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
