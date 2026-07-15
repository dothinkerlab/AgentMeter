import Foundation
import Testing
import Security
@testable import AgentMeterCore

/// DeepSeekKeyStore 单测:save/read/delete + `synchronizable=false` + `ThisDeviceOnly`,
/// 保证 DeepSeek API key 不经 iCloud Keychain 或加密备份迁移出去(架构铁律 1 的 DeepSeek 例外要点)。
struct DeepSeekKeyStoreTests {

    /// 每个测试用独立 service,避免污染用户真实 keychain 条目 + 并行测试互相干扰。
    private func scopedService() -> String {
        let suffix = UUID().uuidString.prefix(8)
        return "DeepSeek-credentials-test-\(suffix)"
    }

    @Test func saveThenReadReturnsKey() throws {
        let service = scopedService()
        defer { wipe(service: service) }

        try DeepSeekKeyStore.save(apiKey: "sk-deepseek-abc", service: service)
        let read = try DeepSeekKeyStore.read(service: service)
        #expect(read == "sk-deepseek-abc")
    }

    @Test func readReturnsNilWhenAbsent() throws {
        let service = scopedService()
        defer { wipe(service: service) }
        let read = try DeepSeekKeyStore.read(service: service)
        #expect(read == nil)
    }

    @Test func saveOverwritesExistingKey() throws {
        let service = scopedService()
        defer { wipe(service: service) }

        try DeepSeekKeyStore.save(apiKey: "sk-old", service: service)
        try DeepSeekKeyStore.save(apiKey: "sk-new-flushed", service: service)

        let read = try DeepSeekKeyStore.read(service: service)
        #expect(read == "sk-new-flushed")
    }

    @Test func deleteRemovesKeyAndIsIdempotent() throws {
        let service = scopedService()
        defer { wipe(service: service) }

        try DeepSeekKeyStore.save(apiKey: "sk-will-delete", service: service)
        try DeepSeekKeyStore.delete(service: service)

        let after = try DeepSeekKeyStore.read(service: service)
        #expect(after == nil)

        // 重复删不抛错(幂等)。
        try DeepSeekKeyStore.delete(service: service)
        try DeepSeekKeyStore.delete(service: service)
    }

    @Test func savedItemIsNotSynchronizableAndDoesNotMigrate() throws {
        let service = scopedService()
        defer { wipe(service: service) }

        try DeepSeekKeyStore.save(apiKey: "sk-sync-check", service: service)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: DeepSeekKeyStore.account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        #expect(status == errSecSuccess)

        // kSecAttrSynchronizable 在部分平台不会回读出来 —— 只要它不显式为 true 就算通过
        // (save 实现里把 kSecAttrSynchronizable 硬编码为 kCFBooleanFalse)。
        if let attrs = item as? [String: Any],
           let sync = attrs[kSecAttrSynchronizable as String] {
            if let bool = sync as? Bool {
                #expect(bool == false)
            } else {
                Issue.record("synchronizable 属性不是 Bool: \(sync)")
            }
        }

        let localOnlyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: DeepSeekKeyStore.account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        #expect(SecItemCopyMatching(localOnlyQuery as CFDictionary, nil) == errSecSuccess)
    }

    @Test func saveUpgradesMigratableItemToThisDeviceOnly() throws {
        let service = scopedService()
        defer { wipe(service: service) }
        let legacyItem: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: DeepSeekKeyStore.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data("sk-legacy".utf8),
        ]
        #expect(SecItemAdd(legacyItem as CFDictionary, nil) == errSecSuccess)

        try DeepSeekKeyStore.save(apiKey: "sk-upgraded", service: service)

        let localOnlyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: DeepSeekKeyStore.account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        #expect(SecItemCopyMatching(localOnlyQuery as CFDictionary, nil) == errSecSuccess)
    }
}

/// 测试结束清理对应 service 下的条目,防止 leftover key 留在用户机器 Keychain。
private func wipe(service: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
    ]
    SecItemDelete(query as CFDictionary)
}
