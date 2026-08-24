import SwiftUI

/// MCP server status dialog — reached by long-pressing the robot icon in the
/// chat header. Lists every configured server on the Mac with a per-server
/// connect/disconnect toggle.
struct MCPListView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TUIScreenHeader(title: "mcp servers", detail: "model context protocol on the Mac", close: { dismiss() })
            HStack(spacing: 8) {
                PixelRobot().frame(width: 47, height: 41)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(appState.mcpStatuses.count) configured")
                    Text("\(connectedCount) connected").foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Button("[ refresh ]") { Task { await appState.refreshMCPs() } }
                    .buttonStyle(TUIButtonStyle(accent: Theme.borderStrong))
            }
            .font(Theme.monoFont(size: 10))
            .foregroundStyle(Theme.textSecondary)
            .padding(9)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .bottom)

            if appState.mcpStatuses.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Text("~ no mcp servers configured")
                        .font(Theme.monoFont(size: 11))
                        .foregroundStyle(Theme.textMuted)
                    Text("configure them in opencode.json / .mcp.json on the Mac")
                        .font(Theme.monoFont(size: 9))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row)
                        }
                    }
                }
                .scrollIndicators(.visible)
                .scrollDismissesKeyboard(.immediately)
            }
            StatusBar(
                path: appState.activeSession?.directory ?? appState.activeDirectory ?? "~",
                connected: appState.connectionState == .connected,
                version: appState.serverVersion,
                running: false
            )
        }
        .background(Theme.background.ignoresSafeArea())
        .dismissKeyboardOnTapOutside()
        .overlay(alignment: .bottom) { PermissionBarOverlay() }
        .task { await appState.refreshMCPs() }
    }

    private var connectedCount: Int {
        appState.mcpStatuses.values.filter(\.connected).count
    }

    private var rows: [MCPRow] {
        appState.mcpStatuses
            .map { MCPRow(id: $0.key, name: $0.key, status: $0.value) }
            .sorted {
                if $0.status.connected != $1.status.connected { return $0.status.connected }
                return $0.name < $1.name
            }
    }

    private func rowView(_ row: MCPRow) -> some View {
        HStack(spacing: 8) {
            Text(row.status.connected ? "●" : "○")
                .foregroundStyle(row.status.connected ? Theme.green : Theme.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let err = row.status.error, !err.isEmpty {
                    Text(err)
                        .font(Theme.monoFont(size: 9))
                        .foregroundStyle(Theme.red)
                        .lineLimit(2)
                } else {
                    Text(row.status.connected ? "connected" : "disconnected")
                        .font(Theme.monoFont(size: 9))
                        .foregroundStyle(row.status.connected ? Theme.green : Theme.textMuted)
                }
            }
            Spacer()
            Button(row.status.connected ? "[ disconnect ]" : "[ connect ]") {
                Task { await appState.toggleMCP(name: row.name) }
            }
            .buttonStyle(TUIButtonStyle(accent: row.status.connected ? Theme.red : Theme.green))
        }
        .font(Theme.monoFont(size: 10))
        .padding(.horizontal, 9)
        .frame(minHeight: 49)
        .background(Theme.background)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .bottom)
    }
}

private struct MCPRow: Identifiable {
    let id: String
    let name: String
    let status: MCPStatus
}
