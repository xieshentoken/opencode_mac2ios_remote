import SwiftUI

@main
struct OpenCodeMobileApp: App {
    @StateObject private var appState = AppState()
    @State private var theme = ThemeSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(theme.isLight ? .light : .dark)
                .onChange(of: scenePhase) { _, phase in
                    // iOS severs SSE when backgrounded. On foreground, reopen
                    // the stream and reconcile messages/pending permissions
                    // against REST so nothing is missed while asleep.
                    if phase == .active {
                        Task { await appState.reconcileOnForeground() }
                    }
                }
        }
    }
}
