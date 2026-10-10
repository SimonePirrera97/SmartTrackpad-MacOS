import Foundation

enum PairingSecret {
    static func decode(_ text: String) throws -> Data {
        let compact = text.filter { !$0.isWhitespace }
        guard compact.utf8.count == 64, compact.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw SecretError.invalidKey
        }
        var bytes = Data()
        var index = compact.startIndex
        while index < compact.endIndex {
            let end = compact.index(index, offsetBy: 2)
            guard let value = UInt8(compact[index..<end], radix: 16) else { throw SecretError.invalidKey }
            bytes.append(value)
            index = end
        }
        return bytes
    }

    enum SecretError: LocalizedError {
        case invalidKey, randomGenerationFailed
        var errorDescription: String? {
            switch self {
            case .invalidKey: "Paste the 64-character pairing key from the Mac"
            case .randomGenerationFailed: "Could not generate a pairing key"
            }
        }
    }
}
