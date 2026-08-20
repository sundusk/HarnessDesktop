import Foundation

protocol HarnessReleaseVersionProviding: Sendable {
    func fetchLatestReleaseVersion() async throws -> HarnessVersion
}

private struct GitHubHarnessRelease: Decodable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
    }
}

/// Queries all recent Harness releases because GitHub's `/releases/latest`
/// excludes prereleases, while DeepSeek Harness currently ships RC versions.
struct GitHubHarnessReleaseVersionProvider: HarnessReleaseVersionProviding {
    var fetcher: any HTTPDataFetching
    var repository = "deepseek-ai/deepseek-harness"
    var apiBaseURL = URL(string: "https://api.github.com")!

    init(fetcher: any HTTPDataFetching = URLSession.shared) {
        self.fetcher = fetcher
    }

    func fetchLatestReleaseVersion() async throws -> HarnessVersion {
        guard let url = URL(string: "\(apiBaseURL.absoluteString)/repos/\(repository)/releases?per_page=20") else {
            throw HarnessVersionError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await fetcher.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HarnessVersionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HarnessVersionError.unexpectedStatus(http.statusCode)
        }

        let releases: [GitHubHarnessRelease]
        do {
            releases = try JSONDecoder().decode([GitHubHarnessRelease].self, from: data)
        } catch {
            throw HarnessVersionError.malformedReleaseData
        }

        let versions = releases.compactMap { release -> HarnessVersion? in
            guard !release.draft else { return nil }
            let normalized: String
            if release.tagName.hasPrefix("dsh-v") {
                normalized = String(release.tagName.dropFirst("dsh-v".count))
            } else if release.tagName.hasPrefix("v") {
                normalized = String(release.tagName.dropFirst())
            } else {
                return nil
            }
            return HarnessVersion(normalized)
        }
        guard let latest = versions.max() else {
            throw HarnessVersionError.noValidReleaseVersions
        }
        return latest
    }
}
