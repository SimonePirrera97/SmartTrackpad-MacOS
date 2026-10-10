import Foundation

/// Shared validation for camera-free pairing; contains no UI or network types.
enum PairingEntry {
    static func invitation(address: String, keyOrInvitation: String) throws -> PairingInvitation {
        let text = keyOrInvitation.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(PairingInvitation.prefix) {
            do { return try PairingInvitation.decode(text) }
            catch { throw EntryError.invalidDetails }
        }
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw EntryError.missingAddress }
        guard !host.contains(":"), !host.contains("/"), !host.contains("@"),
              host.allSatisfy({ $0.isASCII && !$0.isWhitespace }), host.utf8.count <= 255 else {
            throw EntryError.invalidAddress
        }
        _ = try PairingSecret.decode(text)
        return PairingInvitation(version: 1, host: host, port: 47821,
                                 key: text.filter { !$0.isWhitespace }.lowercased())
    }

    enum EntryError: LocalizedError {
        case missingAddress, invalidAddress, invalidDetails
        var errorDescription: String? {
            switch self {
            case .missingAddress: "Enter the Mac Wi-Fi address, or paste pairing details copied from the Mac. A key alone does not include an address."
            case .invalidAddress: "Enter only the Mac Wi-Fi address, such as 192.168.1.20, without a URL or port."
            case .invalidDetails: "These pairing details are invalid. Copy fresh pairing details from the Mac."
            }
        }
    }
}
