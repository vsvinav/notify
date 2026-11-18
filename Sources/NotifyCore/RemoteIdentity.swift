import CryptoKit
import Foundation
import LocalAuthentication
import Security

public enum RemoteIdentityError: Error, Equatable, LocalizedError {
    case missing, alreadyExists, accessDenied, invalidRecord, identityChanged
    case hardwareUnavailable, payloadTooLarge
    case storage(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missing: return "The saved phone connection identity is missing. Pair again from this Mac."
        case .alreadyExists: return "This connection identity already exists. It was not replaced."
        case .accessDenied: return "macOS denied access to the connection identity. Unlock your Mac and try again. After an app update, you may need to pair again."
        case .invalidRecord: return "The saved connection identity is damaged. Phone access remains paused."
        case .identityChanged: return "The connection identity does not match. Pair again from this Mac."
        case .hardwareUnavailable: return "The Mac's protected signing key is unavailable. Phone access remains paused."
        case .payloadTooLarge: return "The message is too large to sign."
        case .storage(let status): return "Connection identity storage failed (\(status)). Phone access remains paused."
        }
    }
}

public final class RemoteSigningIdentity {
    public let id: UUID
    public let publicKey: Data
    private let key: SecureEnclave.P256.Signing.PrivateKey
    private let context: LAContext

    fileprivate init(id: UUID, key: SecureEnclave.P256.Signing.PrivateKey, context: LAContext) {
        self.id = id
        self.key = key
        self.context = context
        publicKey = key.publicKey.x963Representation
    }

    public func sign(_ message: Data) throws -> Data {
        guard message.count <= 1_064_960 else { throw RemoteIdentityError.payloadTooLarge }
        do { return try key.signature(for: message).derRepresentation }
        catch { throw RemoteIdentityError.hardwareUnavailable }
    }
}

// Explicit local setup only. Loading never creates or replaces an identity.
public struct RemoteIdentityStore {
    private static let lock = NSLock()
    private static let service = "dev.notify.remote-signing-identity"
    private let id: UUID

    private struct Record: Codable {
        let version: Int
        let id: UUID
        let publicKey: Data
        let wrappedKey: Data
    }

    public init(id: UUID) { self.id = id }

    public func create() throws -> RemoteSigningIdentity {
        try withKeychain { keychain in
            let existing = SecItemCopyMatching(query(keychain) as CFDictionary, nil)
            if existing == errSecSuccess { throw RemoteIdentityError.alreadyExists }
            if existing != errSecItemNotFound { try Self.check(existing) }
            guard SecureEnclave.isAvailable else { throw RemoteIdentityError.hardwareUnavailable }
            let context = LAContext()
            context.interactionNotAllowed = true
            var controlError: Unmanaged<CFError>?
            guard let control = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &controlError
            ) else {
                _ = controlError?.takeRetainedValue()
                throw RemoteIdentityError.hardwareUnavailable
            }
            let key: SecureEnclave.P256.Signing.PrivateKey
            do {
                key = try SecureEnclave.P256.Signing.PrivateKey(
                    compactRepresentable: false, accessControl: control, authenticationContext: context
                )
            } catch { throw RemoteIdentityError.hardwareUnavailable }
            let record = Record(version: 1, id: id, publicKey: key.publicKey.x963Representation,
                                wrappedKey: key.dataRepresentation)
            let data = try JSONEncoder().encode(record)
            guard data.count <= 4096 else { throw RemoteIdentityError.invalidRecord }
            var trusted: SecTrustedApplication?
            try Self.check(SecTrustedApplicationCreateFromPath(nil, &trusted))
            guard let trusted else { throw RemoteIdentityError.invalidRecord }
            var access: SecAccess?
            try Self.check(SecAccessCreate(
                "Notify phone connection identity" as CFString, [trusted] as CFArray, &access
            ))
            guard let access else { throw RemoteIdentityError.invalidRecord }
            try Self.check(SecItemAdd([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: id.uuidString,
                kSecAttrLabel as String: "Notify phone connection identity",
                kSecValueData as String: data,
                kSecAttrAccess as String: access,
                kSecUseKeychain as String: keychain
            ] as CFDictionary, nil))
            return RemoteSigningIdentity(id: id, key: key, context: context)
        }
    }

    public func load(expectedPublicKey: Data) throws -> RemoteSigningIdentity {
        guard expectedPublicKey.count == 65 else { throw RemoteIdentityError.identityChanged }
        return try withKeychain { keychain in
            var search = query(keychain)
            search[kSecReturnData as String] = true
            var value: CFTypeRef?
            try Self.check(SecItemCopyMatching(search as CFDictionary, &value))
            guard let data = value as? Data, data.count <= 4096 else {
                throw RemoteIdentityError.invalidRecord
            }
            let record: Record
            do { record = try JSONDecoder().decode(Record.self, from: data) }
            catch { throw RemoteIdentityError.invalidRecord }
            guard record.version == 1, record.id == id, record.publicKey.count == 65,
                  !record.wrappedKey.isEmpty else { throw RemoteIdentityError.invalidRecord }
            guard record.publicKey == expectedPublicKey else { throw RemoteIdentityError.identityChanged }
            let context = LAContext()
            context.interactionNotAllowed = true
            let key: SecureEnclave.P256.Signing.PrivateKey
            do {
                key = try SecureEnclave.P256.Signing.PrivateKey(
                    dataRepresentation: record.wrappedKey, authenticationContext: context
                )
            } catch { throw RemoteIdentityError.hardwareUnavailable }
            guard key.publicKey.x963Representation == expectedPublicKey else {
                throw RemoteIdentityError.identityChanged
            }
            return RemoteSigningIdentity(id: id, key: key, context: context)
        }
    }

    public func delete() throws {
        try withKeychain { keychain in
            var search = query(keychain)
            search.removeValue(forKey: kSecMatchLimit as String)
            try Self.check(SecItemDelete(search as CFDictionary))
        }
    }

    private func query(_ keychain: SecKeychain) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id.uuidString,
            kSecMatchSearchList as String: [keychain],
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
    }

    private static func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw RemoteIdentityError.missing
        case errSecDuplicateItem: throw RemoteIdentityError.alreadyExists
        case errSecAuthFailed, errSecInteractionNotAllowed: throw RemoteIdentityError.accessDenied
        default: throw RemoteIdentityError.storage(status)
        }
    }

    private func withKeychain<T>(_ operation: (SecKeychain) throws -> T) throws -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        // File-Keychain UI suppression is process-wide, not an OS preference.
        // Serialize these calls and restore the previous value on both error and success.
        var allowed = DarwinBoolean(false)
        try Self.check(SecKeychainGetUserInteractionAllowed(&allowed))
        try Self.check(SecKeychainSetUserInteractionAllowed(false))
        let result = Result {
            var keychain: SecKeychain?
            try Self.check(SecKeychainCopyDefault(&keychain))
            guard let keychain else { throw RemoteIdentityError.invalidRecord }
            return try operation(keychain)
        }
        try Self.check(SecKeychainSetUserInteractionAllowed(allowed.boolValue))
        return try result.get()
    }
}
