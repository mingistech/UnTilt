import AppKit
import Combine
import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var isChecking = false
    private let defaults = UserDefaults.standard
    private let lastCheckKey = "updates.lastSuccessfulCheck"
    private var lastAttempt: Date?
    private let week: TimeInterval = 7 * 24 * 60 * 60

    func checkIfDue() async {
        guard NSApp.isActive else { return }
        let lastCheck = defaults.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastCheck) >= week,
              Date().timeIntervalSince(lastAttempt ?? .distantPast) >= 6 * 60 * 60 else { return }
        await check(manually: false)
    }

    func check(manually: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        lastAttempt = Date()
        defer { isChecking = false }

        do {
            let endpoint = URL(string: "https://api.github.com/repos/mingistech/UnTilt/releases/latest")!
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("UnTilt", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw UpdateError.unavailable
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            guard !release.draft, !release.prerelease,
                  let latest = ReleaseVersion(release.tag_name),
                  let current = ReleaseVersion(installed),
                  let url = URL(string: release.html_url),
                  url.scheme == "https", url.host == "github.com",
                  url.path.hasPrefix("/mingistech/UnTilt/releases/tag/") else {
                throw UpdateError.invalidRelease
            }
            defaults.set(Date(), forKey: lastCheckKey)
            if latest.isNewer(than: current) {
                let alert = NSAlert()
                alert.messageText = "UnTilt \(release.tag_name) is available"
                alert.informativeText = "You’re using version \(installed). Download the new version from GitHub."
                alert.addButton(withTitle: "View Release")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(url)
                }
            } else if manually {
                showMessage("You’re up to date", "UnTilt \(installed) is the latest release.")
            }
        } catch {
            if manually {
                showMessage("Couldn’t check for updates", "Check your internet connection and try again later. GitHub may also be temporarily unavailable.")
            }
        }
    }

    private func showMessage(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool
        let prerelease: Bool
    }

    private enum UpdateError: Error {
        case unavailable, invalidRelease
    }
}

// Compare numeric release tags, including v1.0, 1.0.0, and 1.10.
struct ReleaseVersion {
    let components: [Int]

    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        components = numbers
    }

    func isNewer(than other: ReleaseVersion) -> Bool {
        for index in 0..<max(components.count, other.components.count) {
            let left = index < components.count ? components[index] : 0
            let right = index < other.components.count ? other.components[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
