import Foundation
import MusterCore
import Testing
@testable import Muster

@Suite struct UpdateReleaseTests {
    private func release(signature: Bool = true, host: String = "github.com", size: Int64 = 100) throws -> Data {
        let base = "https://\(host)/EthanWFL/muster/releases/download/v1.2.3/"
        var assets: [[String: Any]] = [["name": "Muster-1.2.3.dmg", "browser_download_url": base + "Muster-1.2.3.dmg", "size": size]]
        if signature { assets.append(["name": "Muster-1.2.3.dmg.sig", "browser_download_url": base + "Muster-1.2.3.dmg.sig", "size": 89]) }
        return try JSONSerialization.data(withJSONObject: ["tag_name": "v1.2.3",
            "html_url": "https://github.com/EthanWFL/muster/releases/tag/v1.2.3", "assets": assets])
    }

    @Test func requiresMatchingSignatureAndTrustedDownloadLocation() throws {
        let good = try #require(try UpdateChecker.parse(release()))
        #expect(good.asset?.signatureURL.lastPathComponent == "Muster-1.2.3.dmg.sig")
        for bytes in [try release(signature: false), try release(host: "example.com"),
                      try release(size: UpdateTrust.maximumImageBytes + 1)] {
            let manual = try #require(try UpdateChecker.parse(bytes))
            #expect(manual.asset == nil)
            #expect(manual.url == good.url)
        }
    }

    @Test func invalidSignatureNeverMountsOrReplacesTheInstalledApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("Muster.app")
        let image = root.appendingPathComponent("update.dmg")
        try Data("original app".utf8).write(to: installed)
        try Data("not a disk image".utf8).write(to: image)
        #expect(throws: UpdateTrustError.missingKey) {
            try UpdateInstaller.install(dmgURL: image, signature: Data(), publicKey: nil,
                version: "1.2.3", currentVersion: "1.2.2", replacing: installed)
        }
        #expect(try String(contentsOf: installed, encoding: .utf8) == "original app")
    }
}

private final class DownloadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.path == "/wait" { return }
        let bytes = Data(repeating: 65, count: url.path == "/large" ? 8192 : 128)
        let status = url.path == "/missing" ? 404 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(bytes.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.timeLimit(.minutes(1))) struct UpdateDownloaderTests {
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DownloadProtocol.self]
        return config
    }

    @Test func downloadWritesCompletedFileAndRejectsSizeAndHTTPFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download")
        try await UpdateDownloader.download(URL(string: "https://test.invalid/good")!, to: destination,
                                            limit: 1024, configuration: configuration())
        #expect(try Data(contentsOf: destination) == Data(repeating: 65, count: 128))
        try FileManager.default.removeItem(at: destination)
        for path in ["large", "missing"] {
            do {
                try await UpdateDownloader.download(URL(string: "https://test.invalid/" + path)!, to: destination,
                                                    limit: 1024, configuration: configuration())
                Issue.record("Unexpected successful download: \(path)")
            } catch {
                if path == "large" { #expect(error as? UpdateTrustError == .invalidSize) }
                else if case UpdateCheckError.download(let code) = error { #expect(code == 404) }
                else { Issue.record("Unexpected download error: \(error)") }
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test func cancellationCompletesAndLeavesNoFile() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let config = configuration()
        let task = Task {
            try await UpdateDownloader.download(URL(string: "https://test.invalid/wait")!,
                                                to: destination, limit: 1024, configuration: config)
        }
        task.cancel()
        do { try await task.value; Issue.record("Cancelled download succeeded") }
        catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
