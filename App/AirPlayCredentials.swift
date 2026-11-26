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
///
/// Keychain is preferred, but a TrollStore (ldid) signature can report `SecItemAdd` success and
/// still not persist the item, which made the receiver mint a brand-new AirPlay identity on every
/// launch. iOS then saw "same name, different accessory" and refused to connect the RTSP endpoint.
/// The identity is therefore mirrored into the app sandbox and read back from there as a fallback.
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
        if let url = identityURL { try? FileManager.default.removeItem(at: url) }
        if let url = controllersURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: sandbox mirror

    private static var identityURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("airplay-identity.json")
    }
    private static var controllersURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("airplay-controllers.json")
    }
    private static func readMap(_ url: URL?) -> [String: String] {
        guard let url, let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }
    private static func writeMap(_ map: [String: String], to url: URL?) throws {
        guard let url else { return }
        let data = try JSONEncoder().encode(map)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Hex public key of the active receiver identity, published to iAP2 StartSession.
    private(set) static var currentPublicKey = ""
    let signingKey: Curve25519.Signing.PrivateKey
    let identifier: String
    private func pairingQuery(_ identifier: String) -> [String: Any] {
        let account = Self.account(for: identifier)
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "local.tds.carkit.controllers", kSecAttrAccount as String: account]
    }
    private static func account(for identifier: String) -> String {
        SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func controller(_ identifier: String) throws -> Curve25519.Signing.PublicKey? {
        var query = pairingQuery(identifier); query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) {
            return key
        }
        guard let encoded = Self.readMap(Self.controllersURL)[Self.account(for: identifier)],
              let data = Data(base64Encoded: encoded) else { return nil }
        return try Curve25519.Signing.PublicKey(rawRepresentation: data)
    }
    func saveController(_ identifier: String, key: Data) throws {
        if let existing = try controller(identifier) {
            guard existing.rawRepresentation == key else { throw ProtocolError.malformed(CWL("已配对控制端的密钥发生变化")) }
            return
        }
        var map = Self.readMap(Self.controllersURL)
        map[Self.account(for: identifier)] = key.base64EncodedString()
        try Self.writeMap(map, to: Self.controllersURL)
        var item = pairingQuery(identifier); item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        _ = SecItemAdd(item as CFDictionary, nil)
    }
    init() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.tds.carkit.airplay", kSecAttrAccount as String: "identity"]
        var lookup = query; lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let values = plist as? [String: Any],
           let key = values["key"] as? Data, let id = values["id"] as? String,
           let parsed = try? Curve25519.Signing.PrivateKey(rawRepresentation: key) {
            signingKey = parsed; identifier = id
            Self.currentPublicKey = parsed.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
            return
        }
        // Keychain empty or unreliable: reuse the sandbox copy so the identity stays stable.
        let mirrored = Self.readMap(Self.identityURL)
        if let encoded = mirrored["key"], let id = mirrored["id"],
           let keyData = Data(base64Encoded: encoded),
           let parsed = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) {
            signingKey = parsed; identifier = id
            Self.currentPublicKey = parsed.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
            Self.persist(keyData, id: id)
            return
        }
        let key = Curve25519.Signing.PrivateKey()
        signingKey = key
        identifier = UUID().uuidString
        Self.currentPublicKey = key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        Self.persist(key.rawRepresentation, id: identifier)
    }
    /// Set by the receiver so identity persistence failures are visible in the log.
    static var onLog: ((String) -> Void)?
    private static func persist(_ key: Data, id: String) {
        var map = readMap(identityURL)
        map["key"] = key.base64EncodedString()
        map["id"] = id
        do { try writeMap(map, to: identityURL) }
        catch { onLog?(CWL("AirPlay 身份保存失败：{1}", [String(describing: error)])) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.tds.carkit.airplay", kSecAttrAccount as String: "identity"]
        if let data = try? PropertyListSerialization.data(
            fromPropertyList: ["key": key, "id": id], format: .binary, options: 0) {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemDelete(query as CFDictionary)
            _ = SecItemAdd(item as CFDictionary, nil)
        }
    }
}
