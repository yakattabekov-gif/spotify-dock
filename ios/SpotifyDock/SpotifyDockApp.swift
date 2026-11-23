import SwiftUI

@main
struct SpotifyDockApp: App {
    @StateObject private var model = DockModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
                .onChange(of: phase) { p in
                    UIApplication.shared.isIdleTimerDisabled = (p == .active)
                    if p == .active { model.resume() } else { model.pause() }
                }
        }
    }
}
