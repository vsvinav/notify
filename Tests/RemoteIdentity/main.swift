import CryptoKit
import Foundation
import NotifyCore
import Security

func expect(_ expected: RemoteIdentityError, _ operation: () throws -> Void) throws {
    do {
        try operation()
        fatalError("Expected \(expected)")
    } catch let error as RemoteIdentityError {
        precondition(error == expected, "Expected \(expected), got \(error)")
    }
}

guard CommandLine.arguments.count == 4,
      let id = UUID(uuidString: CommandLine.arguments[2]) else {
    fatalError("Pass operation, unique synthetic identity UUID and public-key file")
}
let operation = CommandLine.arguments[1]
let publicFile = URL(fileURLWithPath: CommandLine.arguments[3])
let store = RemoteIdentityStore(id: id)
var originalInteraction = DarwinBoolean(false)
precondition(SecKeychainGetUserInteractionAllowed(&originalInteraction) == errSecSuccess)

#if NOTIFY_UPDATED_IDENTITY_CHECK
print("Changed build with the same signing identifier")
#endif

do {
    switch operation {
    case "create":
        let identity = try store.create()
        try identity.publicKey.write(to: publicFile, options: .withoutOverwriting)
        try expect(.alreadyExists) { _ = try store.create() }
        print("Created synthetic hardware identity; duplicate creation rejected")
    case "load":
        let publicKey = try Data(contentsOf: publicFile)
        let identity = try store.load(expectedPublicKey: publicKey)
        precondition(identity.id == id && identity.publicKey == publicKey)
        let verifier = try P256.Signing.PublicKey(x963Representation: publicKey)
        let message = Data("Notify synthetic persisted identity".utf8)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: identity.sign(message))
        precondition(verifier.isValidSignature(signature, for: message))
        precondition(!verifier.isValidSignature(signature, for: Data("changed".utf8)))
        let other = P256.Signing.PrivateKey().publicKey.x963Representation
        try expect(.identityChanged) { _ = try store.load(expectedPublicKey: other) }
        try expect(.payloadTooLarge) { _ = try identity.sign(Data(count: 1_064_961)) }
        print("Same identity restored and signed after process restart; wrong identity rejected")
    case "denied":
        let publicKey = try Data(contentsOf: publicFile)
        try expect(.accessDenied) { _ = try store.load(expectedPublicKey: publicKey) }
        print("Other code identity denied without replacing the stored key")
    case "corrupt":
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.notify.remote-signing-identity",
            kSecAttrAccount as String: id.uuidString
        ]
        // Only the uniquely named synthetic item created by this runner is modified.
        precondition(SecKeychainSetUserInteractionAllowed(false) == errSecSuccess)
        let status = SecItemUpdate(query as CFDictionary, [
            kSecValueData as String: Data("invalid fixture record".utf8)
        ] as CFDictionary)
        precondition(SecKeychainSetUserInteractionAllowed(originalInteraction.boolValue) == errSecSuccess)
        precondition(status == errSecSuccess)
        let publicKey = try Data(contentsOf: publicFile)
        try expect(.invalidRecord) { _ = try store.load(expectedPublicKey: publicKey) }
        try expect(.alreadyExists) { _ = try store.create() }
        print("Corrupt storage rejected without automatic replacement")
    case "delete":
        try store.delete()
        print("Synthetic identity deleted")
    case "cleanup":
        do { try store.delete() }
        catch RemoteIdentityError.missing {}
        print("Synthetic cleanup complete")
    case "absent":
        let key = P256.Signing.PrivateKey().publicKey.x963Representation
        try expect(.missing) { _ = try store.load(expectedPublicKey: key) }
        try expect(.missing) { try store.delete() }
        print("Synthetic identity absence verified")
    default:
        fatalError("Unknown synthetic operation")
    }
    var currentInteraction = DarwinBoolean(false)
    precondition(SecKeychainGetUserInteractionAllowed(&currentInteraction) == errSecSuccess)
    precondition(currentInteraction.boolValue == originalInteraction.boolValue)
} catch {
    fputs("Remote identity check failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
