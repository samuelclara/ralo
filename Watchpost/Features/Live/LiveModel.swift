import AVFoundation
import CoreImage
import Observation
import Photos
import UIKit

@MainActor
@Observable
final class LiveModel {
    enum State: Equatable {
        case idle
        case connecting
        case playing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var stream: LiveStream?
    private(set) var startedAt: Date?
    private(set) var isRecording = false
    private(set) var isSirenOn = false
    private(set) var isLightOn = false
    private(set) var busyControl: String?
    var toast: String?

    @ObservationIgnored private var camera: ArloDevice?
    @ObservationIgnored private weak var store: CameraStore?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    var isPlaying: Bool { state == .playing }

    // MARK: Stream

    func start(camera: ArloDevice, store: CameraStore) async {
        guard state == .idle || isFailed else { return }
        self.camera = camera
        self.store = store
        state = .connecting
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        do {
            let url = try await store.client.startStream(camera: camera)
            // Left the screen while Arlo was starting the stream: close it again.
            guard state == .connecting else {
                let base = store.base(for: camera)
                await store.client.stopStream(camera: camera, base: base)
                return
            }
            let stream = LiveStream(url: url)
            stream.onFirstFrame = { [weak self] in self?.firstFrameShown() }
            stream.onEnd = { [weak self] error in self?.streamEnded(error) }
            self.stream = stream
            stream.start()
        } catch {
            guard state == .connecting else { return }
            if case ArloError.unauthorized = error { store.report(error) }
            state = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't start the live view.")
        }
    }

    func retry() async {
        guard let camera, let store else { return }
        teardownStream()
        state = .idle
        await start(camera: camera, store: store)
    }

    func stop() {
        guard let camera, let store else { return }
        let wasRecording = isRecording
        teardownStream()
        state = .idle
        isRecording = false
        let client = store.client
        let base = store.base(for: camera)
        Task {
            if wasRecording { try? await client.stopRecording(camera: camera) }
            await client.stopStream(camera: camera, base: base)
        }
    }

    private func teardownStream() {
        stream?.stop()
        stream = nil
        startedAt = nil
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func firstFrameShown() {
        guard state == .connecting else { return }
        state = .playing
        startedAt = Date()
    }

    private func streamEnded(_ error: Error) {
        teardownStream()
        switch error {
        case LiveStream.End.noVideo:
            state = .failed("The camera didn't send any video. Try again.")
        case let error as ArloError:
            state = .failed(error.errorDescription ?? "The live stream stopped. Try again.")
        default:
            state = .failed("The live stream stopped. Try again.")
        }
    }

    // MARK: Controls

    func toggleRecording() async {
        guard let camera, let store else { return }
        await run("record") {
            if self.isRecording {
                try await store.client.stopRecording(camera: camera)
                self.isRecording = false
                self.show("Recording saved to Clips")
            } else {
                try await store.client.startRecording(camera: camera)
                self.isRecording = true
            }
        }
    }

    func toggleSiren() async {
        guard let camera, let store else { return }
        let base = store.base(for: camera)
        await run("siren") {
            try await store.client.setSiren(!self.isSirenOn, camera: camera, base: base)
            self.isSirenOn.toggle()
        }
    }

    func toggleLight() async {
        guard let camera, let store else { return }
        let base = store.base(for: camera)
        await run("light") {
            try await store.client.setLight(!self.isLightOn, camera: camera, base: base)
            self.isLightOn.toggle()
        }
    }

    /// Saves the current frame to Photos. The frame never leaves the device another way.
    func snapshot() async {
        guard let buffer = stream?.currentFrame() else {
            show("No frame to save yet")
            return
        }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else {
            show("Couldn't capture the frame")
            return
        }
        let photo = UIImage(cgImage: cgImage)

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            show("Allow adding photos in Settings")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: photo)
            }
            show("Snapshot saved to Photos")
        } catch {
            show("Couldn't save the snapshot")
        }
    }

    private func run(_ control: String, _ action: @escaping () async throws -> Void) async {
        guard busyControl == nil else { return }
        busyControl = control
        defer { busyControl = nil }
        do {
            try await action()
        } catch {
            if case ArloError.unauthorized = error { store?.report(error) }
            show((error as? LocalizedError)?.errorDescription ?? "That didn't work. Try again.")
        }
    }

    private func show(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
