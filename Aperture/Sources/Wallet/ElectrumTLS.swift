import Foundation
import Network
import Security

/// TLS parameters for Electrum / Electrum-Cash peers.
///
/// Public Electrum servers almost always present **self-signed** certificates.
/// Default `NWParameters.tls` performs full CA verification and fails with
/// `CERTIFICATE_VERIFY_FAILED` on Simulator and device — the same path that
/// broke BTC balance scans when no peer accepted.
///
/// Desktop Electrum clients use TOFU / allow-self-signed on this transport
/// only (encrypted channel; identity is not CA-backed). This must **not** be
/// reused for HTTPS REST (Esplora, mempool, etc.).
enum ElectrumTLS {
    /// Network parameters for one Electrum connection.
    /// - Parameter tls: when `true`, TLS with peer-cert accept-all; otherwise cleartext TCP.
    static func parameters(tls: Bool) -> NWParameters {
        guard tls else { return .tcp }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { _, _, complete in
                // Allow self-signed / non-CA Electrum peer certs (Electrum TOFU model).
                complete(true)
            },
            .global()
        )
        return NWParameters(tls: options)
    }
}
