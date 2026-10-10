import Foundation

enum MessageKind: String, Codable, Sendable {
    case pairRequest, pairAccept, pairReject, sessionRequest, sessionAccept, heartbeat, disconnect, pointerMove, input
}

struct PointerDelta: Codable, Sendable, Equatable {
    let dx: Double
    let dy: Double
    var valid: Bool { dx.isFinite && dy.isFinite && abs(dx) <= 128 && abs(dy) <= 128 }
    var scrollValid: Bool { dx.isFinite && dy.isFinite && abs(dx) <= 2048 && abs(dy) <= 2048 }
}

struct WireMessage: Codable, Sendable {
    static let currentVersion = 2
    let version: Int
    let session: String
    let sequence: UInt64
    let timestampMilliseconds: UInt64
    let type: MessageKind
    let code: String?
    var delta: PointerDelta? = nil
    var input: InputCommand? = nil
    var capabilities: [String]? = nil
    var appContext: AppControlContext? = nil
    var trackpadPreferences: TrackpadPreferences? = nil

    func validate() throws {
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
        if type == .pointerMove {
            guard let delta, delta.valid else { throw WireError.invalidMessage }
        } else if delta != nil { throw WireError.invalidMessage }
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

    func encoded() throws -> Data {
        try validate()
        var data = try JSONEncoder().encode(self)
        guard data.count <= LineFramer.maximumSize else { throw WireError.tooLarge }
        data.append(10)
        return data
    }
}

enum WireError: Error { case invalidMessage, tooLarge }

struct LineFramer {
    static let maximumSize = 4096
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [WireMessage] {
        var messages: [WireMessage] = []
        // Bound incomplete frames independently of receive chunk boundaries.
        for byte in data {
            if byte == 10 {
                let message = try JSONDecoder().decode(WireMessage.self, from: buffer)
                try message.validate()
                messages.append(message)
                buffer.removeAll(keepingCapacity: true)
            } else {
                guard buffer.count < Self.maximumSize else { throw WireError.tooLarge }
                buffer.append(byte)
            }
        }
        return messages
    }
}
