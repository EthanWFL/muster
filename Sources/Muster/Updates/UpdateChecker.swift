import Foundation

struct UpdateRelease {
    let version: String
    let url: URL
}

enum UpdateCheckError: LocalizedError {
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "GitHub returned HTTP \(code)"
        }
    }
}

enum UpdateChecker {
    static func latest(owner: String = "EthanWFL", repo: String = "muster") async throws -> UpdateRelease? {
        guard let endpoint = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Muster", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateCheckError.http(-1) }
        // A private repo or a repo without releases looks like 404 to an unauthenticated client.
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw UpdateCheckError.http(http.statusCode) }
        struct Release: Decodable {
            let tag_name: String
            let html_url: String
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let url = URL(string: release.html_url) else { return nil }
        return UpdateRelease(version: release.tag_name, url: url)
    }
}
