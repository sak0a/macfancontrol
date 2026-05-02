import AppKit
import Foundation

enum UpdateChecker {
    private static let repo = "laurinfrank/macfancontrol"
    private static let releasesURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

    private static let lastCheckKey = "UpdateChecker.lastCheck"
    private static let lastNotifiedKey = "UpdateChecker.lastNotifiedVersion"
    private static let cooldown: TimeInterval = 6 * 60 * 60

    // MARK: - Public

    static func checkForUpdates(manual: Bool = false) {
        Task {
            await performCheck(manual: manual)
        }
    }

    // MARK: - Network

    private static func performCheck(manual: Bool) async {
        if !manual {
            let lastCheck = UserDefaults.standard.double(forKey: lastCheckKey)
            if Date().timeIntervalSince1970 - lastCheck < cooldown { return }
        }

        var req = URLRequest(url: releasesURL)
        req.timeoutInterval = 15

        let data: Data
        do {
            let (d, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                if manual { await showAlert(title: "Check Failed", message: "Server returned an error.") }
                return
            }
            data = d
        } catch {
            if manual { await showAlert(title: "Check Failed", message: error.localizedDescription) }
            return
        }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        let release: Release
        do {
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            if manual { await showAlert(title: "Check Failed", message: "Could not parse response.") }
            return
        }

        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name

        guard isNewer(version) else {
            if manual { await showUpToDate() }
            return
        }

        let lastNotified = UserDefaults.standard.string(forKey: lastNotifiedKey)
        if version == lastNotified {
            if manual { await showUpToDate() }
            return
        }

        UserDefaults.standard.set(version, forKey: lastNotifiedKey)
        await showUpdateAlert(release: release, version: version)
    }

    // MARK: - Version comparison

    private static func isNewer(_ version: String) -> Bool {
        guard let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return false
        }
        return compare(version, current) > 0
    }

    private static func compare(_ a: String, _ b: String) -> Int {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(aParts.count, bParts.count)
        for i in 0 ..< maxLen {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av != bv { return av - bv }
        }
        return 0
    }

    // MARK: - Alerts

    @MainActor
    private static func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = "Up to Date"
        alert.informativeText = "MacFanControl \(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor
    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor
    private static func showUpdateAlert(release: Release, version: String) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        var info = "MacFanControl \(version) is available."
        if let body = release.body, !body.isEmpty {
            info += "\n\n" + body
        }
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: release.html_url) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    // MARK: - Types

    private struct Release: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
    }
}
