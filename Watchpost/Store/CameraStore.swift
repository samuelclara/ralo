import Foundation
import Observation

/// Everything the screens show, kept in memory while the app is unlocked.
@MainActor
@Observable
final class CameraStore {
    enum ModeControl: Equatable {
        case location(ArloLocation)
        case baseStations
        case unavailable
    }

    let client: ArloClient
    let events: ArloEventStream
    let batteryHistory = BatteryHistory()
    @ObservationIgnored var onUnauthorized: (() -> Void)?

    private(set) var devices: [ArloDevice] = []
    private(set) var mode: SecurityMode?
    private(set) var modeControl: ModeControl = .unavailable
    private(set) var isChangingMode = false
    private(set) var todayClips: [ArloClip] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var motionAt: [String: Date] = [:]
    var errorMessage: String?

    @ObservationIgnored private var sessionInfo: SessionInfo?
    @ObservationIgnored private var modeRevision: Int?
    @ObservationIgnored private var capabilityCache: [String: CameraCapabilities] = [:]
    @ObservationIgnored private var listeners: [UUID: (ArloEvent) -> Void] = [:]
    @ObservationIgnored private var libraryRefresh: Task<Void, Never>?

    init(client: ArloClient) {
        self.client = client
        events = ArloEventStream(client: client)
        events.onEvent = { [weak self] event in self?.handle(event) }
        events.onConnected = { [weak self] in self?.requestCameraStates() }
        events.onUnauthorized = { [weak self] in self?.onUnauthorized?() }
    }

    var cameras: [ArloDevice] { devices.filter(\.isCamera) }
    var accountEmail: String { client.session.email }
    var supportsHomeMode: Bool {
        if case .location = modeControl { return true }
        return false
    }

    func camera(id: String) -> ArloDevice? { devices.first { $0.id == id } }

    func base(for camera: ArloDevice) -> ArloDevice {
        if let parentId = camera.parentId, let base = devices.first(where: { $0.id == parentId }) {
            return base
        }
        return camera
    }

    func hasRecentMotion(_ camera: ArloDevice) -> Bool {
        if let seen = motionAt[camera.id], seen.timeIntervalSinceNow > -120 { return true }
        return todayClips.contains { $0.deviceId == camera.id && $0.createdAt.timeIntervalSinceNow > -120 }
    }

    // MARK: Lifecycle

    /// Bumped by every start and stop, so a start that's still waiting on the network
    /// can tell that the app locked or went to the background in the meantime.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isInvalidated = false

    func start() async {
        guard !isInvalidated else { return }
        generation += 1
        let current = generation
        await refresh()
        guard current == generation, !isInvalidated, let sessionInfo, !devices.isEmpty else { return }
        events.start(devices: devices, sessionInfo: sessionInfo)
    }

    /// Pauses the live connection (going to the background). Listeners stay registered.
    func stop() {
        generation += 1
        events.stop()
        libraryRefresh?.cancel()
    }

    /// Ends this store for good: lock or sign-out. Frees every network session it owns.
    func invalidate() {
        isInvalidated = true
        stop()
        listeners.removeAll()
        events.invalidate()
        client.transport.invalidate()
    }

    func refresh() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            if sessionInfo == nil {
                sessionInfo = try await client.sessionInfo()
            }
            // The device list leaves out battery and signal for cameras on a base station;
            // keep what the base last reported until it reports again.
            let previous = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            devices = try await client.devices().map { device in
                guard let old = previous[device.id] else { return device }
                var device = device
                if device.batteryLevel == nil {
                    device.batteryLevel = old.batteryLevel
                    device.isCharging = old.isCharging
                }
                device.signalStrength = device.signalStrength ?? old.signalStrength
                device.connectionState = device.connectionState ?? old.connectionState
                return device
            }
            for device in devices { recordBattery(device) }
            if events.isConnected { requestCameraStates() }
            await loadMode()
            todayClips = try await client.clips(from: Date(), to: Date())
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    func clips(on day: Date) async -> [ArloClip] {
        if Calendar.current.isDateInToday(day) {
            let fresh = try? await client.clips(from: day, to: day)
            if let fresh { todayClips = fresh }
            return todayClips
        }
        do {
            return try await client.clips(from: day, to: day)
        } catch {
            report(error)
            return []
        }
    }

    // MARK: Modes

    private func loadMode() async {
        do {
            let locations = sessionInfo?.supportsMultiLocation == true ? try await client.locations() : []
            if let location = locations.first {
                modeControl = .location(location)
                let current = try await client.activeMode(location: location)
                mode = current.mode
                modeRevision = current.revision
            } else {
                let bases = devices.filter(\.isBaseStation)
                guard !bases.isEmpty else {
                    modeControl = .unavailable
                    return
                }
                modeControl = .baseStations
                let modes = try await client.baseStationModes()
                mode = bases.compactMap { modes[$0.uniqueId] }.first
            }
        } catch {
            if case ArloError.unauthorized = error { onUnauthorized?() }
        }
    }

