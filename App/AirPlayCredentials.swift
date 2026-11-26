import Foundation
import CryptoKit
import Security

/// Persists Wi-Fi passwords in three layers, because sideloading signatures differ:
/// memory for the current process, Keychain when the signature grants
/// `keychain-access-groups` (企业证书/全能签), and an app-sandbox file when it does not
/// (TrollStore's ldid signature has no Keychain entitlement and returns -34018).
enum WiFiCredentials {
    private static let temporaryLock = NSLock()
    private static var temporaryPasswords: [String: String] = [:]

    static func isTemporary(for ssid: String) -> Bool {
        temporaryLock.lock(); defer { temporaryLock.unlock() }
        return temporaryPasswords[ssid] != nil
    }

    static let temporaryNotice = CWL("当前签名无法访问钥匙串（-34018）。密码已保存到 App 数据目录，App 重启后仍可使用；重装 App 后需要重新输入。如果要存进钥匙串，请用带钥匙串权限的有效签名重新安装。")

    /// Sandbox file used when Keychain is unavailable. File protection matches the
    /// Keychain accessibility used above (readable after first unlock, device only).
    private static var storeURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("wifi-credentials.json")
    }
    private static func loadStore() -> [String: String] {
        guard let url = storeURL, let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }
    private static func writeStore(_ dict: [String: String]) throws {
        guard let url = storeURL else { return }
        let data = try JSONEncoder().encode(dict)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private static func storedPassword(for ssid: String) -> String? { loadStore()[ssid] }

    /// State of every storage layer, for diagnostics. Never includes the secret itself.
    static func diagnostic(for ssid: String) -> String {
        temporaryLock.lock()
        let memoryHit = temporaryPasswords[ssid] != nil
        temporaryLock.unlock()
        var lookup = query(ssid)
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        let file = loadStore()
        let fileExists = storeURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        // Assembled step by step: a single interpolated expression with nested ternaries
        // exceeds the type checker's budget on some Xcode versions.
        let memoryText: String = memoryHit ? "有" : "无"
        let existsText: String = fileExists ? "是" : "否"
        let hitText: String = file[ssid] != nil ? "是" : "否"
        let entryCount = file.keys.count
        let keychainText = String(status)
        return "内存=" + memoryText + "｜Keychain=" + keychainText
            + "｜文件存在=" + existsText + "｜文件命中=" + hitText
            + "｜文件条目=" + String(entryCount)
    }

    static func savedMessage(for ssid: String) -> String {
        isTemporary(for: ssid) ? temporaryNotice : CWL("Wi-Fi 密码已保存到 Keychain")
    }

    private static func query(_ ssid: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.tds.carkit.wifi",
         kSecAttrAccount as String: ssid]
    }
    static func password(for ssid: String) throws -> String? {
        guard !ssid.isEmpty else { return nil }
        temporaryLock.lock()
        let temporary = temporaryPasswords[ssid]
        temporaryLock.unlock()
        if let temporary { return temporary }
        var lookup = query(ssid); lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let password = String(data: data, encoding: .utf8) {
            return password
        }
        // Not in Keychain (either absent or the signature has no entitlement): fall back
        // to the sandbox file so a TrollStore build still remembers the password.
        if status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement {
            if let stored = storedPassword(for: ssid) { return stored }
        }
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return nil
    }
    static func save(_ password: String, for ssid: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query(ssid) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(ssid).merging(attributes) { _, value in value } as CFDictionary, nil)
        }
        if status == errSecSuccess {
            temporaryLock.lock(); temporaryPasswords.removeValue(forKey: ssid); temporaryLock.unlock()
            return
        }
        guard status == errSecMissingEntitlement || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        // Signature cannot use Keychain: persist to the sandbox file and keep an in-memory
        // copy so the current session reads it back immediately.
        var dict = loadStore()
        dict[ssid] = password
        try writeStore(dict)
        temporaryLock.lock(); temporaryPasswords[ssid] = password; temporaryLock.unlock()
    }
    static func forget(_ ssid: String) throws {
        let status = SecItemDelete(query(ssid) as CFDictionary)
        var dict = loadStore()
        if dict.removeValue(forKey: ssid) != nil { try writeStore(dict) }
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        temporaryLock.lock(); defer { temporaryLock.unlock() }
        temporaryPasswords.removeValue(forKey: ssid)
    }
}

/// Persistent receiver key, independent of the accessory certificate identity.
final class AirPlayCredentials {
    /// Drops the receiver identity and every stored controller key. The next session then has
    /// to run a full pair-setup instead of pair-verify, which is how an iOS build that stalls
    /// right after pair-verify can be pushed back onto the complete handshake.
    static func resetStoredIdentity() {
        for service in ["local.tds.carkit.airplay", "local.tds.carkit.controllers"] {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service]
            SecItemDelete(query as CFDictionary)
        }
    }
    let signingKey: Curve25519.Signing.PrivateKey
    let identifier: String
    private func pairingQuery(_ identifier: String) -> [String: Any] {
        let account = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "local.tds.carkit.controllers", kSecAttrAccount as String: account]
    }
    func controller(_ identifier: String) throws -> Curve25519.Signing.PublicKey? {
        var query = pairingQuery(identifier); query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return try Curve25519.Signing.PublicKey(rawRepresentation: data)
    }
    func saveController(_ identifier: String, key: Data) throws {
        if let existing = try controller(identifier) {
            guard existing.rawRepresentation == key else { throw ProtocolError.malformed(CWL("已配对控制端的密钥发生变化")) }
            return
        }
        var item = pairingQuery(identifier); item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    init() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.tds.carkit.airplay", kSecAttrAccount as String: "identity"]
        var lookup = query; lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            guard let key = values?["key"] as? Data, let id = values?["id"] as? String else { throw ProtocolError.malformed(CWL("已存储的 AirPlay 身份无效")) }
            signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: key); identifier = id
        } else if status == errSecItemNotFound {
            signingKey = Curve25519.Signing.PrivateKey(); identifier = UUID().uuidString
            let data = try PropertyListSerialization.data(fromPropertyList: ["key": signingKey.rawRepresentation, "id": identifier], format: .binary, options: 0)
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let stored = SecItemAdd(item as CFDictionary, nil)
            guard stored == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(stored)) }
        } else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
