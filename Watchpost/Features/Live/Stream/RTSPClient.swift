import Foundation

/// Just enough RTSP (RFC 2326) to pull Arlo's live stream: DESCRIBE, SETUP with RTP
/// interleaved on the same TLS connection, PLAY, and keep-alives until it's torn down.
///
/// Arlo hands out its stream servers as bare IP addresses, so the TLS certificate is
/// checked against Arlo's streaming domain rather than the address.
final class RTSPClient: @unchecked Sendable {
    struct Track {
        let control: String
        let payloadType: UInt8
        let codec: String
        let clockRate: Int
        let channels: Int
        let parameters: [String: String]
        /// The interleaved channel its RTP arrives on.
        var channel: UInt8 = 0
    }

    struct Packet {
        let channel: UInt8
        let rtp: RTPPacket
    }

    private let url: URL
    private let socket: TLSSocket
    private var buffer = ByteQueue()
    private var cseq = 0
    private var session: String?
    private var lastKeepAlive = Date()

    init(url: URL) {
        self.url = url
        socket = TLSSocket(
            host: url.host ?? "",
            port: UInt16(url.port ?? 443),
            certificateName: Arlo.streamCertificateName
        )
    }

    /// Connects and asks for every track. Packets follow through `nextPacket()`.
    func start() async throws -> [Track] {
        try await socket.open()

        let describe = try await request("DESCRIBE", url.absoluteString, headers: ["Accept": "application/sdp"])
        let base = describe.headers["content-base"] ?? Self.stripQuery(url)
        var tracks = SDP.tracks(in: String(decoding: describe.body, as: UTF8.self), base: base)
        guard !tracks.isEmpty else { throw ArloError.unsupported("The camera's stream had no video.") }

        for index in tracks.indices {
            let channel = UInt8(index * 2)
            tracks[index].channel = channel
            let reply = try await request("SETUP", tracks[index].control, headers: [
                "Transport": "RTP/AVP/TCP;unicast;interleaved=\(channel)-\(channel + 1)",
            ])
            if session == nil, let value = reply.headers["session"] {
                session = value.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }
            }
        }

        _ = try await request("PLAY", base, headers: ["Range": "npt=0.000-"])
        lastKeepAlive = Date()
        return tracks
    }

    /// The next RTP packet. RTCP and the replies to keep-alives are skipped.
    func nextPacket() async throws -> Packet {
        while true {
            if Date().timeIntervalSince(lastKeepAlive) > 25 {
                lastKeepAlive = Date()
                try await send("OPTIONS", base: Self.stripQuery(url), headers: [:])
            }

            guard let first = buffer.peek(0) else {
                try await fill()
                continue
            }

            if first == 0x24 { // '$': an interleaved binary frame
                guard buffer.count >= 4 else { try await fill(); continue }
                let channel = buffer.peek(1)!
                let length = Int(buffer.peek(2)!) << 8 | Int(buffer.peek(3)!)
                guard buffer.count >= 4 + length else { try await fill(); continue }
                buffer.drop(4)
                let payload = buffer.take(length)
                // Odd channels carry RTCP.
                if channel % 2 == 0, let rtp = RTPPacket(payload) {
                    return Packet(channel: channel, rtp: rtp)
                }
            } else if first == UInt8(ascii: "R") {
                // An RTSP reply in the middle of the media, e.g. to a keep-alive.
                guard let reply = try parseReply() else { try await fill(); continue }
                _ = reply
            } else {
                buffer.drop(1) // Out of step; find the next frame.
            }
        }
    }

    /// Tells the server goodbye and closes the connection.
    func stop() {
        let base = Self.stripQuery(url)
        Task { [self] in
            try? await send("TEARDOWN", base: base, headers: [:])
            socket.close()
        }
    }

    // MARK: Requests

    private struct Reply {
        let status: Int
        let headers: [String: String]
        let body: [UInt8]
    }

    private func request(_ method: String, _ target: String, headers: [String: String]) async throws -> Reply {
        try await send(method, base: target, headers: headers)
        while true {
            if let reply = try parseReply() {
                guard reply.status == 200 else {
                    throw ArloError.server(message: "Arlo's stream server refused the connection (\(reply.status)).")
                }
                return reply
            }
            try await fill()
        }
    }

    private func send(_ method: String, base target: String, headers: [String: String]) async throws {
        cseq += 1
        var lines = ["\(method) \(target) RTSP/1.0", "CSeq: \(cseq)", "User-Agent: Ralo"]
        if let session { lines.append("Session: \(session)") }
        for (field, value) in headers { lines.append("\(field): \(value)") }
        let text = lines.joined(separator: "\r\n") + "\r\n\r\n"
        try await socket.send(Data(text.utf8))
    }

    /// Takes one complete RTSP reply off the front of the buffer, if it's all there.
    private func parseReply() throws -> Reply? {
        guard let end = buffer.firstRange(of: [13, 10, 13, 10]) else { return nil }
        let head = String(decoding: buffer.prefix(end), as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        guard statusLine.hasPrefix("RTSP/") else { throw ArloError.decoding }
        let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = line[..<colon].lowercased()
            headers[field] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.count >= end + 4 + length else { return nil }
        buffer.drop(end + 4)
        return Reply(status: status, headers: headers, body: buffer.take(length))
    }

    private func fill() async throws {
        buffer.append(try await socket.receive())
    }

    private static func stripQuery(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        return components?.string ?? url.absoluteString
    }
}

