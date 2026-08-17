import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            Group {
                if appState.connectionState == .connected {
                    ChatView()
                } else {
                    SettingsView()
                }
            }
            if appState.errorShown {
                Color.black.opacity(0.72).ignoresSafeArea()
                BorderedBox(title: "error", color: Theme.red) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(appState.lastError ?? "unknown error")
                            .font(Theme.monoFont(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                        Button("[ ok ]") { appState.errorShown = false }
                            .buttonStyle(TUIButtonStyle(accent: Theme.red))
                    }
                }
                .padding(24)
            }
        }
        .dismissKeyboardOnTapOutside()
        .task {
            await appState.connect()
            #if DEBUG
            if appState.e2eRequested {
                await appState.runE2ETest()
            }
            #endif
        }
    }
}
