import Foundation

/// Just enough MQTT 3.1.1 to receive Arlo's events over a WebSocket.
enum MQTTPacket {
    case connAck(returnCode: UInt8)
    case subAck(accepted: Bool)
    case publish(topic: String, payload: Data, qos: UInt8, packetId: UInt16?)
    case pingResp
    case other(type: UInt8)

    // MARK: Encoding

    static func connect(clientId: String, username: String, password: String, keepAlive: UInt16) -> Data {
        var variable: [UInt8] = []
        variable += encodeString("MQTT")
        variable.append(4)            // protocol level 3.1.1
        variable.append(0b1100_0010)  // username, password, clean session
        variable += [UInt8(keepAlive >> 8), UInt8(keepAlive & 0xFF)]

        var payload: [UInt8] = []
        payload += encodeString(clientId)
        payload += encodeString(username)
        payload += encodeString(password)

        return frame(type: 0x10, body: variable + payload)
    }

    static func subscribe(topics: [String], packetId: UInt16) -> Data {
        var body: [UInt8] = [UInt8(packetId >> 8), UInt8(packetId & 0xFF)]
        for topic in topics {
            body += encodeString(topic)
            body.append(0) // QoS 0
        }
        return frame(type: 0x82, body: body)
    }

    static func pubAck(packetId: UInt16) -> Data {
        Data([0x40, 0x02, UInt8(packetId >> 8), UInt8(packetId & 0xFF)])
    }

    static let pingReq = Data([0xC0, 0x00])
    static let disconnect = Data([0xE0, 0x00])

    private static func encodeString(_ string: String) -> [UInt8] {
        let bytes = Array(string.utf8)
        let length = min(bytes.count, 0xFFFF)
        return [UInt8(length >> 8), UInt8(length & 0xFF)] + bytes.prefix(length)
    }

    private static func frame(type: UInt8, body: [UInt8]) -> Data {
        var bytes: [UInt8] = [type]
        var remaining = body.count
        repeat {
            var digit = UInt8(remaining % 128)
            remaining /= 128
            if remaining > 0 { digit |= 0x80 }
            bytes.append(digit)
        } while remaining > 0
        bytes += body
        return Data(bytes)
    }

    // MARK: Decoding

    /// Pulls complete packets off the front of `buffer`, leaving any partial packet behind.
    static func drain(_ buffer: inout [UInt8]) -> [MQTTPacket] {
        var packets: [MQTTPacket] = []
        while buffer.count >= 2 {
            var multiplier = 1
            var remaining = 0
            var index = 1
            var complete = false
            while index < buffer.count && index <= 4 {
                let byte = Int(buffer[index])
                remaining += (byte & 0x7F) * multiplier
                multiplier *= 128
                index += 1
                if byte & 0x80 == 0 { complete = true; break }
            }
            guard complete else {
                if index > 4 { buffer.removeAll() } // malformed length, drop everything
                return packets
            }
            let total = index + remaining
            guard buffer.count >= total else { return packets }

            let header = buffer[0]
            let body = Array(buffer[index..<total])
            buffer.removeFirst(total)
            packets.append(parse(header: header, body: body))
        }
        return packets
    }

    private static func parse(header: UInt8, body: [UInt8]) -> MQTTPacket {
        let type = header >> 4
        switch type {
        case 2:
            return .connAck(returnCode: body.count >= 2 ? body[1] : 0xFF)
        case 3:
            guard body.count >= 2 else { return .other(type: type) }
            let qos = (header >> 1) & 0x03
            let topicLength = Int(body[0]) << 8 | Int(body[1])
            var cursor = 2 + topicLength
            guard body.count >= cursor else { return .other(type: type) }
            let topic = String(decoding: body[2..<cursor], as: UTF8.self)
            var packetId: UInt16?
            if qos > 0 {
                guard body.count >= cursor + 2 else { return .other(type: type) }
                packetId = UInt16(body[cursor]) << 8 | UInt16(body[cursor + 1])
                cursor += 2
            }
            return .publish(topic: topic, payload: Data(body[cursor...]), qos: qos, packetId: packetId)
        case 9:
            // After the packet id, one return code per topic; 0x80 means refused.
            // Accept as long as at least one topic went through.
            let codes = body.dropFirst(2)
            return .subAck(accepted: codes.contains { $0 != 0x80 })
        case 13:
            return .pingResp
        default:
            return .other(type: type)
        }
    }
}