    func setMode(_ newMode: SecurityMode) async {
        guard newMode != mode, !isChangingMode else { return }
        let previous = mode
        mode = newMode
        isChangingMode = true
        defer { isChangingMode = false }

        do {
            switch modeControl {
            case .location(let location):
                do {
                    modeRevision = try await client.setMode(newMode, location: location, revision: modeRevision) ?? modeRevision
                } catch {
                    guard case ArloError.server = error else { throw error }
                    // Usually a stale revision: someone changed the mode elsewhere. Re-read and retry once.
                    modeRevision = try await client.activeMode(location: location).revision
                    modeRevision = try await client.setMode(newMode, location: location, revision: modeRevision) ?? modeRevision
                }
            case .baseStations:
                for base in devices.filter(\.isBaseStation) {
                    try await client.setBaseStationMode(newMode, base: base)
                }
            case .unavailable:
                throw ArloError.unsupported("Security modes aren't available for this Arlo account.")
            }
        } catch {
            mode = previous
            report(error)
        }
    }

    // MARK: Cameras

    func batteryForecast(for camera: ArloDevice) -> BatteryForecast? {
        guard camera.runsOnBattery else { return nil }
        return batteryHistory.forecast(cameraId: camera.id)
    }

    private func recordBattery(_ device: ArloDevice) {
        guard device.runsOnBattery, let level = device.batteryLevel else { return }
        batteryHistory.record(cameraId: device.id, level: level, isCharging: device.isCharging)
    }

    /// Asks every base station for its cameras' battery and signal; answers come as events.
    func requestCameraStates() {
        let client = client
        let bases = devices.filter(\.isBaseStation)
        Task {
            for base in bases { await client.requestCameraStates(base: base) }
        }
    }

    func capabilities(for camera: ArloDevice) async -> CameraCapabilities {
        if let cached = capabilityCache[camera.id] { return cached }
        let caps = await client.capabilities(for: camera)
        capabilityCache[camera.id] = caps
        return caps
    }

    // MARK: Events

    func addListener(_ listener: @escaping (ArloEvent) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    private func handle(_ event: ArloEvent) {
        for listener in listeners.values { listener(event) }

        let properties = event.properties
        let resource = event.resource

        if resource.hasPrefix("cameras/"), let id = event.deviceId,
           let index = devices.firstIndex(where: { $0.id == id }) {
            if let level = properties.int("batteryLevel") { devices[index].batteryLevel = level }
            if let charging = ArloDevice.isCharging(properties) { devices[index].isCharging = charging }
            if properties["batteryLevel"] != nil || properties["chargingState"] != nil { recordBattery(devices[index]) }
            if let signal = properties.int("signalStrength") { devices[index].signalStrength = signal }
            if let state = properties.string("connectionState") { devices[index].connectionState = state }
            if let url = properties.url("presignedLastImageUrl") { devices[index].lastImageURL = url }
            if properties.bool("motionDetected") == true { motionAt[id] = Date() }
            if properties.string("activityState") == "idle" { scheduleLibraryRefresh() }
        }

        // A base station's answer to `requestCameraStates`: one entry per camera.
        if resource == "cameras", let states = event.raw["properties"] as? [JSONObject] {
            for state in states {
                guard let id = state.string("serialNumber"),
                      let index = devices.firstIndex(where: { $0.id == id }) else { continue }
                if let level = state.int("batteryLevel") { devices[index].batteryLevel = level }
                if let charging = ArloDevice.isCharging(state) { devices[index].isCharging = charging }
                if let signal = state.int("signalStrength") { devices[index].signalStrength = signal }
                if let connection = state.string("connectionState") { devices[index].connectionState = connection }
                recordBattery(devices[index])
            }
        }

        if resource.hasPrefix("mediaUploadNotification") {
            let deviceId = properties.string("deviceId") ?? event.raw.string("deviceId")
            if let deviceId, let index = devices.firstIndex(where: { $0.id == deviceId }),
               let url = properties.url("presignedLastImageUrl") ?? event.raw.url("presignedLastImageUrl") {
                devices[index].lastImageURL = url
            }
            scheduleLibraryRefresh()
        }

        if resource == "automation/activeMode", !isChangingMode {
            let inner = properties.object("properties") ?? properties
            if let raw = inner.string("mode"), let newMode = SecurityMode(v3Id: raw) { mode = newMode }
            if let revision = properties.int("revision") { modeRevision = revision }
        }
    }

    private func scheduleLibraryRefresh() {
        libraryRefresh?.cancel()
        libraryRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            let fresh = try? await self.client.clips(from: Date(), to: Date())
            if let fresh { self.todayClips = fresh }
        }
    }

    // MARK: Errors

    func report(_ error: Error) {
        if case ArloError.unauthorized = error {
            onUnauthorized?()
            return
        }
        if error is CancellationError { return }
        errorMessage = error.localizedDescription
    }
}
