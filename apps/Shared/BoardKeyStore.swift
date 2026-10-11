import CryptoKit
import Foundation
import Security

/// The permanent key of the one remembered dedicated board. It is created on
/// the Mac, handed to the board over the trusted USB cable, and from then on
/// lets that board connect wirelessly without a pairing key or approval.
struct BoardKeyStore {
    static let identity = "smart-trackpad-board"
    static let capability = "board.enroll.v1"
    /// Advertised by a board that already holds a key.
    static let enrolledCapability = "board.enrolled.v1"

    var load: () -> Data?
    var save: (Data) -> Bool
    var delete: () -> Void

    /// What a board sends with its wireless pair request. Only the holder of
    /// the board key can produce it, and it is only ever sent inside a TLS
    /// session that was itself set up with that key.
    static func proof(key: Data, session: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(("smart-trackpad-board-proof-v1:" + session).utf8),
                                                   using: SymmetricKey(data: key))
        return code.map { String(format: "%02x", $0) }.joined()
    }

    static func accepts(proof: String, key: Data, session: String) -> Bool {
        let expected = Array(Self.proof(key: key, session: session).utf8), given = Array(proof.utf8)
        guard expected.count == given.count else { return false }
        // Compare every byte regardless of where the first difference is.
        return zip(expected, given).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// For checks: nothing touches the user's keychain.
    static func memory() -> BoardKeyStore {
        final class Box: @unchecked Sendable { var key: Data? }
        let box = Box()
        return BoardKeyStore(load: { box.key }, save: { box.key = $0; return true }, delete: { box.key = nil })
    }

    static var keychain: BoardKeyStore {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "SmartTrackpad.board",
                                    kSecAttrAccount as String: identity]
        return BoardKeyStore(load: {
            var request = query
            request[kSecReturnData as String] = true
            var item: CFTypeRef?
            guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
                  let key = item as? Data, key.count == 32 else { return nil }
            return key
        }, save: { key in
            SecItemDelete(query as CFDictionary)
            var item = query
            item[kSecValueData as String] = key
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }, delete: { SecItemDelete(query as CFDictionary) })
    }
}
