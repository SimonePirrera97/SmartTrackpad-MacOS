import Foundation
import Network
import Security

enum SecureTransport {
    static let identity = "smart-trackpad-v2"
    // Standard TLS-PSK suite, also implementable by an embedded TLS stack.
    static let cipher = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!

    /// `boardKey` lets a listener also accept the remembered board, and makes
    /// a client connect as that board when it is the only key given.
    static func parameters(key: Data?, boardKey: Data? = nil) -> NWParameters {
        precondition(key?.count ?? 32 == 32 && boardKey?.count ?? 32 == 32 && (key != nil || boardKey != nil))
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        // No identity hint: a hint naming one key makes a client holding only
        // the other key give up, and each client selects its key by identity anyway.
        for (secret, label) in [(key, identity), (boardKey, BoardKeyStore.identity)] {
            guard let secret else { continue }
            let bytes = secret.withUnsafeBytes { DispatchData(bytes: $0) }
            let label = Data(label.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options, bytes as __DispatchData, label as __DispatchData)
        }
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, cipher)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    static func authenticated(_ peer: NWConnection) -> Bool {
        guard let tls = peer.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return false }
        let metadata = tls.securityProtocolMetadata
        // Reject any negotiated fallback before reading or sending app messages.
        return sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata) == .TLSv12
            && sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata) == cipher
    }
}
