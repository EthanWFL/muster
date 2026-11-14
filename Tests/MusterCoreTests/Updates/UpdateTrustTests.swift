import CryptoKit
import Foundation
import Testing
@testable import MusterCore

@Suite struct UpdateTrustTests {
    @Test func verifiesPinnedKeyAndRejectsTamperingAndDifferentPublisher() throws {
        let tree = try TempTree()
        let key = Curve25519.Signing.PrivateKey()
        let bytes = Data("test update payload".utf8)
        let image = URL(fileURLWithPath: tree.path("update.dmg"))
        try bytes.write(to: image)
        let signature = Data(try key.signature(for: bytes).base64EncodedString().utf8)
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        try UpdateTrust.verify(image: image, signature: signature, publicKey: publicKey)
        #expect(throws: UpdateTrustError.invalidSignature) {
            try UpdateTrust.verify(image: image, signature: signature,
                publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())
        }
        try Data("tampered".utf8).write(to: image)
        #expect(throws: UpdateTrustError.invalidSignature) {
            try UpdateTrust.verify(image: image, signature: signature, publicKey: publicKey)
        }
    }

    @Test func missingKeyAndMalformedSignatureFailClosed() throws {
        let tree = try TempTree()
        let image = URL(fileURLWithPath: try tree.write("update.dmg", "payload"))
        #expect(!UpdateTrust.hasValidKey(nil))
        #expect(!UpdateTrust.hasValidKey(Data(repeating: 0, count: 31).base64EncodedString()))
        #expect(throws: UpdateTrustError.missingKey) {
            try UpdateTrust.verify(image: image, signature: Data(), publicKey: nil)
        }
        let publicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        for signature in [Data("invalid".utf8), Data(repeating: 65, count: 513)] {
            #expect(throws: UpdateTrustError.invalidSignature) {
                try UpdateTrust.verify(image: image, signature: signature, publicKey: publicKey)
            }
        }
    }

    @Test func refusesOversizedImagesBeforeLoadingThem() throws {
        let tree = try TempTree()
        let image = URL(fileURLWithPath: try tree.write("large.dmg", ""))
        let handle = try FileHandle(forWritingTo: image)
        try handle.truncate(atOffset: UInt64(UpdateTrust.maximumImageBytes + 1))
        try handle.close()
        let key = Curve25519.Signing.PrivateKey()
        let signature = Data(try key.signature(for: Data()).base64EncodedString().utf8)
        #expect(throws: UpdateTrustError.invalidSize) {
            try UpdateTrust.verify(image: image, signature: signature, publicKey: key.publicKey.rawRepresentation.base64EncodedString())
        }
    }

    @Test func bundleMustMatchIdentityVersionAndBeNewer() throws {
        var info = ["CFBundleIdentifier": "com.muster.app", "CFBundleExecutable": "Muster", "CFBundleShortVersionString": "1.2.3"]
        try UpdateTrust.validateBundle(info: info, expectedVersion: "v1.2.3", currentVersion: "1.2.2")
        #expect(throws: UpdateTrustError.wrongVersion) {
            try UpdateTrust.validateBundle(info: info, expectedVersion: "v1.2.4", currentVersion: "1.2.2")
        }
        #expect(throws: UpdateTrustError.wrongVersion) {
            try UpdateTrust.validateBundle(info: info, expectedVersion: "v1.2.3", currentVersion: "1.2.3")
        }
        info["CFBundleIdentifier"] = "someone.else"
        #expect(throws: UpdateTrustError.wrongApplication) {
            try UpdateTrust.validateBundle(info: info, expectedVersion: "v1.2.3", currentVersion: "1.2.2")
        }
    }

    @Test func updatesCannotDropOrReplaceTheInstalledTrustAnchor() throws {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        var info = ["CFBundleIdentifier": "com.muster.app", "CFBundleExecutable": "Muster", "CFBundleShortVersionString": "1.1.1"]
        #expect(throws: UpdateTrustError.changedKey) {
            try UpdateTrust.validateBundle(info: info, expectedVersion: "1.1.1", currentVersion: "1.1.0", expectedPublicKey: key)
        }
        info["MusterUpdatePublicKey"] = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(throws: UpdateTrustError.changedKey) {
            try UpdateTrust.validateBundle(info: info, expectedVersion: "1.1.1", currentVersion: "1.1.0", expectedPublicKey: key)
        }
        info["MusterUpdatePublicKey"] = key
        try UpdateTrust.validateBundle(info: info, expectedVersion: "1.1.1", currentVersion: "1.1.0", expectedPublicKey: key)
    }
}
