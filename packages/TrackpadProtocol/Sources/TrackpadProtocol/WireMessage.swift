import Foundation

enum MessageKind: String, Codable, Sendable {
    case pairRequest, pairAccept, pairReject, sessionRequest, sessionAccept, heartbeat, disconnect, input
    /// Cable only: the Mac hands a dedicated board its permanent key; the board confirms.
    case enroll, enrolled
}

struct PointerDelta: Codable, Sendable, Equatable {
    let dx: Double
    let dy: Double
    var valid: Bool { dx.isFinite && dy.isFinite && abs(dx) <= 128 && abs(dy) <= 128 }
    var scrollValid: Bool { dx.isFinite && dy.isFinite && abs(dx) <= 2048 && abs(dy) <= 2048 }
}

/// Sent once over the trusted cable so the board can later connect wirelessly.
struct BoardEnrollment: Codable, Sendable, Equatable {
    /// 64 hexadecimal characters.
    let key: String
    /// The Mac's local network name, such as "My-Mac.local".
    let host: String
    /// Shown on the board.
    let name: String
    var valid: Bool {
        (try? PairingSecret.decode(key)) != nil && !host.isEmpty && host.utf8.count <= 255
            && host.allSatisfy({ $0.isASCII && !$0.isWhitespace }) && !name.isEmpty && name.utf8.count <= 64
    }
}

struct WireMessage: Codable, Sendable {
    static let currentVersion = 2
    /// Largest JSON frame, excluding its newline terminator.
    static let maximumSize = 4096
    let version: Int
    let session: String
    let sequence: UInt64
    let timestampMilliseconds: UInt64
    let type: MessageKind
    let code: String?
    var input: InputCommand? = nil
    var capabilities: [String]? = nil
    var appContext: AppControlContext? = nil
    var trackpadPreferences: TrackpadPreferences? = nil
    var acknowledgedInputSequence: UInt64? = nil
    var enrollment: BoardEnrollment? = nil
    /// A remembered board's proof of its key, on a wireless pairRequest.
    var boardProof: String? = nil

    func validate() throws {
        if let enrollment {
            guard type == .enroll, enrollment.valid else { throw WireError.invalidMessage }
        } else if type == .enroll { throw WireError.invalidMessage }
        if let boardProof {
            guard type == .pairRequest, boardProof.utf8.count == 64,
                  boardProof.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw WireError.invalidMessage }
        }
        if let acknowledgedInputSequence {
            guard type == .heartbeat, acknowledgedInputSequence > 0 else { throw WireError.invalidMessage }
        }
        if let appContext {
            guard (type == .pairAccept || type == .sessionAccept || type == .heartbeat), appContext.valid else { throw WireError.invalidMessage }
        }
        if let trackpadPreferences {
            guard (type == .pairAccept || type == .sessionAccept), trackpadPreferences.valid,
                  capabilities?.contains("settings.trackpadPreferences") == true else { throw WireError.invalidMessage }
        }
        guard version == Self.currentVersion, UUID(uuidString: session) != nil, sequence > 0 else {
            throw WireError.invalidMessage
        }
        if type == .pairRequest {
            guard let code, code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                throw WireError.invalidMessage
            }
        } else if code != nil {
            throw WireError.invalidMessage
        }
        if type == .input {
            guard let input, input.valid else { throw WireError.invalidMessage }
            if let sampleTime = input.sampleTimestampMilliseconds, sampleTime > timestampMilliseconds {
                throw WireError.invalidMessage
            }
        } else if input != nil { throw WireError.invalidMessage }
        if type == .pairRequest || type == .pairAccept || type == .sessionRequest || type == .sessionAccept {
            guard let capabilities, !capabilities.isEmpty, capabilities.count <= 16,
                  Set(capabilities).count == capabilities.count,
                  capabilities.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 && $0.allSatisfy(\.isASCII) }) else {
                throw WireError.invalidMessage
            }
        } else if capabilities != nil { throw WireError.invalidMessage }
    }

    /// One validated newline-terminated JSON frame.
    func encoded(using encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        try validate()
        var data = try encoder.encode(self)
        guard data.count <= Self.maximumSize else { throw WireError.tooLarge }
        data.append(10)
        return data
    }
}

enum WireError: Error { case invalidMessage, tooLarge }
