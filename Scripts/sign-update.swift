import CryptoKit
import Foundation

enum SigningError: Error {
    case usage, invalidKey, keyMismatch, invalidSize, invalidSignature, unsafeKeyFile
}

func validatePrivateKeyFile(_ path: String, repository: String) throws {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let resolved = url.resolvingSymlinksInPath()
    let root = URL(fileURLWithPath: repository).resolvingSymlinksInPath().path
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let directory = try FileManager.default.attributesOfItem(atPath: resolved.deletingLastPathComponent().path)
    guard path.hasPrefix("/"), !resolved.path.hasPrefix(root + "/"), !url.path.hasPrefix(root + "/"),
          attributes[.type] as? FileAttributeType == .typeRegular,
          (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
          (attributes[.posixPermissions] as? NSNumber).map({ $0.intValue & 0o077 == 0 }) == true,
          (directory[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
          (directory[.posixPermissions] as? NSNumber).map({ $0.intValue & 0o077 == 0 }) == true
    else { throw SigningError.unsafeKeyFile }
    _ = try privateKey(path)
}

func publicKey(_ text: String) throws -> Curve25519.Signing.PublicKey {
    guard let data = Data(base64Encoded: text), data.count == 32 else { throw SigningError.invalidKey }
    return try Curve25519.Signing.PublicKey(rawRepresentation: data)
}

func privateKey(_ path: String) throws -> Curve25519.Signing.PrivateKey {
    let text = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: text), data.count == 32 else { throw SigningError.invalidKey }
    return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
}

func payload(_ path: String) throws -> Data {
    let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber
    guard let size, size.int64Value > 0, size.int64Value <= 256 * 1024 * 1024 else { throw SigningError.invalidSize }
    return try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args.first {
    case "check-key" where args.count == 2:
        _ = try publicKey(args[1])
    case "check-private-key" where args.count == 3:
        try validatePrivateKeyFile(args[1], repository: args[2])
    case "generate-key" where args.count == 2:
        let key = Curve25519.Signing.PrivateKey()
        // Never overwrite an existing key; the private material is never printed.
        let descriptor = open(args[1], O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data(key.rawRepresentation.base64EncodedString().utf8))
        try handle.close()
        print(key.publicKey.rawRepresentation.base64EncodedString())
    case "public-key" where args.count == 2:
        print(try privateKey(args[1]).publicKey.rawRepresentation.base64EncodedString())
    case "sign" where args.count == 5:
        let key = try privateKey(args[2])
        guard try publicKey(args[3]).rawRepresentation == key.publicKey.rawRepresentation else { throw SigningError.keyMismatch }
        let signature = try key.signature(for: payload(args[1]))
        try (signature.base64EncodedString() + "\n").write(toFile: args[4], atomically: true, encoding: .utf8)
    case "verify" where args.count == 4:
        let text = try String(contentsOfFile: args[2], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: text),
              try publicKey(args[3]).isValidSignature(signature, for: payload(args[1])) else { throw SigningError.invalidSignature }
    default: throw SigningError.usage
    }
} catch {
    // Error names contain no private key data.
    fputs("Update signing failed: \(error)\n", stderr)
    fputs("Usage: swift Scripts/sign-update.swift generate-key KEY_FILE | public-key KEY_FILE | check-key PUBLIC_KEY | check-private-key KEY_FILE REPOSITORY | sign DMG KEY_FILE PUBLIC_KEY SIG_FILE | verify DMG SIG_FILE PUBLIC_KEY\n", stderr)
    exit(1)
}
