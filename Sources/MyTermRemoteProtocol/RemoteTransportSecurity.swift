import CryptoKit
import Foundation
import Network

/// Builds the TLS parameters both ends of a MyTerm Remote connection use.
///
/// The connection is authenticated and encrypted with a pre-shared key derived from the pairing
/// token, so a device that does not hold the token cannot complete a handshake, and nothing on the
/// network can read terminal bytes. A pre-shared key avoids shipping a certificate authority into
/// the app for what is a two-party link between devices the same person owns.
public enum RemoteTransportSecurity {
    /// Separates this key from any other use of the same token.
    private static let keyContext = Data("myterm-remote-psk-v1".utf8)
    private static let identity = Data("myterm-remote".utf8)

    public static func parameters(token: String) -> NWParameters {
        let options = NWProtocolTLS.Options()
        let key = derivedKey(token: token)

        key.withUnsafeBytes { keyBytes in
            identity.withUnsafeBytes { identityBytes in
                sec_protocol_options_add_pre_shared_key(
                    options.securityProtocolOptions,
                    DispatchData(bytes: keyBytes) as __DispatchData,
                    DispatchData(bytes: identityBytes) as __DispatchData
                )
            }
        }
        sec_protocol_options_append_tls_ciphersuite(
            options.securityProtocolOptions,
            tls_ciphersuite_t.AES_128_GCM_SHA256
        )
        sec_protocol_options_set_min_tls_protocol_version(
            options.securityProtocolOptions,
            .TLSv12
        )

        let parameters = NWParameters(tls: options)
        // A terminal is interactive. Coalescing keystrokes to fill a packet is the wrong trade.
        parameters.serviceClass = .responsiveData
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
        }
        return parameters
    }

    static func derivedKey(token: String) -> Data {
        var hasher = SHA256()
        hasher.update(data: keyContext)
        hasher.update(data: Data(token.utf8))
        return Data(hasher.finalize())
    }

    /// A fresh pairing token. 32 hexadecimal characters carry 128 bits.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
