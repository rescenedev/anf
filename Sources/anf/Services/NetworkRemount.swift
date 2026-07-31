import AppKit
import NetFS

/// Remembers which network volumes were mounted and quietly remounts them on
/// the next launch (#101) — so a NAS share survives a reboot without a trip
/// through Finder, and the network tabs/pins that restore() now keeps come
/// back to life on their own.
///
/// How: every mounted non-local volume advertises the URL it was mounted FROM
/// (`volumeURLForRemounting`, e.g. smb://nas/share). We record those on mount
/// and at quit; at launch each remembered URL is remounted with
/// NetFSMountURLAsync in no-UI mode — credentials come from the login
/// Keychain, so a share the user ever connected to with "remember password"
/// mounts silently, and one without stored credentials just fails quietly
/// (no prompt storm at login).
///
/// Ejecting a share while anf runs removes it from the memory — an explicit
/// eject is a statement of intent, auto-remounting it next launch would fight
/// the user. Opt out entirely with `"remountNetworkVolumes": false` in ⌘,.
enum NetworkRemount {
    static let defaultsKey = "anf.networkRemounts.v1"
    private static let capacity = 8

    /// `"remountNetworkVolumes": false` in the ⌘, settings file disables both
    /// recording and remounting. Default on — the whole point of #101.
    nonisolated static var enabled: Bool {
        (Keymap.settingsDict(fileAt: Keymap.fileURL)["remountNetworkVolumes"] as? Bool) ?? true
    }

    /// Launch entry point: start observing mounts, then remount what we
    /// remember. Call once from applicationDidFinishLaunching; a headless
    /// test run never gets here (guarded by the caller).
    @MainActor static func start() {
        guard enabled else { return }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { _ in
            record()
        }
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { note in
            // The volume is gone, so its remount URL can't be read anymore —
            // match by the recorded mount path instead.
            if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                forget(mountPath: url.path)
            }
        }
        remountAll()
        // Capture the state a bit after launch too: volumes mounted before anf
        // started never fire didMount for us.
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            record()
        }
    }

    /// Merge the currently-mounted network volumes into the remembered list.
    /// Runs the volume walk off-main (resourceValues on a stalling mount blocks).
    nonisolated static func record() {
        guard enabled else { return }
        Task.detached(priority: .utility) {
            let current = mountedNetworkVolumes()
            guard !current.isEmpty else { return }   // never wipe memory on a quiet moment
            let merged = merge(remembered: stored(), current: current, cap: capacity)
            UserDefaults.standard.set(merged.map { [$0.remountURL, $0.mountPath] }, forKey: defaultsKey)
        }
    }

    /// Drop the entry for an ejected volume — the user said "disconnect".
    nonisolated static func forget(mountPath: String) {
        let kept = stored().filter { $0.mountPath != mountPath }
        UserDefaults.standard.set(kept.map { [$0.remountURL, $0.mountPath] }, forKey: defaultsKey)
    }

    /// Remount every remembered share that isn't already mounted. No UI: a
    /// share without Keychain credentials fails silently rather than throwing
    /// login prompts at the user's face on every launch.
    nonisolated static func remountAll() {
        Task.detached(priority: .utility) {
            let mountedNow = Set(mountedNetworkVolumes().map(\.remountURL))
            for entry in stored() where !mountedNow.contains(entry.remountURL) {
                guard let url = URL(string: entry.remountURL) else { continue }
                let open = NSMutableDictionary()
                open[kNAUIOptionKey as String] = kNAUIOptionNoUI
                let mount = NSMutableDictionary()
                mount[kNetFSAllowSubMountsKey as String] = true
                // Remount at the ORIGINAL location: a share mounted at a custom
                // path (e.g. ~/nas-mnt/zpool via the user's own setup) must come
                // back where the saved tabs/pins point, not at /Volumes/<name>.
                // /Volumes itself is system-managed (and root-owned) — let the
                // OS pick the default there by passing nil.
                var mountPoint: CFURL?
                if !entry.mountPath.hasPrefix("/Volumes/") {
                    try? FileManager.default.createDirectory(atPath: entry.mountPath,
                                                             withIntermediateDirectories: true)
                    mountPoint = URL(fileURLWithPath: entry.mountPath, isDirectory: true) as CFURL
                }
                var requestID: AsyncRequestID?
                NetFSMountURLAsync(url as CFURL, mountPoint, nil, nil,
                                   open, mount, &requestID,
                                   DispatchQueue.global(qos: .utility)) { status, _, _ in
                    if status != 0 {
                        // noisy-free: no credentials / server down — next launch retries.
                        NSLog("[anf] remount \(entry.remountURL) failed: \(status)")
                    }
                }
            }
        }
    }

    // MARK: - Pure parts (unit-tested)

    struct Entry: Equatable {
        let remountURL: String   // smb://nas._smb._tcp.local/share
        let mountPath: String    // /Volumes/share
    }

    /// Union of remembered + currently mounted, most-recently-seen first,
    /// capped. A share seen again moves to the front; memory of shares not
    /// currently mounted is preserved (that's the whole point — they'll be
    /// missing right after a reboot).
    nonisolated static func merge(remembered: [Entry], current: [Entry], cap: Int) -> [Entry] {
        var out = current
        for old in remembered where !out.contains(where: { $0.remountURL == old.remountURL }) {
            out.append(old)
        }
        return Array(out.prefix(cap))
    }

    nonisolated static func stored() -> [Entry] {
        let raw = UserDefaults.standard.array(forKey: defaultsKey) as? [[String]] ?? []
        return raw.compactMap { $0.count == 2 ? Entry(remountURL: $0[0], mountPath: $0[1]) : nil }
    }

    /// Currently mounted non-local browsable volumes with a remount URL.
    /// BLOCKS on volume metadata — call off the main thread.
    nonisolated private static func mountedNetworkVolumes() -> [Entry] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsBrowsableKey, .volumeURLForRemountingKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return vols.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsLocal == false, v.volumeIsBrowsable != false,
                  let remount = v.volumeURLForRemounting else { return nil }
            return Entry(remountURL: remount.absoluteString, mountPath: url.path)
        }
    }
}
