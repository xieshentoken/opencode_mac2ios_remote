import SwiftUI

struct SessionListView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var deleteMode = false
    @State private var pendingDelete: Session?

    var body: some View {
        VStack(spacing: 0) {
            TUIScreenHeader(title: deleteMode ? "select session to delete" : "sessions", detail: "robot / session switcher", close: { dismiss() })
            HStack(spacing: 8) {
                PixelRobot().frame(width: 47, height: 41)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(appState.sessions.count) sessions")
                    Text(appState.activeSession?.directory ?? "~").foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                Spacer()
                Button(deleteMode ? "[- delete ]" : "[- delete]") { deleteMode.toggle() }
                    .buttonStyle(TUIButtonStyle(accent: deleteMode ? Theme.red : Theme.borderStrong, filled: deleteMode))
                    .disabled(!appState.canMutateSessions)
                Button("[ + new ]") { Task { await create() } }
                    .buttonStyle(TUIButtonStyle(accent: Theme.accent))
                    .disabled(!appState.canMutateSessions)
            }
            .font(Theme.monoFont(size: 10))
            .foregroundStyle(Theme.textSecondary)
            .padding(9)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .bottom)

            if appState.sessions.isEmpty {
                Spacer()
                Text("~ no sessions")
                    .font(Theme.monoFont(size: 11))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groupedSessions, id: \.directory) { group in
                            sectionHeader(group.directory)
                            ForEach(group.sessions) { session in
                                SessionRow(session: session, running: appState.activeSessionID == session.id && appState.activeSessionRunning)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if deleteMode {
                                            pendingDelete = session
                                        } else {
                                            appState.selectSession(session.id)
                                            dismiss()
                                        }
                                    }
                                    .contextMenu {
                                        if appState.canMutateSessions {
                                            Button("Delete", role: .destructive) { pendingDelete = session }
                                        }
                                    }
                            }
                        }
                    }
                }
                .scrollIndicators(.visible)
                .scrollDismissesKeyboard(.immediately)
                .onTapGesture { hideKeyboard() }
            }
            StatusBar(path: appState.activeSession?.directory ?? "~", connected: appState.connectionState == .connected, version: appState.serverVersion, running: appState.activeSessionRunning)
        }
        .background(Theme.background.ignoresSafeArea())
        .dismissKeyboardOnTapOutside()
        .overlay {
            if let pendingDelete {
                ZStack(alignment: .center) {
                    Color.black.opacity(0.6).ignoresSafeArea().onTapGesture { self.pendingDelete = nil }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("delete session?")
                            .font(Theme.monoFont(size: 11, weight: .bold))
                            .foregroundStyle(Theme.red)
                        Text(deleteTitle(pendingDelete))
                            .font(Theme.monoFont(size: 10))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        HStack(spacing: 8) {
                            Button("[ no ]") { self.pendingDelete = nil }
                                .buttonStyle(TUIButtonStyle(accent: Theme.borderStrong))
                            Button("[ yes ]") { confirmDelete(pendingDelete) }
                                .buttonStyle(TUIButtonStyle(accent: Theme.red, filled: true))
                        }
                    }
                    .padding(14)
                    .background(Theme.backgroundRaised)
                    .overlay(Rectangle().stroke(Theme.red.opacity(0.75), lineWidth: 1))
                    .padding(32)
                }
            }
        }
        .overlay(alignment: .bottom) { PermissionBarOverlay() }
    }

    private var groupedSessions: [(directory: String, sessions: [Session])] {
        let groups = Dictionary(grouping: appState.sessions) { $0.directory ?? "~" }
        return groups
            .map { (directory: $0.key, sessions: $0.value.sorted { ($0.time?.updated ?? 0) > ($1.time?.updated ?? 0) }) }
            .sorted { $0.directory < $1.directory }
    }

    private func sectionHeader(_ value: String) -> some View {
        Text("┤ \(value) ├")
            .font(Theme.monoFont(size: 9, weight: .semibold))
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .background(Theme.backgroundInput)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border.opacity(0.45)), alignment: .bottom)
    }

    private func create() async {
        await appState.createSession()
        dismiss()
    }

    private func deleteTitle(_ session: Session) -> String {
        let title = session.title?.isEmpty == false ? session.title! : (session.slug ?? session.id)
        return "\(title)\n\(session.directory ?? "~")"
    }

    private func confirmDelete(_ session: Session) {
        pendingDelete = nil
        deleteMode = false
        Task {
            await appState.deleteSession(session.id)
        }
    }
}

struct SessionRow: View {
    let session: Session
    let running: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(running ? "●" : " ").foregroundStyle(Theme.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(session.directory ?? "~")
                    .font(Theme.monoFont(size: 9))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            if let summary = session.summary {
                Text("+\(summary.additions ?? 0) -\(summary.deletions ?? 0)")
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(updatedTime).foregroundStyle(Theme.textMuted)
        }
        .font(Theme.monoFont(size: 10))
        .padding(.horizontal, 9)
        .frame(minHeight: 49)
        .background(Theme.background)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .bottom)
    }

    private var title: String { session.title?.isEmpty == false ? session.title! : (session.slug ?? session.id) }
    private var updatedTime: String {
        guard let t = session.time?.updated else { return "" }
        return Date(timeIntervalSince1970: Double(t) / 1000).formatted(.dateTime.hour().minute())
    }
}
