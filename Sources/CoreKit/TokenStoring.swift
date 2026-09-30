import Foundation

// REQ-2026-001 T-2（lab swift 同款缝）：密态存储缝。token/refreshToken 属会话密钥，
// 不落 UserDefaults；具体实现由绑定层给——App target 绑 Keychain（KeychainTokenStore），
// swift test 注入内存 fake（InMemoryTokenStore），单测不碰 Keychain。

/// 会话密钥存储缝：按 key 存取删，语义与 Keychain 单值条目一致。
public protocol TokenStoring {
    func read(_ key: String) -> String?
    func save(_ key: String, _ value: String)
    func delete(_ key: String)
}

/// 测试缝 fake：进程内字典。生产代码禁用（密态必须进 Keychain）。
public final class InMemoryTokenStore: TokenStoring {
    private var storage: [String: String] = [:]

    public init() {}

    public func read(_ key: String) -> String? {
        storage[key]
    }

    public func save(_ key: String, _ value: String) {
        storage[key] = value
    }

    public func delete(_ key: String) {
        storage.removeValue(forKey: key)
    }
}
