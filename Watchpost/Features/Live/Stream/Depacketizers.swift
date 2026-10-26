import CoreMedia
import Foundation

/// Rebuilds H.264 frames from RTP (RFC 6184): single NAL units, STAP-A and FU-A.
/// Frames come out in AVCC form (4-byte lengths), ready for a CMSampleBuffer.
struct H264Depacketizer {
    struct Frame {
        let data: [UInt8]
        let isKeyframe: Bool
        let timestamp: UInt32
        let format: CMVideoFormatDescription
    }

    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var format: CMVideoFormatDescription?
    private var nalUnits: [[UInt8]] = []
    private var fragment: [UInt8]?
    private var timestamp: UInt32?

    init(parameters: [String: String]) {
        // sprop-parameter-sets=<base64 SPS>,<base64 PPS>
        for set in (parameters["sprop-parameter-sets"] ?? "").split(separator: ",") {
            guard let data = Data(base64Encoded: String(set)) else { continue }
            remember(Array(data))
        }
    }

    /// Feeds one packet; returns the frames it completed.
    mutating func push(_ packet: RTPPacket) -> [Frame] {
        var frames: [Frame] = []
        if let timestamp, timestamp != packet.timestamp, let frame = finish() {
            frames.append(frame)
        }
        timestamp = packet.timestamp

        let payload = packet.payload
        guard let first = payload.first else { return frames }
        switch first & 0x1F {
        case 1...23:
            nalUnits.append(Array(payload))
        case 24: // STAP-A: several small units in one packet
            var i = payload.startIndex + 1
            while i + 2 <= payload.endIndex {
                let size = Int(payload[i]) << 8 | Int(payload[i + 1])
                i += 2
                guard size > 0, i + size <= payload.endIndex else { break }
                nalUnits.append(Array(payload[i..<i + size]))
                i += size
            }
        case 28: // FU-A: one unit split across packets
            guard payload.count >= 2 else { break }
            let header = payload[payload.startIndex + 1]
            let body = payload.dropFirst(2)
            if header & 0x80 != 0 {
                fragment = [(first & 0xE0) | (header & 0x1F)] + body
            } else if fragment != nil {
                fragment! += body
            }
            if header & 0x40 != 0, let unit = fragment {
                nalUnits.append(unit)
                fragment = nil
            }
        default:
            break
        }

        if packet.marker, let frame = finish() {
            frames.append(frame)
        }
        return frames
    }

    private mutating func finish() -> Frame? {
        defer {
            nalUnits = []
            fragment = nil
        }
        guard let timestamp else { return nil }

        var data: [UInt8] = []
        var isKeyframe = false
        for unit in nalUnits {
            guard let type = unit.first.map({ $0 & 0x1F }) else { continue }
            if type == 7 || type == 8 {
                remember(unit)
                continue
            }
            if type == 5 { isKeyframe = true }
            let length = UInt32(unit.count)
            data += [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
            data += unit
        }
        guard !data.isEmpty, let format else { return nil }
        return Frame(data: data, isKeyframe: isKeyframe, timestamp: timestamp, format: format)
    }

    /// Keeps the latest SPS and PPS and rebuilds the format when either changes.
    private mutating func remember(_ unit: [UInt8]) {
        switch unit.first.map({ $0 & 0x1F }) {
        case 7 where unit != sps: sps = unit
        case 8 where unit != pps: pps = unit
        default: return
        }
        guard let sps, let pps else { return }
        var description: CMVideoFormatDescription?
        sps.withUnsafeBufferPointer { spsBytes in
            pps.withUnsafeBufferPointer { ppsBytes in
                let pointers = [spsBytes.baseAddress!, ppsBytes.baseAddress!]
                let sizes = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        if let description { format = description }
    }
}

/// Splits AAC from RTP in the "AAC-hbr" mode (RFC 3640): each packet starts with a list
/// of access-unit headers, then the access units, each 1024 samples long.
struct AACDepacketizer {
    struct Frame {
        let data: [UInt8]
        let timestamp: UInt32
    }

    let format: CMAudioFormatDescription?
    private let sizeLength: Int
    private let indexLength: Int
    private let indexDeltaLength: Int

    init(parameters: [String: String], sampleRate: Int, channels: Int) {
        sizeLength = Int(parameters["sizelength"] ?? "13") ?? 13
        indexLength = Int(parameters["indexlength"] ?? "3") ?? 3
        indexDeltaLength = Int(parameters["indexdeltalength"] ?? "3") ?? 3

        // The AudioSpecificConfig, as hex. The decoder takes it as the magic cookie.
        let hex = parameters["config"] ?? ""
        var config: [UInt8] = []
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), index < hex.endIndex {
            if let byte = UInt8(hex[index..<next], radix: 16) { config.append(byte) }
            index = next
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        _ = config.withUnsafeBytes { cookie in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: cookie.count,
                magicCookie: cookie.baseAddress,
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        format = config.isEmpty ? nil : description
    }

    func frames(in packet: RTPPacket) -> [Frame] {
        let payload = Array(packet.payload)
        guard payload.count >= 2 else { return [] }
        let headerBits = Int(payload[0]) << 8 | Int(payload[1])
        let headerBytes = (headerBits + 7) / 8
        guard payload.count >= 2 + headerBytes else { return [] }

        var reader = BitReader(bytes: Array(payload[2..<2 + headerBytes]))
        var sizes: [Int] = []
        var bitsRead = 0
        while bitsRead + sizeLength <= headerBits {
            let size = reader.read(sizeLength)
            let indexBits = sizes.isEmpty ? indexLength : indexDeltaLength
            _ = reader.read(indexBits)
            bitsRead += sizeLength + indexBits
            sizes.append(size)
        }

        var frames: [Frame] = []
        var offset = 2 + headerBytes
        for (i, size) in sizes.enumerated() {
            guard offset + size <= payload.count else { break }
            frames.append(Frame(
                data: Array(payload[offset..<offset + size]),
                timestamp: packet.timestamp &+ UInt32(i * 1024)
            ))
            offset += size
        }
        return frames
    }
}

private struct BitReader {
    let bytes: [UInt8]
    private var position = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            let byte = position / 8
            let bit = byte < bytes.count ? (bytes[byte] >> (7 - UInt8(position % 8))) & 1 : 0
            value = value << 1 | Int(bit)
            position += 1
        }
        return value
    }
}
