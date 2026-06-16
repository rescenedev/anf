import AppKit
import Observation

/// Once-a-day check against the latest GitHub release. Fail-silent (offline is
/// fine); when a newer version exists a small dismissible banner appears, and a
/// dismissed version is never offered again. A manual "Check for Updates…" menu
/// item (issue #38) bypasses the daily throttle and the dismissed-version filter
/// and always reports a result — including "you're up to date".
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// Newer version tag (e.g. "1.2.0") when an update is available.
    private(set) var availableVersion: String?

    private static let lastCheckKey = "anf.update.lastCheck"
    private static let dismissedKey = "anf.update.dismissed"
    private static let releaseAPI = "https://api.github.com/repos/rescenedev/anf/releases/latest"

    /// The app's own version, e.g. "1.5.17". Overridable for tests.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Background check on launch: at most once per 24h, silent on every outcome
    /// (offline, up-to-date, or a version the user already dismissed).
    func checkIfDue() {
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard now - last > 24 * 3600 else { return }
        UserDefaults.standard.set(now, forKey: Self.lastCheckKey)

        Task { [weak self] in
            guard let latest = await Self.fetchLatest() else { return }
            await self?.applyAuto(latest)
        }
    }

    /// Manual check (⌘-less menu item, issue #38): ignores the 24h throttle and
    /// the dismissed-version filter, and always tells the user the outcome.
    func checkNow() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        Task { [weak self] in
            guard let latest = await Self.fetchLatest() else {
                Self.alert(L("Couldn’t check for updates", "업데이트를 확인하지 못했습니다"),
                           L("Check your connection and try again.", "연결을 확인하고 다시 시도해 주세요."))
                return
            }
            if Self.isNewer(latest, than: Self.currentVersion) {
                self?.availableVersion = latest   // surface the banner even if previously dismissed
            } else {
                Self.alert(L("You’re up to date", "최신 버전입니다"),
                           L("anf \(Self.currentVersion) is the latest version.",
                             "anf \(Self.currentVersion) 이(가) 최신 버전입니다."))
            }
        }
    }

    /// Apply an auto-check result: show the banner only for a newer, not-yet-dismissed version.
    private func applyAuto(_ latest: String) {
        guard Self.isNewer(latest, than: Self.currentVersion),
              UserDefaults.standard.string(forKey: Self.dismissedKey) != latest else { return }
        availableVersion = latest
    }

    func dismiss() {
        if let v = availableVersion {
            UserDefaults.standard.set(v, forKey: Self.dismissedKey)
        }
        availableVersion = nil
    }

    /// Fetch the latest release tag (without a leading "v"), or nil on any failure.
    private static func fetchLatest() async -> String? {
        guard let url = URL(string: releaseAPI) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    private static func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: L("OK", "확인"))
        a.runModal()
    }

    /// Numeric dotted-version comparison ("1.10.0" > "1.9").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
