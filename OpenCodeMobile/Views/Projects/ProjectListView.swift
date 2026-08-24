import SwiftUI

struct ProjectListView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var switching = ""

    var body: some View {
        VStack(spacing: 0) {
            TUIScreenHeader(title: "projects", detail: "workspaces on the Mac", close: { dismiss() })
            HStack(spacing: 8) {
                PixelRobot().frame(width: 47, height: 41)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(appState.projects.count) projects")
                    Text(appState.activeDirectory ?? "~")
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Button("[ new ]") { dismiss() }
                    .buttonStyle(TUIButtonStyle(accent: Theme.accent))
            }
            .font(Theme.monoFont(size: 10))
            .foregroundStyle(Theme.textSecondary)
            .padding(9)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .bottom)

            if appState.projects.isEmpty {
                Spacer()
                Text("~ no projects")
                    .font(Theme.monoFont(size: 11))
                    .foregroundStyle(Theme.textMuted)
                Text("switch to a workspace, or create one via [ + ] / new project")
                    .font(Theme.monoFont(size: 9))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, 4)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appState.projects) { project in
                            ProjectRow(project: project, active: project.worktree == appState.activeDirectory, switching: switching == project.worktree)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard switching.isEmpty else { return }
                                    switching = project.worktree ?? project.id
                                    Task {
                                        await appState.switchProject(to: project.worktree ?? project.id)
                                        dismiss()
                                    }
                                }
                        }
                    }
                }
                .scrollIndicators(.visible)
                .scrollDismissesKeyboard(.immediately)
                .onTapGesture { hideKeyboard() }
            }
            StatusBar(path: appState.activeDirectory ?? "~", connected: appState.connectionState == .connected, version: appState.serverVersion, running: false)
        }
        .background(Theme.background.ignoresSafeArea())
        .dismissKeyboardOnTapOutside()
        .overlay(alignment: .bottom) { PermissionBarOverlay() }
        .task {
            await appState.refreshProjects()
        }
    }
}

struct ProjectRow: View {
    let project: Project
    let active: Bool
    let switching: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(active ? "●" : (switching ? "…" : " ")).foregroundStyle(Theme.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(project.worktree ?? project.id)
                    .font(Theme.monoFont(size: 9))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            if let status = project.status {
                Text(status)
                    .font(Theme.monoFont(size: 9))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .font(Theme.monoFont(size: 10))
        .padding(.horizontal, 9)
        .frame(minHeight: 49)
        .background(active ? Theme.selection : Theme.background)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .bottom)
    }

    private var name: String {
        let path = project.worktree ?? project.id
        return URL(fileURLWithPath: path).lastPathComponent.isEmpty ? path : URL(fileURLWithPath: path).lastPathComponent
    }
}
