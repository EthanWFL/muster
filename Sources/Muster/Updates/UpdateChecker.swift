import Foundation
import MusterCore

struct UpdateAsset: Equatable, Sendable {
    let url: URL
    let signatureURL: URL
}

struct UpdateRelease: Equatable, Sendable {
    let version: String
    let url: URL
    let asset: UpdateAsset?
}

enum UpdateCheckError: LocalizedError {
    case http(Int)
    case download(Int)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "GitHub returned HTTP \(code)"
        case .download(let code): return "Download returned HTTP \(code)"
        }
    }
}

enum UpdateChecker {
    static func latest(owner: String = "EthanWFL", repo: String = "muster") async throws -> UpdateRelease? {
        guard let endpoint = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            return nil
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MusterRelease-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("release.json")
        do { try await UpdateDownloader.download(endpoint, to: file, limit: 1_024 * 1_024) }
        catch UpdateCheckError.download(404) { return nil }
        catch UpdateCheckError.download(let code) { throw UpdateCheckError.http(code) }
        return try parse(Data(contentsOf: file), owner: owner, repo: repo)
    }

    static func parse(_ data: Data, owner: String = "EthanWFL", repo: String = "muster") throws -> UpdateRelease? {
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
                let size: Int64
            }
            let tag_name: String
            let html_url: String
            let assets: [Asset]?
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        func githubURL(_ raw: String, path: String) -> URL? {
            guard let url = URL(string: raw), url.scheme == "https", url.host?.lowercased() == "github.com",
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
                  url.path == path else { return nil }
            return url
        }
        let tag = release.tag_name
        guard AppVersion(tag) != nil, !tag.contains("/"),
              let page = githubURL(release.html_url, path: "/\(owner)/\(repo)/releases/tag/\(tag)") else { return nil }
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        let name = "Muster-\(version).dmg"
        let prefix = "/\(owner)/\(repo)/releases/download/\(tag)/"
        var asset: UpdateAsset?
        if let image = release.assets?.first(where: { $0.name == name }),
           let signature = release.assets?.first(where: { $0.name == name + ".sig" }),
           image.size > 0, image.size <= UpdateTrust.maximumImageBytes, signature.size > 0, signature.size <= 512,
           let imageURL = githubURL(image.browser_download_url, path: prefix + name),
           let signatureURL = githubURL(signature.browser_download_url, path: prefix + name + ".sig") {
            asset = UpdateAsset(url: imageURL, signatureURL: signatureURL)
        }
        return UpdateRelease(version: tag, url: page, asset: asset)
    }
}
