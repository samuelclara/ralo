import AVFoundation
import SwiftUI

struct LiveView: View {
    let store: CameraStore
    let cameraId: String

    @State private var live = LiveModel()
    @State private var talk = TalkSession()
    @State private var capabilities = CameraCapabilities.unknown
    @State private var confirmSiren = false
    @State private var showFullScreen = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(PreferenceKey.groupByVisit) private var groupByVisit = true

    private var camera: ArloDevice? { store.camera(id: cameraId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let camera {
                    Text(statusLine(camera))
                        .font(.ag(13))
                        .foregroundStyle(AG.ink800)
                    videoCard(camera)
                    if let forecast = store.batteryForecast(for: camera) {
                        BatteryCard(forecast: forecast)
                    }
                    todayCard(camera)
                } else {
                    ContentUnavailableView("Camera not found", systemImage: "video.slash")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
        }
        .background(LightField())
        .navigationTitle(camera?.name ?? "Camera")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showFullScreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .disabled(live.stream == nil)
                .accessibilityLabel("Full screen")
            }
        }
        .overlay(alignment: .top) {
            if let toast = live.toast {
                Toast(text: toast).padding(.top, 8)
            }
        }
        .animation(.snappy, value: live.toast)
        .task {
            guard let camera else { return }
            capabilities = await store.capabilities(for: camera)
            await live.start(camera: camera, store: store)
        }
        .onDisappear {
            // Opening full screen also "disappears" this view; keep the stream for it.
            guard !showFullScreen else { return }
            talk.stop()
            live.stop()
        }
        .confirmationDialog("Sound the siren?", isPresented: $confirmSiren, titleVisibility: .visible) {
            Button("Sound siren", role: .destructive) {
                Task { await live.toggleSiren() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It plays at full volume for up to 5 minutes, or until you stop it here.")
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenPlayer(stream: live.stream)
        }
    }

    private func statusLine(_ camera: ArloDevice) -> String {
        var parts: [String] = []
        if let battery = camera.batteryLevel, camera.runsOnBattery {
            parts.append(camera.isCharging ? "Battery \(battery)%, charging" : "Battery \(battery)%")
        }
        if let signal = camera.signalStrength { parts.append(signal >= 3 ? "Wi-Fi strong" : "Wi-Fi weak") }
        if parts.isEmpty { parts.append(camera.connectionState?.lowercased() == "available" ? "Online" : "Live view") }
        return parts.joined(separator: " · ")
    }

    // MARK: Video

    private func videoCard(_ camera: ArloDevice) -> some View {
        Color.clear
            .aspectRatio(sizeClass == .regular ? 16 / 9 : 4 / 5, contentMode: .fit)
            .overlay {
                ZStack {
                    SecureImage(url: camera.lastImageURL)
                    if let stream = live.stream {
                        LiveVideoView(stream: stream)
                            .opacity(live.isPlaying ? 1 : 0)
                            .animation(.easeOut(duration: 0.3), value: live.isPlaying)
                    }
                    stateOverlay
                }
            }
            .overlay(alignment: .top) { topBadges }
            .overlay(alignment: .center) {
                if talk.state == .live {
                    Label("Talking · tap Talk to stop", systemImage: "mic.fill")
                        .font(.ag(13, .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.white, in: Capsule())
                        .foregroundStyle(AG.ink950)
                }
            }
            .overlay(alignment: .bottom) { controls(camera) }
            .clipShape(RoundedRectangle(cornerRadius: AG.cardRadius, style: .continuous))
            .shadow(color: AG.ink950.opacity(0.08), radius: 20, y: 12)
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch live.state {
        case .connecting, .idle:
            Label("Connecting", systemImage: "dot.radiowaves.left.and.right")
                .symbolEffect(.variableColor.iterative)
                .font(.ag(14, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular.tint(.black.opacity(0.35)), in: .capsule)
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .font(.ag(14, .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                Button("Try again") { Task { await live.retry() } }
                    .font(.ag(14, .semibold))
                    .buttonStyle(.glass)
            }
            .padding(20)
            .glassEffect(.regular.tint(.black.opacity(0.4)), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(24)
        case .playing:
            EmptyView()
        }
    }

    private var topBadges: some View {
        HStack {
            if live.isPlaying {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 6) {
                        Circle().fill(AG.signal).frame(width: 8, height: 8)
                        Text("Live · \(elapsed(at: context.date))")
                            .monospacedDigit()
                    }
                }
                .font(.ag(12, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular.tint(.black.opacity(0.3)), in: .capsule)
            }
            Spacer()
            if live.isRecording {
                Label("Recording", systemImage: "record.circle")
                    .font(.ag(12, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(AG.signal, in: Capsule())
            }
        }
        .padding(14)
    }

    private func elapsed(at date: Date) -> String {
        guard let started = live.startedAt else { return "0:00" }
        let seconds = max(0, Int(date.timeIntervalSince(started)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func controls(_ camera: ArloDevice) -> some View {
        let talkOn = talk.state == .live || talk.state == .connecting
        let canTalk = capabilities.pushToTalk && !capabilities.usesSIPTalk && live.isPlaying
        return GlassEffectContainer(spacing: 8) {
            HStack(spacing: 2) {
                ControlButton(title: "Talk", symbol: talkOn ? "mic.fill" : "mic", isOn: talkOn,
                              isEnabled: canTalk || talkOn, isBusy: talk.state == .connecting) {
                    if talkOn {
                        talk.stop()
                    } else {
                        Task { await talk.start(camera: camera, store: store) }
                    }
                }
                ControlButton(title: "Siren", symbol: "light.beacon.max", isOn: live.isSirenOn, tint: AG.signal,
                              isEnabled: camera.hasSiren, isBusy: live.busyControl == "siren") {
                    if live.isSirenOn {
                        Task { await live.toggleSiren() }
                    } else {
                        confirmSiren = true
                    }
                }
                ControlButton(title: "Light", symbol: live.isLightOn ? "lightbulb.fill" : "lightbulb", isOn: live.isLightOn,
                              isEnabled: camera.hasLight, isBusy: live.busyControl == "light") {
                    Task { await live.toggleLight() }
                }
                ControlButton(title: "Snapshot", symbol: "camera", isOn: false,
                              isEnabled: live.isPlaying, isBusy: false) {
                    Task { await live.snapshot() }
                }
                ControlButton(title: "Record", symbol: "record.circle", isOn: live.isRecording, tint: AG.signal,
                              isEnabled: live.isPlaying, isBusy: live.busyControl == "record") {
                    Task { await live.toggleRecording() }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .glassEffect(.regular.tint(.black.opacity(0.32)),
                         in: RoundedRectangle(cornerRadius: AG.cardRadius, style: .continuous))
        }
        .padding(10)
        .overlay(alignment: .top) {
            if case .failed(let message) = talk.state {
                Text(message)
                    .font(.ag(12, .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.tint(.black.opacity(0.4)), in: .capsule)
                    .offset(y: -36)
            }
        }
    }

    // MARK: Today

    private func todayCard(_ camera: ArloDevice) -> some View {
        let clips = store.todayClips.filter { $0.deviceId == camera.id }
        let visits = Visit.group(clips, byVisit: groupByVisit)
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Today on this camera")
            Figure(value: "\(visits.count)", unit: visits.first.map { "visits · last at \($0.start.formatted(date: .omitted, time: .shortened))" } ?? "visits", size: 48)
            DayTimeline(visits: visits)
            VStack(spacing: 0) {
                ForEach(Array(visits.prefix(3))) { visit in
                    VisitRow(visit: visit, cameraName: camera.name)
                        .overlay(alignment: .top) { Rectangle().fill(AG.hairline).frame(height: 1) }
                }
            }
        }
        .agCard()
    }
}

/// One of the five round buttons in the glass bar over the video.
struct ControlButton: View {
    let title: String
    let symbol: String
    let isOn: Bool
    var tint: Color?
    let isEnabled: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                ZStack {
                    Circle().fill(fill)
                    if isBusy {
                        ProgressView().tint(foreground)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(foreground)
                    }
                }
                .frame(width: 50, height: 50)
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? "On" : "Off")

            Text(title)
                .font(.ag(12, .medium))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var fill: Color {
        guard isOn else { return .white.opacity(0.16) }
        return tint ?? .white
    }

    private var foreground: Color {
        isOn && tint == nil ? AG.ink950 : .white
    }
}

/// Dots for each visit along the day, with the present moment marked.
struct DayTimeline: View {
    let visits: [Visit]

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(AG.paper).frame(height: 10)
                    ForEach(visits) { visit in
                        Circle()
                            .fill(visit.id == visits.first?.id ? AG.ember : AG.ink950)
                            .frame(width: 10, height: 10)
                            .offset(x: position(of: visit.start) * (width - 10))
                    }
                    Rectangle()
                        .fill(AG.ember)
                        .frame(width: 2, height: 18)
                        .offset(x: position(of: Date()) * (width - 2))
                }
                .frame(height: 18)
            }
            .frame(height: 18)
            HStack {
                ForEach(["00", "06", "12", "18", "24"], id: \.self) { hour in
                    Text(hour).frame(maxWidth: .infinity, alignment: hour == "00" ? .leading : (hour == "24" ? .trailing : .center))
                }
            }
            .font(.ag(11))
            .foregroundStyle(AG.stone500)
        }
        .accessibilityElement()
        .accessibilityLabel("\(visits.count) visits today")
    }

    private func position(of date: Date) -> CGFloat {
        let start = Calendar.current.startOfDay(for: Date())
        return CGFloat(min(max(date.timeIntervalSince(start) / 86_400, 0), 1))
    }
}

struct FullScreenPlayer: View {
    let stream: LiveStream?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let stream {
                LiveVideoView(stream: stream, gravity: .resizeAspect)
                    .ignoresSafeArea()
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Close full screen")
            .padding(16)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }
}
