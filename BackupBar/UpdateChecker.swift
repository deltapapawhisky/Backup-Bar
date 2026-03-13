import Foundation
import AppKit

struct GitHubRelease: Codable {
    let tagName: String
    let name: String
    let htmlUrl: String
    let body: String?
    let publishedAt: String?
    let assets: [GitHubAsset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlUrl = "html_url"
        case body
        case publishedAt = "published_at"
        case assets
    }
}

struct GitHubAsset: Codable {
    let name: String
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

enum UpdateCheckResult {
    case updateAvailable(version: String, releaseUrl: String, downloadUrl: String?)
    case upToDate
    case error(String)
}

class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    private let githubOwner = "deltapapawhisky"
    private let githubRepo = "backup-bar"

    @Published var isChecking = false
    @Published var lastCheckResult: UpdateCheckResult?

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    func checkForUpdates(completion: @escaping (UpdateCheckResult) -> Void) {
        isChecking = true

        let urlString = "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                self.isChecking = false
                let result = UpdateCheckResult.error("Invalid URL")
                self.lastCheckResult = result
                completion(result)
            }
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isChecking = false

                if let error = error {
                    let result = UpdateCheckResult.error("Network error: \(error.localizedDescription)")
                    self?.lastCheckResult = result
                    completion(result)
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    let result = UpdateCheckResult.error("Invalid response")
                    self?.lastCheckResult = result
                    completion(result)
                    return
                }

                if httpResponse.statusCode == 404 {
                    // No releases yet
                    let result = UpdateCheckResult.upToDate
                    self?.lastCheckResult = result
                    completion(result)
                    return
                }

                guard httpResponse.statusCode == 200 else {
                    let result = UpdateCheckResult.error("Server error: \(httpResponse.statusCode)")
                    self?.lastCheckResult = result
                    completion(result)
                    return
                }

                guard let data = data else {
                    let result = UpdateCheckResult.error("No data received")
                    self?.lastCheckResult = result
                    completion(result)
                    return
                }

                do {
                    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                    let result = self?.compareVersions(release: release) ?? .error("Unknown error")
                    self?.lastCheckResult = result
                    completion(result)
                } catch {
                    let result = UpdateCheckResult.error("Failed to parse response")
                    self?.lastCheckResult = result
                    completion(result)
                }
            }
        }.resume()
    }

    private func compareVersions(release: GitHubRelease) -> UpdateCheckResult {
        // Remove 'v' prefix if present
        let remoteVersion = release.tagName.hasPrefix("v")
            ? String(release.tagName.dropFirst())
            : release.tagName

        // Find download URL for .app.zip or .dmg if available
        let downloadUrl = release.assets?.first { asset in
            asset.name.hasSuffix(".app.zip") || asset.name.hasSuffix(".dmg")
        }?.browserDownloadUrl

        if isNewerVersion(remoteVersion, than: currentVersion) {
            return .updateAvailable(
                version: remoteVersion,
                releaseUrl: release.htmlUrl,
                downloadUrl: downloadUrl
            )
        } else {
            return .upToDate
        }
    }

    private func isNewerVersion(_ remote: String, than local: String) -> Bool {
        let remoteComponents = remote.split(separator: ".").compactMap { Int($0) }
        let localComponents = local.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(remoteComponents.count, localComponents.count) {
            let remoteNum = i < remoteComponents.count ? remoteComponents[i] : 0
            let localNum = i < localComponents.count ? localComponents[i] : 0

            if remoteNum > localNum {
                return true
            } else if remoteNum < localNum {
                return false
            }
        }

        return false
    }

    func showUpdateAlert(version: String, releaseUrl: String, downloadUrl: String?) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Backup Bar \(version) is available. You are currently running version \(currentVersion)."
        alert.alertStyle = .informational

        if downloadUrl != nil {
            alert.addButton(withTitle: "Download")
        }
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()

        if downloadUrl != nil {
            switch response {
            case .alertFirstButtonReturn:
                // Download
                if let url = URL(string: downloadUrl!) {
                    NSWorkspace.shared.open(url)
                }
            case .alertSecondButtonReturn:
                // View Release
                if let url = URL(string: releaseUrl) {
                    NSWorkspace.shared.open(url)
                }
            default:
                break
            }
        } else {
            switch response {
            case .alertFirstButtonReturn:
                // View Release
                if let url = URL(string: releaseUrl) {
                    NSWorkspace.shared.open(url)
                }
            default:
                break
            }
        }
    }

    func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're Up to Date"
        alert.informativeText = "Backup Bar \(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func showErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
