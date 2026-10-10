import Foundation
import Security

extension PairingSecret {
    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SecretError.randomGenerationFailed
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
