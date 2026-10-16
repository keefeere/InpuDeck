import CryptoKit
import Foundation
import Security

/// Keychain-backed access password for the "Команди" tab.
///
/// The password itself is never stored; only a salted SHA-256 digest lives in
/// the Keychain (encrypted at rest, device-only). This mirrors the bank-app
/// flow: the password is the primary credential and biometrics are an
/// optional convenience added on top of it.
enum CommandletCredentials {
    private static let service = "com.keefeere.InpuDeck.commands"
    private static let hashAccount = "access-password-hash"
    private static let saltAccount = "access-password-salt"

    /// True when a password has been set for the commands tab.
    static var hasPassword: Bool {
        read(hashAccount) != nil && read(saltAccount) != nil
    }

    /// Stores `password` as `SHA256(salt + password)` with a fresh random salt.
    @discardableResult
    static func setPassword(_ password: String) -> Bool {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        guard write(salt, saltAccount) else { return false }
        return write(digest(password, salt: salt), hashAccount)
    }

    /// Checks `password` against the stored digest.
    static func verify(_ password: String) -> Bool {
        guard let salt = read(saltAccount), let expected = read(hashAccount) else { return false }
        return digest(password, salt: salt) == expected
    }

    private static func digest(_ password: String, salt: Data) -> Data {
        var input = salt
        input.append(Data(password.utf8))
        return Data(SHA256.hash(data: input))
    }

    private static func read(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return data
    }

    private static func write(_ data: Data, _ account: String) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var newItem: CFTypeRef?
        let addStatus = SecItemAdd(query as CFDictionary, &newItem)
        if addStatus == errSecSuccess { return true }
        guard addStatus == errSecDuplicateItem else { return false }
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
    }
}
