import CryptoKit
import Foundation
import LocalAuthentication
import Security

private enum Identity {
    case ephemeral(LAContext, SecureEnclave.P256.Signing.PrivateKey)
    case stored(RemoteSigningIdentity)

    func sign(_ data: Data) throws -> Data {
        switch self {
        case .ephemeral(_, let key): return try key.signature(for: data).derRepresentation
        case .stored(let identity): return try identity.sign(data)
        }
    }
}

private let lock = NSLock()
private var identities: [UInt64: Identity] = [:]
private var nextHandle: UInt64 = 1
private let maximumPayload = 1_048_576 + 16_384

private func report(_ error: Error) {
    let error = error as NSError
    fputs("Hardware signer failed: \(error.domain) code \(error.code)\n", stderr)
}

@_cdecl("notify_hw_create")
public func createHardwareIdentity(
    _ publicKey: UnsafeMutablePointer<UInt8>?, _ capacity: Int32
) -> UInt64 {
    guard let publicKey, capacity >= 65, SecureEnclave.isAvailable else { return 0 }
    lock.lock()
    defer { lock.unlock() }
    guard identities.count < 32, nextHandle < UInt64.max else { return 0 }
    do {
        let context = LAContext()
        context.interactionNotAllowed = true
        var controlError: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &controlError
        ) else {
            if let controlError { report(controlError.takeRetainedValue()) }
            return 0
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(
            compactRepresentable: false, accessControl: control, authenticationContext: context
        )
        let encoded = key.publicKey.x963Representation
        guard encoded.count == 65 else { return 0 }
        for (index, byte) in encoded.enumerated() { publicKey[index] = byte }
        let handle = nextHandle
        nextHandle += 1
        identities[handle] = .ephemeral(context, key)
        return handle
    } catch {
        report(error)
        return 0
    }
}

@_cdecl("notify_hw_sign")
public func signHardwareMessage(
    _ handle: UInt64, _ input: UnsafePointer<UInt8>?, _ count: Int32,
    _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int32
) -> Int32 {
    guard count >= 0, Int(count) <= maximumPayload, capacity >= 72,
          let output, count == 0 || input != nil else { return -1 }
    lock.lock()
    defer { lock.unlock() }
    guard let identity = identities[handle] else { return -1 }
    let data: Data
    if let input { data = Data(bytes: input, count: Int(count)) }
    else { data = Data() }
    do {
        let signature = try identity.sign(data)
        guard signature.count <= Int(capacity) else { return -1 }
        for (index, byte) in signature.enumerated() { output[index] = byte }
        return Int32(signature.count)
    } catch {
        report(error)
        return -1
    }
}

@_cdecl("notify_hw_destroy")
public func destroyHardwareIdentity(_ handle: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    identities.removeValue(forKey: handle)
}

private func store(_ bytes: UnsafePointer<UInt8>?, _ count: Int32) throws -> RemoteIdentityStore {
    guard let bytes, count == 36,
          let text = String(bytes: UnsafeBufferPointer(start: bytes, count: 36), encoding: .utf8),
          let id = UUID(uuidString: text) else { throw RemoteIdentityError.invalidRecord }
    return RemoteIdentityStore(id: id)
}

@_cdecl("notify_hw_persist")
public func persistHardwareIdentity(
    _ id: UnsafePointer<UInt8>?, _ count: Int32, _ publicKey: UnsafeMutablePointer<UInt8>?,
    _ capacity: Int32
) -> Int32 {
    guard let publicKey, capacity == 65 else { return -1 }
    do {
        let identity = try store(id, count).create()
        for (index, byte) in identity.publicKey.enumerated() { publicKey[index] = byte }
        return 0
    } catch {
        report(error)
        return -1
    }
}

@_cdecl("notify_hw_load")
public func loadHardwareIdentity(
    _ id: UnsafePointer<UInt8>?, _ count: Int32, _ publicKey: UnsafePointer<UInt8>?,
    _ keyLength: Int32
) -> UInt64 {
    guard let publicKey, keyLength == 65 else { return 0 }
    lock.lock()
    defer { lock.unlock() }
    guard identities.count < 32, nextHandle < UInt64.max else { return 0 }
    do {
        let identity = try store(id, count).load(expectedPublicKey: Data(bytes: publicKey, count: 65))
        let handle = nextHandle
        nextHandle += 1
        identities[handle] = .stored(identity)
        return handle
    } catch {
        report(error)
        return 0
    }
}

@_cdecl("notify_hw_delete")
public func deleteHardwareIdentity(_ id: UnsafePointer<UInt8>?, _ count: Int32) -> Int32 {
    do {
        try store(id, count).delete()
        return 0
    } catch {
        report(error)
        return -1
    }
}
