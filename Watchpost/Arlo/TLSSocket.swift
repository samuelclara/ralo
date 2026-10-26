import Foundation
import Network

/// A raw TLS byte stream, for Arlo's MQTT broker and its RTSPS stream servers.
///
/// Neither speaks HTTP (the broker takes plain MQTT over TLS on port 443), so this uses
/// Network.framework rather than URLSession. Same rules as the REST transport:
/// TLS 1.2 or later, and proxies are never used.
final class TLSSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.watchpost.tls")

    /// - Parameter certificateName: the name the server's certificate must be valid for, when
    ///   `host` is a bare IP address. The chain is still checked against the system's roots.
    init(host: String, port: UInt16 = 443, certificateName: String? = nil) {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        if let certificateName {
            sec_protocol_options_set_verify_block(security, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, certificateName as CFString))
                complete(SecTrustEvaluateWithError(secTrust, nil))
            }, DispatchQueue.global(qos: .userInitiated))
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 25
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.preferNoProxies = true
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .https,
            using: parameters
        )
    }

    /// Opens the connection and returns once TLS is up.
    func open() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Handled once: after that a dropped connection shows up as a failed receive.
                connection.stateUpdateHandler = { [connection] state in
                    switch state {
                    case .ready:
                        connection.stateUpdateHandler = nil
                        continuation.resume()
                    case .failed(let error), .waiting(let error):
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    case .cancelled:
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// The next chunk of bytes from the broker. Throws once the connection has closed.
    func receive() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: NWError.posix(.ECONNRESET))
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Sends a last message if there is one (e.g. MQTT's DISCONNECT), then closes.
    func close(sending goodbye: Data? = nil) {
        guard let goodbye else {
            connection.cancel()
            return
        }
        connection.send(content: goodbye, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }
}
