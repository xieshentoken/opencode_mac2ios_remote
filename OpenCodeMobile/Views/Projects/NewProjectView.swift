import SwiftUI

struct NewProjectView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var rootPath = ""
    @State private var projectName = ""
    @State private var creating = false
    @State private var error = ""
    @State private var useGitInit = true

    var body: some View {
        VStack(spacing: 0) {
            TUIScreenHeader(title: "new project", detail: "runs on the connected Mac", close: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PixelRobot().frame(width: 65, height: 57).frame(maxWidth: .infinity)
                    label("workspace root")
                    TUIField(prompt: "/path/to/projects", text: $rootPath)
                    label("project name")
                    TUIField(prompt: "my-project", text: $projectName)
                    Button {
                        useGitInit.toggle()
                    } label: {
                        Text("[\(useGitInit ? "x" : " ")] git init via native endpoint")
                    }
                    .buttonStyle(.plain)
                    .font(Theme.monoFont(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                    if !error.isEmpty { Text(error).font(Theme.monoFont(size: 10)).foregroundStyle(Theme.red) }
                    Button(creating ? "[ creating... ]" : "[ create project + session ]", action: create)
                        .buttonStyle(TUIButtonStyle(accent: Theme.accent, filled: true))
                        .disabled(rootPath.isEmpty || projectName.isEmpty || creating)
                }
                .padding(12)
            }
            .scrollDismissesKeyboard(.immediately)
            .onTapGesture { hideKeyboard() }
            StatusBar(path: targetDirectory, connected: appState.connectionState == .connected, version: appState.serverVersion, running: creating)
        }
        .background(Theme.background.ignoresSafeArea())
        .dismissKeyboardOnTapOutside()
        .overlay(alignment: .bottom) { PermissionBarOverlay() }
    }

    private func label(_ value: String) -> some View {
        Text("┤ \(value) ├").font(Theme.monoFont(size: 10, weight: .semibold)).foregroundStyle(Theme.textMuted)
    }

    private var targetDirectory: String {
        let root = rootPath.trimmingCharacters(in: .whitespaces)
        let name = projectName.trimmingCharacters(in: .whitespaces)
        return root.hasSuffix("/") ? root + name : root + "/" + name
    }

    private func create() {
        guard let api = appState.api else { return }
        creating = true
        error = ""
        let dir = targetDirectory
        Task {
            do {
                if useGitInit { _ = try await api.gitInit(directory: dir) }
                let session = try await api.createSession(directory: dir, agent: appState.selectedAgentID, model: appState.selectedModel)
                await appState.switchProject(to: session.directory ?? dir)
                appState.selectSession(session.id)
                await appState.refreshProjects()
                dismiss()
            } catch {
                self.error = error.localizedDescription
                creating = false
            }
        }
    }
}
