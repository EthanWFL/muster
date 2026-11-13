import CryptoKit
import Foundation

public enum UpdateTrustError: String, LocalizedError {
    case missingKey = "This build has no trusted update key. Download updates from Releases."
    case invalidSignature = "The update signature is missing or invalid."
    case invalidSize = "The update download is empty or exceeds the size limit."
    case wrongApplication = "The update contains a different application."
    case wrongVersion = "The update version does not match the selected release."
    public var errorDescription: String? { rawValue }
}

/// The trust anchor comes from the installed app, never from the downloaded release.
public enum UpdateTrust {
    public static let maximumImageBytes: Int64 = 256 * 1_024 * 1_024

    public static func hasValidKey(_ encoded: String?) -> Bool {
        guard let encoded, let raw = Data(base64Encoded: encoded), raw.count == 32 else { return false }
        return (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil
    }

    public static func verify(image: URL, signature: Data, publicKey: String?) throws {
        guard let publicKey, hasValidKey(publicKey), let raw = Data(base64Encoded: publicKey) else {
            throw UpdateTrustError.missingKey
        }
        guard signature.count <= 512,
              let text = String(data: signature, encoding: .utf8),
              let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              signature.count == 64 else { throw UpdateTrustError.invalidSignature }
        let attributes = try FileManager.default.attributesOfItem(atPath: image.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value > 0,
              size.int64Value <= maximumImageBytes else { throw UpdateTrustError.invalidSize }
        let data = try Data(contentsOf: image, options: .mappedIfSafe)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
        guard key.isValidSignature(signature, for: data) else { throw UpdateTrustError.invalidSignature }
    }

    public static func validateBundle(info: [String: Any], expectedVersion: String, currentVersion: String) throws {
        guard info["CFBundleIdentifier"] as? String == "com.muster.app",
              info["CFBundleExecutable"] as? String == "Muster" else { throw UpdateTrustError.wrongApplication }
        let version = expectedVersion.hasPrefix("v") || expectedVersion.hasPrefix("V")
            ? String(expectedVersion.dropFirst()) : expectedVersion
        guard info["CFBundleShortVersionString"] as? String == version,
              AppVersion.isNewer(version, than: currentVersion) else { throw UpdateTrustError.wrongVersion }
    }
}
