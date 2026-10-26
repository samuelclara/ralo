import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch model.phase {
            case .launching:
                LightField()
            case .signedOut:
                SignInView()
            case .locked:
                LockView()
            case .ready:
                if let store = model.store {
                    MainTabs(store: store)
                } else {
                    LightField()
                }
            }

            // Hides the screen in the app switcher and while Face ID is up.
            if scenePhase != .active {
                PrivacyCover()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: scenePhase)
        .animation(.easeInOut(duration: 0.25), value: model.phase)
        .preferredColorScheme(.light)
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            LightField()
            AppMark(size: 72)
        }
        .accessibilityLabel("Ralo is hidden")
    }
}

enum AppTab: Hashable {
    case home, clips, alerts, settings
}

struct MainTabs: View {
    let store: CameraStore
    @State private var tab: AppTab = .home

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack {
                    HomeView(store: store, openClips: { tab = .clips }, openAlerts: { tab = .alerts })
                }
            }
            Tab("Clips", systemImage: "play.rectangle", value: AppTab.clips) {
                NavigationStack { ClipsView(store: store) }
            }
            Tab("Alerts", systemImage: "bell", value: AppTab.alerts) {
                NavigationStack { AlertsView(store: store) }
            }
            Tab("Settings", systemImage: "lock.shield", value: AppTab.settings) {
                NavigationStack { SettingsView(store: store) }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(AG.ink950)
    }
}
