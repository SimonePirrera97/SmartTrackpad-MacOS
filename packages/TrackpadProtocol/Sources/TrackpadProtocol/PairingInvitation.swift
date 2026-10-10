import Foundation

struct PairingInvitation: Codable {
    let version: Int
    let host: String
    let port: UInt16
    let key: String
    static let prefix = "smart-trackpad:"

    func validate() throws {
        guard version == 1, port == 47821, !host.isEmpty, host.utf8.count <= 255,
              host.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }),
              !host.contains("/"), !host.contains("@") else { throw WireError.invalidMessage }
        _ = try PairingSecret.decode(key)
    }

    func encoded() throws -> String {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return Self.prefix + (try encoder.encode(self)).base64EncodedString()
    }

    static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= 2048, text.hasPrefix(prefix),
              let data = Data(base64Encoded: String(text.dropFirst(prefix.count))), data.count <= 1024 else {
            throw WireError.invalidMessage
        }
        let invitation = try JSONDecoder().decode(Self.self, from: data)
        try invitation.validate()
        return invitation
    }
}
