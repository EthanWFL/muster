import Foundation
import Security

struct ChatKeychain {
    private let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.muster.app.openai",
        kSecAttrAccount as String: "responses-api-key"
    ]

    enum Failure: LocalizedError {
        case inaccessible
        var errorDescription: String? { "Could not access the OpenAI API key in Keychain." }
    }

    func exists() throws -> Bool {
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw Failure.inaccessible }
        return true
    }

    func read() throws -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { _, new in new } as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { throw Failure.inaccessible }
        return key
    }

    func save(_ key: String) throws {
        let data = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, data as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging(data) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.inaccessible }
        } else if status != errSecSuccess {
            throw Failure.inaccessible
        }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.inaccessible }
    }
}
