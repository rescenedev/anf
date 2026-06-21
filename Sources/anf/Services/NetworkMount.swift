import AppKit
import NetFS

/// Mounts a network server URL (smb://, afp://, nfs://, ftp://, http(s) WebDAV …)
/// so a disconnected share can be (re)connected from inside anf instead of falling
/// back to Finder (#76). macOS presents its own authentication UI; on success we
/// return the local mount point so the caller can browse it in-app.
enum NetworkMount {
    /// URL schemes macOS can mount as a volume.
    static let mountableSchemes: Set<String> =
        ["smb", "cifs", "afp", "nfs", "ftp", "ftps", "http", "https", "webdav"]

    static func isMountable(_ raw: String) -> Bool {
        guard let scheme = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))?
                .scheme?.lowercased() else { return false }
        return mountableSchemes.contains(scheme)
    }

    /// `NetFSMountURLSync` blocks (and may show an auth sheet), so run it off-main;
    /// the completion is delivered back on the main actor as `(mountPoint, error)` —
    /// both nil means the user dismissed the auth sheet. `kNAUIOptionAllowUI` lets the
    /// OS prompt for credentials when they aren't already in the Keychain.
    static func mount(_ url: URL,
                      completion: @escaping @MainActor (_ mountPoint: URL?, _ error: String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var mountpoints: Unmanaged<CFArray>?
            let openOptions: NSMutableDictionary = [kNAUIOptionKey: kNAUIOptionAllowUI]
            let status = NetFSMountURLSync(url as CFURL, nil, nil, nil, openOptions, nil, &mountpoints)
            let paths = (mountpoints?.takeRetainedValue()) as? [String]
            let mountPoint: URL?
            let error: String?
            if status == 0, let first = paths?.first {
                mountPoint = URL(fileURLWithPath: first); error = nil
            } else if status == ECANCELED {
                mountPoint = nil; error = nil   // user dismissed the auth sheet — stay silent
            } else {
                mountPoint = nil; error = message(for: status)
            }
            Task { @MainActor in completion(mountPoint, error) }
        }
    }

    private static func message(for status: Int32) -> String {
        let detail = String(cString: strerror(status))
        return L("Could not connect: \(detail)", "연결할 수 없습니다: \(detail)")
    }
}
