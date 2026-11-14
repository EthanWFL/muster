import CryptoKit
import Foundation
import MusterCore
@testable import Muster

// Linked by test-update-installation.py against the actual app's updater. No Agent models run.
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "updates.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MUSTER_UPDATE_FIXTURE"]!)
            let data = try Data(contentsOf: root.appendingPathComponent(request.url!.lastPathComponent))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Length": String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct UpdateInstallationTest {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let destination = root.appendingPathComponent("installed/Muster.app")
        let publicKey = try String(contentsOf: root.appendingPathComponent("public.key"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let image = root.appendingPathComponent("downloaded.dmg")
        let signatureFile = root.appendingPathComponent("downloaded.sig")
        let config = URLSessionConfiguration.ephemeral
        let published = CommandLine.arguments.contains("--published")
        var imageURL = URL(string: "https://updates.example.test/update.dmg")!
        var signatureURL = URL(string: "https://updates.example.test/update.sig")!
        if published {
            guard let release = try await UpdateChecker.latest(), release.version == "1.1.1",
                  release.installationAvailability(publicKey: publicKey) == .ready, let asset = release.asset else {
                fatalError("Published release is not eligible for trusted in-app installation")
            }
            imageURL = asset.url; signatureURL = asset.signatureURL
        } else { config.protocolClasses = [FixtureProtocol.self] }
        try await UpdateDownloader.download(signatureURL, to: signatureFile, limit: 512, configuration: config)
        try await UpdateDownloader.download(imageURL, to: image, limit: UpdateTrust.maximumImageBytes, configuration: config)
        let signature = try Data(contentsOf: signatureFile)
        if CommandLine.arguments.contains("--install-only") || published {
            try UpdateInstaller.install(dmgURL: image, signature: signature, publicKey: publicKey,
                version: "1.1.1", currentVersion: "1.1.0", replacing: destination)
            let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: destination.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
            precondition(info["CFBundleShortVersionString"] as? String == "1.1.1" && info["MusterUpdatePublicKey"] as? String == publicKey)
            print("PASS: actual release downloaded, verified and installed into an isolated app copy; actual Muster was not launched.")
            return
        }
        let original = try Data(contentsOf: destination.appendingPathComponent("Contents/Info.plist"))
        func reject(_ image: URL, signature: Data, key: String?, destination: URL, expected: UpdateTrustError) throws {
            do {
                try UpdateInstaller.install(dmgURL: image, signature: signature, publicKey: key,
                    version: "1.1.1", currentVersion: "1.1.0", replacing: destination)
                fatalError("An invalid update was accepted")
            } catch let error as UpdateTrustError { precondition(error == expected, "Unexpected rejection: \(error)") }
        }
        try reject(image, signature: signature, key: nil, destination: destination, expected: .missingKey)
        var tampered = try Data(contentsOf: image)
        tampered[tampered.startIndex] ^= 1
        let badImage = root.appendingPathComponent("tampered.dmg")
        try tampered.write(to: badImage)
        try reject(badImage, signature: signature, key: publicKey, destination: destination, expected: .invalidSignature)
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        try reject(image, signature: signature, key: otherKey, destination: destination, expected: .invalidSignature)
        try reject(root.appendingPathComponent("changed-key.dmg"), signature: Data(contentsOf: root.appendingPathComponent("changed-key.sig")), key: publicKey,
            destination: destination, expected: .changedKey)
        let link = root.appendingPathComponent("linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        try reject(image, signature: signature, key: publicKey, destination: link, expected: .invalidDestination)
        let afterRejections = try Data(contentsOf: destination.appendingPathComponent("Contents/Info.plist"))
        precondition(afterRejections == original)
        try UpdateInstaller.install(dmgURL: image, signature: signature, publicKey: publicKey,
            version: "1.1.1", currentVersion: "1.1.0", replacing: destination)
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: destination.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
        precondition(info["CFBundleShortVersionString"] as? String == "1.1.1")
        precondition(info["MusterUpdatePublicKey"] as? String == publicKey)
        try UpdateInstaller.relaunch(destination)
        print("PASS: HTTPS downloader, signature/tamper/key/path rejection, replacement and relaunch dispatch; waiting for old process exit.")
        // The parent verifies that relaunch wrote the marker after this process exits.
    }
}
