import SwiftUI

struct CameraRoute: Hashable {
    let cameraId: String
}

struct HomeView: View {
    let store: CameraStore
    let openClips: () -> Void
    let openAlerts: () -> Void

    @AppStorage(PreferenceKey.groupByVisit) private var groupByVisit = true
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var visits: [Visit] { Visit.group(store.todayClips, byVisit: groupByVisit) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(statusLine)
                    .font(.ag(13))
                    .foregroundStyle(AG.ink800)

                if let message = store.errorMessage {
                    ErrorBanner(message: message) { Task { await store.refresh() } }
                }

                modeSection
                camerasSection
                todaySection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
        }
        .background(LightField())
        .navigationTitle("Home")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openAlerts) {
                    Image(systemName: "bell")
                }
                .accessibilityLabel("Alert settings")
            }
        }
        .refreshable { await store.refresh() }
        .navigationDestination(for: CameraRoute.self) { route in
            LiveView(store: store, cameraId: route.cameraId)
        }
        .overlay {
            if !store.hasLoaded {
                ProgressView().controlSize(.large)
            }
        }
    }

    private var statusLine: String {
        let cameras = store.cameras
        guard store.hasLoaded else { return "Connecting to Arlo…" }
        guard !cameras.isEmpty else { return "No cameras on this account" }
        let offline = cameras.filter { ($0.connectionState ?? "available").lowercased() != "available" }.count
        let noun = cameras.count == 1 ? "camera" : "cameras"
        return offline == 0 ? "\(cameras.count) \(noun) · all online" : "\(cameras.count) \(noun) · \(offline) offline"
    }

    // MARK: Mode

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Security mode")
                .font(.ag(15, .medium))
            Text(store.mode?.label ?? "—")
                .font(.ag(72, .light, relativeTo: .largeTitle))
                .tracking(-2.8)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.opacity)
                .accessibilityLabel("Security mode: \(store.mode?.label ?? "unknown")")
            Text(caption)
                .font(.ag(13))
                .foregroundStyle(AG.ink800)
            ModeSwitcher(
                selected: store.mode,
                supportsHome: store.supportsHomeMode,
                isBusy: store.isChangingMode || store.modeControl == .unavailable
            ) { mode in
                Task { await store.setMode(mode) }
            }
            .padding(.top, 4)
        }
        .animation(.snappy, value: store.mode)
    }

    private var caption: String {
        if store.modeControl == .unavailable && store.hasLoaded {
            return "Modes aren't available for this account."
        }
        return store.mode?.caption ?? " "
    }

    // MARK: Cameras

    private var camerasSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Cameras", detail: "Tap for live view")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 220 : 150), spacing: 12)],
                spacing: 12
            ) {
                ForEach(store.cameras) { camera in
                    NavigationLink(value: CameraRoute(cameraId: camera.id)) {
                        CameraTile(camera: camera, hasMotion: store.hasRecentMotion(camera), mode: store.mode,
                                   forecast: store.batteryForecast(for: camera))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Today

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Visits today", action: ("All clips", openClips))
            Figure(value: "\(visits.count)", unit: breakdown)
            VStack(spacing: 0) {
                ForEach(Array(visits.prefix(3))) { visit in
                    Button(action: openClips) {
                        VisitRow(visit: visit, cameraName: store.camera(id: visit.cameraId)?.name ?? "Camera")
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .top) {
                        Rectangle().fill(AG.hairline).frame(height: 1)
                    }
                }
                if visits.isEmpty && store.hasLoaded {
                    Text("Nothing yet today.")
                        .font(.ag(14))
                        .foregroundStyle(AG.stone500)
                        .padding(.vertical, 8)
                }
            }
        }
        .agCard()
    }

    private var breakdown: String {
        let counts = Dictionary(grouping: visits, by: \.category).mapValues(\.count)
        let parts: [String] = [
            counts[.person].map { "\($0) with people" },
            counts[.package].map { "\($0) parcel\($0 == 1 ? "" : "s")" },
            counts[.vehicle].map { "\($0) car\($0 == 1 ? "" : "s")" },
            counts[.animal].map { "\($0) animal\($0 == 1 ? "" : "s")" },
        ].compactMap { $0 }
        return parts.isEmpty ? "visits" : parts.joined(separator: " · ")
    }
}

struct ModeSwitcher: View {
    let selected: SecurityMode?
    let supportsHome: Bool
    let isBusy: Bool
    let onSelect: (SecurityMode) -> Void

    @Namespace private var selection

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SecurityMode.allCases) { mode in
                let isOn = mode == selected
                let isAvailable = mode != .home || supportsHome
                Button {
                    onSelect(mode)
                } label: {
                    Text(mode.label)
                        .font(.ag(15, .medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(isOn ? Color.white : AG.ink800)
                        .background {
                            if isOn {
                                Capsule()
                                    .fill(AG.ink950)
                                    .matchedGeometryEffect(id: "selected", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isBusy || !isAvailable)
                .opacity(isAvailable ? 1 : 0.35)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(5)
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(.snappy, value: selected)
    }
}

struct CameraTile: View {
    let camera: ArloDevice
    let hasMotion: Bool
    let mode: SecurityMode?
    var forecast: BatteryForecast?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureImage(url: camera.lastImageURL)
                .frame(height: 110)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: AG.tileRadius, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if hasMotion {
                        Badge(text: "Motion").padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let battery = camera.batteryLevel, camera.runsOnBattery {
                        BatteryBadge(level: battery, isCharging: camera.isCharging).padding(8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .glassEffect(.regular.tint(.black.opacity(0.3)), in: .circle)
                        .padding(8)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(camera.name)
                    .font(.ag(15, .medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.ag(12))
                    .foregroundStyle(AG.stone500)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
        }
        .padding(.init(top: 8, leading: 8, bottom: 14, trailing: 8))
        .background(.white, in: RoundedRectangle(cornerRadius: AG.cardRadius, style: .continuous))
        .shadow(color: AG.ink950.opacity(0.06), radius: 20, y: 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(camera.name), \(detail)\(batteryLabel)\(hasMotion ? ", motion" : "")")
        .accessibilityHint("Opens live view")
    }

    private var detail: String {
        if let state = camera.connectionState, state.lowercased() != "available" {
            return "Offline"
        }
        if mode == .off { return "Not recording" }
        if let label = forecast?.shortLabel { return label }
        return "Online"
    }

    private var batteryLabel: String {
        guard let battery = camera.batteryLevel, camera.runsOnBattery else { return "" }
        return ", battery \(battery)%\(camera.isCharging ? ", charging" : "")"
    }
}

struct VisitRow: View {
    let visit: Visit
    let cameraName: String

    var body: some View {
        HStack(spacing: 12) {
            SecureImage(url: visit.thumbnailURL)
                .frame(width: 72, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if visit.durationSeconds > 0 {
                        Text(visit.durationLabel)
                            .font(.ag(10, .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .glassEffect(.regular.tint(.black.opacity(0.35)), in: .capsule)
                            .padding(4)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.ag(15, .medium))
                Text(cameraName)
                    .font(.ag(12))
                    .foregroundStyle(AG.stone500)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(visit.start, format: .dateTime.hour().minute())
                .font(.ag(13))
                .foregroundStyle(AG.stone500)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        visit.clips.count > 1 ? "\(visit.category.title) · \(visit.clips.count) clips" : visit.category.title
    }
}
