import Foundation
import os

/// Arlo's live event feed: mode changes, motion, battery, and the replies two-way talk needs.
///
/// Current accounts use MQTT over TLS; older ones use server-sent events.
/// Either way the connection only lives while the app is unlocked and in the foreground.
@MainActor
final class ArloEventStream {
    enum Backend { case mqtt(host: String), sse }

    var onEvent: ((ArloEvent) -> Void)?
    var onUnauthorized: (() -> Void)?
    /// Called each time the feed (re)connects, so state asked for now isn't missed.
    var onConnected: (() -> Void)?
    private(set) var isConnected = false {
        didSet { if isConnected, !oldValue { onConnected?() } }
    }

    private let client: ArloClient
    private let logger = Logger(subsystem: "com.watchpost", category: "events")
    private var runTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var mqttSocket: TLSSocket?
    private var keepAliveBases: [ArloDevice] = []

    private let streamSession: URLSession

    init(client: ArloClient) {
        self.client = client
        let config = ArloTransport.hardenedConfiguration()
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 24 * 60 * 60
        streamSession = URLSession(configuration: config, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    func start(devices: [ArloDevice], sessionInfo: SessionInfo) {
        stop()
        let topics = Array(Set(devices.flatMap(\.allowedMQTTTopics))).sorted()
        let backend: Backend
        if !topics.isEmpty {
            backend = .mqtt(host: Self.trustedMQTTHost(sessionInfo.mqttHost))
        } else {
            backend = .sse
        }

        keepAliveBases = devices.filter { device in
            let isParent = devices.contains { $0.parentId == device.id } || device.isBaseStation
            return isParent && !device.shouldSkipKeepAlive
        }

        runTask = Task { [weak self] in
            var delay: Double = 2
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    switch backend {
                    case .mqtt(let host):
                        try await self.runMQTT(host: host, topics: topics)
                    case .sse:
                        try await self.runSSE()
                    }
                } catch ArloError.unauthorized {
                    self.onUnauthorized?()
                    return
                } catch {
                    if Task.isCancelled { return }
                    self.logger.notice("event stream dropped: \(String(describing: type(of: error)), privacy: .public)")
                }
                if Task.isCancelled { return }
                // A connection that got going resets the backoff; one that failed straight away grows it.
                delay = self.isConnected ? 2 : min(delay * 2, 60)
                self.isConnected = false
                try? await Task.sleep(for: .seconds(delay))
            }
        }

        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for base in self.keepAliveBases {
                    await self.client.keepAlive(base: base)
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Makes sure a particular base is sending events, e.g. before two-way talk.
    func wake(base: ArloDevice) async {
        await client.keepAlive(base: base)
    }

    func stop() {
        runTask?.cancel()
        keepAliveTask?.cancel()
        runTask = nil
        keepAliveTask = nil
        mqttSocket?.close(sending: MQTTPacket.disconnect)
        mqttSocket = nil
        isConnected = false
    }

    /// Stops and frees the connection for good, when the app locks or signs out.
    func invalidate() {
        stop()
        streamSession.invalidateAndCancel()
    }

    // MARK: MQTT

    private static func trustedMQTTHost(_ candidate: String?) -> String {
        guard let candidate = candidate?.lowercased(),
              Arlo.trustedMQTTSuffixes.contains(where: { candidate.hasSuffix($0) })
        else { return Arlo.defaultMQTTHost }
        return candidate
    }

    private func runMQTT(host: String, topics: [String]) async throws {
        let socket = TLSSocket(host: host)
        mqttSocket = socket
        defer { socket.close(sending: MQTTPacket.disconnect) }
        try await socket.open()

        let digits = (0..<10).map { _ in String(Int.random(in: 0...9)) }.joined()
        let session = client.session
        try await socket.send(MQTTPacket.connect(
            clientId: "user_\(session.userId)_\(digits)",
            username: session.userId,
            password: session.token,
            keepAlive: 60
        ))

        let pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                try? await socket.send(MQTTPacket.pingReq)
            }
        }
        defer { pinger.cancel() }

        var buffer: [UInt8] = []
        while !Task.isCancelled {
            buffer += Array(try await socket.receive())

            for packet in MQTTPacket.drain(&buffer) {
                switch packet {
                case .connAck(let code):
                    // A refused connection is retried with backoff. If the token really is dead,
                    // the next API call gets a 401 and signs out properly.
                    guard code == 0 else { throw ArloError.http(status: Int(code)) }
                    let all = ["u/\(session.userId)/in/#"] + topics
                    try await socket.send(MQTTPacket.subscribe(topics: all, packetId: 1))
                case .subAck(let accepted):
                    guard accepted else { throw ArloError.server(message: "Arlo refused the event subscription.") }
                    isConnected = true
                case .publish(_, let payload, let qos, let packetId):
                    if qos == 1, let packetId {
                        try? await socket.send(MQTTPacket.pubAck(packetId: packetId))
                    }
                    deliver(payload)
                case .pingResp, .other:
                    break
                }
            }
        }
    }

    // MARK: Server-sent events

    private func runSSE() async throws {
        let request = try client.eventStreamRequest()
        let (bytes, response) = try await streamSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ArloError.decoding }
        if http.statusCode == 401 { throw ArloError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw ArloError.http(status: http.statusCode) }
        for try await line in bytes.lines {
            if Task.isCancelled { return }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8) else { continue }
            if let json = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject {
                if json.string("status") == "connected" { isConnected = true; continue }
                // Arlo closes the feed this way when the same account opens another one; reconnect.
                if json.string("action") == "logout" { throw URLError(.networkConnectionLost) }
            }
            deliver(data)
        }
    }

    // MARK: Dispatch

    private func deliver(_ data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else { return }
        if json.string("action") == "logout" { return }
        onEvent?(ArloEvent(raw: json))
    }
}
