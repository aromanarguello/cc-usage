import Foundation

actor UpdateChecker {
    private let currentVersion: String
    private let githubRepo = "aromanarguello/cc-usage"

    init() {
        self.currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    struct UpdateResult {
        let updateAvailable: Bool
        let latestVersion: String
        let downloadURL: String?
    }

    func checkForUpdates() async throws -> UpdateResult {
        let url = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest")!

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw UpdateError.networkError
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else {
            throw UpdateError.parseError
        }

        // Remove 'v' prefix if present (v1.0.0 -> 1.0.0)
        let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

        // Find DMG download URL
        var downloadURL: String? = nil
        if let assets = json["assets"] as? [[String: Any]] {
            for asset in assets {
                if let name = asset["name"] as? String,
                   name.hasSuffix(".dmg"),
                   let url = asset["browser_download_url"] as? String {
                    downloadURL = url
                    break
                }
            }
        }

        let updateAvailable = isNewerVersion(latestVersion, than: currentVersion)

        return UpdateResult(
            updateAvailable: updateAvailable,
            latestVersion: latestVersion,
            downloadURL: downloadURL
        )
    }

    private func isNewerVersion(_ latest: String, than current: String) -> Bool {
        let latestParts = latest.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(latestParts.count, currentParts.count) {
            let latestPart = i < latestParts.count ? latestParts[i] : 0
            let currentPart = i < currentParts.count ? currentParts[i] : 0

            if latestPart > currentPart { return true }
            if latestPart < currentPart { return false }
        }
        return false
    }
}

enum UpdateError: Error, LocalizedError {
    case networkError
    case parseError

    var errorDescription: String? {
        switch self {
        case .networkError:
            return "Could not connect to GitHub"
        case .parseError:
            return "Could not parse release info"
        }
    }
}
