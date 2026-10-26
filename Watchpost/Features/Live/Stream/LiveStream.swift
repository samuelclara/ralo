import AVFoundation
import CoreMedia
import UIKit

/// Plays one Arlo RTSPS stream: H.264 into a display layer, AAC into an audio renderer,
/// both decoded by the system and kept in step by one synchronizer.
final class LiveStream: @unchecked Sendable {
    enum End: Error {
        case noVideo
        case stopped
    }

    let displayLayer = AVSampleBufferDisplayLayer()

    /// Called on the main actor when the first frame is on screen.
    @MainActor var onFirstFrame: (() -> Void)?
    /// Called on the main actor when the stream ends on its own.
    @MainActor var onEnd: ((Error) -> Void)?
    /// The views that have shown the layer, newest last. See `LiveVideoView`.
    @MainActor var hostViews: [WeakHostView] = []

    private let url: URL
    private let audio = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var client: RTSPClient?
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    private var video = H264Depacketizer(parameters: [:])
    private var aac: AACDepacketizer?
    private var videoClock: StreamClock?
    private var audioClock: StreamClock?
    private var needsKeyframe = true
    private var hasShownFrame = false

    /// How far behind live playback runs, to ride out network jitter.
    private static let latency = 0.35

    init(url: URL) {
        self.url = url
        displayLayer.videoGravity = .resizeAspectFill
    }

    func start() {
        let client = RTSPClient(url: url)
        self.client = client
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await self?.run(client)
            } catch {
                guard let self, !Task.isCancelled else { return }
                await self.end(error)
            }
        }
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, !self.hasShownFrame else { return }
            await self.end(End.noVideo)
        }
    }

    func stop() {
        watchdog?.cancel()
        task?.cancel()
        task = nil
        client?.stop()
        client = nil
        synchronizer.setRate(0, time: .zero)
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
        audio.flush()
    }

    /// The frame on screen now, for snapshots.
    func currentFrame() -> CVPixelBuffer? {
        displayLayer.sampleBufferRenderer.displayedPixelBuffer()
    }

    // MARK: Playback

    private func run(_ client: RTSPClient) async throws {
        let tracks = try await client.start()
        guard let videoTrack = tracks.first(where: { $0.codec == "H264" }) else {
            throw ArloError.unsupported("The camera sent video in a format Ralo can't play.")
        }
        video = H264Depacketizer(parameters: videoTrack.parameters)
        videoClock = StreamClock(rate: Double(videoTrack.clockRate))

        synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        if let audioTrack = tracks.first(where: { $0.codec == "MPEG4-GENERIC" }) {
            let depacketizer = AACDepacketizer(
                parameters: audioTrack.parameters,
                sampleRate: audioTrack.clockRate,
                channels: audioTrack.channels
            )
            if depacketizer.format != nil {
                aac = depacketizer
                audioClock = StreamClock(rate: Double(audioTrack.clockRate))
                synchronizer.addRenderer(audio)
            }
        }
        synchronizer.setRate(1, time: .zero)

        let audioChannel = tracks.first { $0.codec == "MPEG4-GENERIC" }?.channel
        while !Task.isCancelled {
            let packet = try await client.nextPacket()
            if packet.channel == videoTrack.channel {
                for frame in video.push(packet.rtp) { enqueue(frame) }
            } else if packet.channel == audioChannel, let aac {
                for frame in aac.frames(in: packet.rtp) { enqueue(frame, format: aac.format!) }
            }
        }
    }

    private func enqueue(_ frame: H264Depacketizer.Frame) {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            // E.g. back from the background: the decoder needs a clean start on a keyframe.
            renderer.flush()
            needsKeyframe = true
        }
        if needsKeyframe {
            guard frame.isKeyframe else { return }
            needsKeyframe = false
        }
        guard let time = videoClock?.time(for: frame.timestamp, now: now, latency: Self.latency),
              let sample = Self.sampleBuffer(frame.data, format: frame.format, time: time, isKeyframe: frame.isKeyframe)
        else { return }
        renderer.enqueue(sample)

        if !hasShownFrame {
            hasShownFrame = true
            watchdog?.cancel()
            Task { @MainActor [weak self] in self?.onFirstFrame?() }
        }
    }

    private func enqueue(_ frame: AACDepacketizer.Frame, format: CMAudioFormatDescription) {
        guard hasShownFrame,
              let time = audioClock?.time(for: frame.timestamp, now: now, latency: Self.latency),
              let block = Self.blockBuffer(frame.data)
        else { return }
        var description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.data.count))
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            presentationTimeStamp: time,
            packetDescriptions: &description,
            sampleBufferOut: &sample
        )
        if let sample { audio.enqueue(sample) }
    }

    private var now: Double { synchronizer.currentTime().seconds }

    private func end(_ error: Error) async {
        stop()
        await MainActor.run { onEnd?(error) }
    }

    // MARK: Sample buffers

    private static func blockBuffer(_ bytes: [UInt8]) -> CMBlockBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let status = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        return status == noErr ? block : nil
    }

    private static func sampleBuffer(_ bytes: [UInt8], format: CMVideoFormatDescription, time: CMTime, isKeyframe: Bool) -> CMSampleBuffer? {
        guard let block = blockBuffer(bytes) else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        if let sample, !isKeyframe,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_NotSync] = true
        }
        return sample
    }
}

/// Maps one track's RTP timestamps onto the synchronizer's clock.
///
/// The first packet plays `latency` seconds after it arrives; later ones keep the camera's
/// spacing. If the network stalls long enough that packets would already be late, the track
/// shifts later instead of dropping them.
private struct StreamClock {
    let rate: Double
    private var base = 0.0
    private var first: Int64?
    private var extended: Int64 = 0
    private var last: UInt32?

    init(rate: Double) { self.rate = rate }

    mutating func time(for timestamp: UInt32, now: Double, latency: Double) -> CMTime {
        // RTP timestamps are 32 bits and wrap around.
        if let last {
            extended += Int64(Int32(bitPattern: timestamp &- last))
        } else {
            extended = Int64(timestamp)
        }
        last = timestamp
        if first == nil {
            first = extended
            base = now + latency
        }

        var seconds = base + Double(extended - first!) / rate
        if seconds < now || seconds > now + 5 {
            base += now + latency - seconds
            seconds = now + latency
        }
        return CMTime(seconds: seconds, preferredTimescale: 90_000)
    }
}
