import CoreKit
import Foundation
import Security

// REQ-2026-001 T-3（lab swift 同款）：TokenStoring 的 Keychain 实现，只活在
// App 绑定层；单测走 CoreKit 的 InMemoryTokenStore fake，不碰 Keychain。

struct KeychainTokenStore: TokenStoring {

    private let service: String

    init(service: String = "saas-identity-platform") {
        self.service = service
    }

    func read(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ key: String, _ value: String) {
        delete(key)
        var query = baseQuery(key)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    func delete(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
