import Foundation
import Observation

/// Asks GitHub once a day for the latest release. Nothing about the Mac is sent; it's one
/// plain request for a public page. Turn it off in Settings > General.
@MainActor
@Observable
final class UpdateChecker {
    private(set) var newVersion: String?
    private(set) var releasePage = URL(string: "https://github.com/noahelhadedy/double-shot/releases/latest")!

    @ObservationIgnored private var timer: Timer?
    private static let api = URL(string: "https://api.github.com/repos/noahelhadedy/double-shot/releases/latest")!

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        guard timer == nil else { return }
        check()
        let timer = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 60 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        newVersion = nil
    }

    private func check() {
        guard Preferences.shared.checkForUpdates else { return }
        var request = URLRequest(url: Self.api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        Task {
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let release = try? JSONDecoder().decode(Release.self, from: data) else { return }
            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            newVersion = Self.isNewer(latest, than: currentVersion) ? latest : nil
            if let page = URL(string: release.htmlURL) { releasePage = page }
        }
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    /// "1.0.10" is newer than "1.0.9".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
