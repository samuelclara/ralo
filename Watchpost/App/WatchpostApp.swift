import SwiftUI

@main
struct WatchpostApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Typeface.register()
        Preferences.register()
        NavigationAppearance.apply()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { model.launch() }
        }
        // The app-wide phase: background only when every window is in the background.
        .onChange(of: scenePhase) { _, newPhase in
            model.scenePhaseChanged(to: newPhase)
        }
    }
}
