import SwiftUI

// MARK: - Permission dialog (TUI dialog style)

struct PermissionDialogView: View {
    @EnvironmentObject private var appState: AppState
    let permission: PermissionRequest
    @State private var expanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("!").foregroundColor(Theme.background).frame(width: 16, height: 16).background(Theme.yellow)
                Text("Permission requested")
                    .font(Theme.monoFont(size: 11, weight: .bold))
                    .foregroundColor(Theme.yellow)
                Spacer()
                Text(permission.permission ?? "unknown")
                    .font(Theme.monoFont(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }

            if let cmd = permission.commandText {
                Text(cmd)
                    .font(Theme.monoFont(size: 11))
                    .foregroundColor(Theme.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(expanded ? nil : 2)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.backgroundInput)
                    .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
                    .onTapGesture { withAnimation { expanded.toggle() } }
            }

            if let patterns = permission.patterns, !patterns.isEmpty {
                Text(patterns.joined(separator: ", "))
                    .font(Theme.monoFont(size: 9))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }

            if !appState.canRespondToAgentRequests {
                Text("WebSocket reconnect required before replying")
                    .font(Theme.monoFont(size: 9))
                    .foregroundStyle(Theme.yellow)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await appState.respond(to: permission, response: .reject) }
                } label: {
                    Text("reject")
                        .font(Theme.monoFont(size: 11, weight: .semibold))
                        .foregroundColor(Theme.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.backgroundInput)
                        .overlay(Rectangle().stroke(Theme.red.opacity(0.7), lineWidth: 1))
                }
                .buttonStyle(BorderlessButtonStyle())
                .disabled(!appState.canRespondToAgentRequests)

                Button {
                    Task { await appState.respond(to: permission, response: .once) }
                } label: {
                    Text("once")
                        .font(Theme.monoFont(size: 11, weight: .semibold))
                        .foregroundColor(Theme.background)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Theme.accent)
                        .overlay(Rectangle().stroke(Theme.accent, lineWidth: 1))
                }
                .buttonStyle(BorderlessButtonStyle())
                .disabled(!appState.canRespondToAgentRequests)

                if permission.always?.isEmpty == false {
                    Button {
                        Task { await appState.respond(to: permission, response: .always) }
                    } label: {
                        Text("always")
                            .font(Theme.monoFont(size: 11, weight: .semibold))
                            .foregroundColor(Theme.green)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Theme.backgroundInput)
                            .overlay(Rectangle().stroke(Theme.green.opacity(0.7), lineWidth: 1))
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .disabled(!appState.canRespondToAgentRequests)
                }
                Spacer()
            }
        }
            .padding(12)
        }
        .scrollIndicators(.visible)
        .frame(maxHeight: 240)
        .background(Theme.backgroundRaised)
        .overlay(Rectangle().stroke(Theme.yellow.opacity(0.75), lineWidth: 1))
    }
}