/// One RTP packet (RFC 3550) with its header parsed.
struct RTPPacket {
    let payloadType: UInt8
    let marker: Bool
    let sequence: UInt16
    let timestamp: UInt32
    let payload: ArraySlice<UInt8>

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { return nil }
        let csrcCount = Int(bytes[0] & 0x0F)
        let hasExtension = bytes[0] & 0x10 != 0
        let hasPadding = bytes[0] & 0x20 != 0
        marker = bytes[1] & 0x80 != 0
        payloadType = bytes[1] & 0x7F
        sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        timestamp = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])

        var start = 12 + csrcCount * 4
        if hasExtension {
            guard bytes.count >= start + 4 else { return nil }
            let words = Int(bytes[start + 2]) << 8 | Int(bytes[start + 3])
            start += 4 + words * 4
        }
        var end = bytes.count
        if hasPadding, let padding = bytes.last { end -= Int(padding) }
        guard start <= end else { return nil }
        payload = bytes[start..<end]
    }
}

/// The parts of an SDP description (RFC 4566) needed to set up each track.
enum SDP {
    static func tracks(in text: String, base: String) -> [RTSPClient.Track] {
        var tracks: [RTSPClient.Track] = []
        var current: (pt: UInt8, control: String?, rtpmap: String?, fmtp: String?)?

        func finish() {
            guard let section = current, let control = section.control, let rtpmap = section.rtpmap else { return }
            // "H264/90000" or "MPEG4-GENERIC/16000/1"
            let parts = rtpmap.split(separator: "/").map(String.init)
            guard parts.count >= 2, let clock = Int(parts[1]) else { return }
            tracks.append(RTSPClient.Track(
                control: resolve(control, base: base),
                payloadType: section.pt,
                codec: parts[0].uppercased(),
                clockRate: clock,
                channels: parts.count > 2 ? Int(parts[2]) ?? 1 : 1,
                parameters: parameters(section.fmtp ?? "")
            ))
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                finish()
                let fields = line.split(separator: " ")
                current = (pt: fields.count > 3 ? UInt8(fields[3]) ?? 0 : 0, control: nil, rtpmap: nil, fmtp: nil)
            } else if current != nil {
                if line.hasPrefix("a=control:") {
                    current?.control = String(line.dropFirst("a=control:".count))
                } else if line.hasPrefix("a=rtpmap:") {
                    current?.rtpmap = line.split(separator: " ", maxSplits: 1).last.map(String.init)
                } else if line.hasPrefix("a=fmtp:") {
                    current?.fmtp = line.split(separator: " ", maxSplits: 1).last.map(String.init)
                }
            }
        }
        finish()
        return tracks
    }

    /// "key=value; key=value" — Arlo also separates some pairs with spaces only.
    private static func parameters(_ fmtp: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in fmtp.split(whereSeparator: { $0 == ";" || $0 == " " }) {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            result[pair[..<equals].lowercased()] = String(pair[pair.index(after: equals)...])
        }
        return result
    }

    private static func resolve(_ control: String, base: String) -> String {
        if control.lowercased().hasPrefix("rtsp") { return control }
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }
}

/// A byte FIFO that doesn't shift memory on every read.
struct ByteQueue {
    private var storage: [UInt8] = []
    private var head = 0

    var count: Int { storage.count - head }

    func peek(_ offset: Int) -> UInt8? {
        head + offset < storage.count ? storage[head + offset] : nil
    }

    mutating func append(_ data: Data) {
        if head > 256 * 1024 {
            storage.removeFirst(head)
            head = 0
        }
        storage.append(contentsOf: data)
    }

    mutating func drop(_ n: Int) {
        head = min(head + n, storage.count)
    }

    mutating func take(_ n: Int) -> [UInt8] {
        let slice = Array(storage[head..<head + n])
        head += n
        return slice
    }

    func prefix(_ n: Int) -> ArraySlice<UInt8> {
        storage[head..<head + n]
    }

    func firstRange(of pattern: [UInt8]) -> Int? {
        guard count >= pattern.count else { return nil }
        var i = head
        while i <= storage.count - pattern.count {
            if storage[i] == pattern[0], Array(storage[i..<i + pattern.count]) == pattern { return i - head }
            i += 1
        }
        return nil
    }
}
