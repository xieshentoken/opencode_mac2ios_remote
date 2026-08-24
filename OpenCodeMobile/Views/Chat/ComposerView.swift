import SwiftUI

enum QuickPanelKind: String, Identifiable {
    case files, models, agents, commands, skills, themes, variants
    var id: String { rawValue }
}

struct ComposerView: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let running: Bool
    let model: String
    let agent: String
    let variant: String?
    let supportsOpenCodeControls: Bool
    let inputEnabled: Bool
    let onOpen: (QuickPanelKind) -> Void
    let onToggleMode: () -> Void
    let onSend: () -> Void
    let onAbort: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(Theme.accent).frame(width: 2)
                TextField("Ask anything... \"Fix broken tests\"", text: $text, axis: .vertical)
                    .focused(focused)
                    .font(Theme.monoFont(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1...5)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 10)
                    .submitLabel(.send)
                    .onSubmit { if !running { onSend() } }
                    .disabled(!inputEnabled)
                Button(running ? "[■]" : "[↵]") { running ? onAbort() : onSend() }
                    .buttonStyle(.plain)
                    .font(Theme.monoFont(size: 11, weight: .bold))
                    .foregroundStyle(running ? Theme.red : Theme.textPrimary)
                    .padding(.trailing, 8)
                    .padding(.top, 8)
                    .disabled(
                        running
                            ? !inputEnabled
                            : (!inputEnabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    )
            }
            .frame(minHeight: 34, maxHeight: text.isEmpty ? 42 : 108, alignment: .top)
            .background(Theme.backgroundInput)
            .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5.5) {
                    if supportsOpenCodeControls {
                        chip("@file", color: Theme.textPrimary) { onOpen(.files) }
                        chip(short(model), color: Theme.textPrimary) { onOpen(.models) }
                        chip(agent == "plan" ? "plan" : "build", color: agent == "plan" ? Theme.yellow : Theme.green, action: onToggleMode)
                        if let variant, !variant.isEmpty {
                            chip(variant, color: Theme.cyan, action: { onOpen(.variants) })
                        } else {
                            chip("think", color: Theme.textMuted, action: { onOpen(.variants) })
                        }
                        chip("skill", color: Theme.magenta) { onOpen(.skills) }
                        chip("commands", color: Theme.textSecondary) { onOpen(.commands) }
                    } else {
                        Text(inputEnabled ? "hermes · websocket" : "hermes · history only")
                            .font(Theme.monoFont(size: 10, weight: .semibold))
                            .foregroundStyle(inputEnabled ? Theme.green : Theme.yellow)
                            .frame(height: 21)
                    }
                }
            }
        }
    }

    private func chip(_ text: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(Theme.monoFont(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 4)
                .frame(height: 21)
        }.buttonStyle(.plain)
    }

    private func short(_ value: String) -> String {
        value.count > 18 ? String(value.prefix(17)) + "…" : value
    }
}

struct PermissionBanner: View {
    @EnvironmentObject private var appState: AppState
    var body: some View {
        if !appState.pendingPermissions.isEmpty || !appState.pendingInputRequests.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("!").font(Theme.monoFont(size: 9, weight: .bold))
                        .foregroundColor(Theme.background)
                        .frame(width: 15, height: 15)
                        .background(Theme.yellow)
                    Text(appState.pendingInputRequests.isEmpty ? "permission requested" : "agent needs input")
                        .font(Theme.monoFont(size: 10, weight: .bold))
                        .foregroundStyle(Theme.yellow)
                    Spacer()
                    Text("\(appState.pendingPermissions.count + appState.pendingInputRequests.count) pending")
                        .font(Theme.monoFont(size: 9))
                        .foregroundStyle(Theme.textMuted)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(appState.pendingPermissions) { permission in
                            PermissionDialogView(permission: permission)
                        }
                        ForEach(appState.pendingInputRequests) { request in
                            AgentInputDialogView(request: request)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 300)
            }
            .background(Theme.backgroundRaised)
            .overlay(Rectangle().stroke(Theme.yellow.opacity(0.75), lineWidth: 1))
        }
    }
}

/// Bottom-overlay variant for screens outside the chat (session list,
/// settings, projects, ...). Non-blocking: only the bar itself captures
/// touches; the rest of the screen stays interactive.
struct PermissionBarOverlay: View {
    @EnvironmentObject private var appState: AppState
    var body: some View {
        if !appState.pendingPermissions.isEmpty || !appState.pendingInputRequests.isEmpty {
            PermissionBanner()
                .padding(8)
        }
    }
}

struct AgentInputDialogView: View {
    @EnvironmentObject private var appState: AppState
    let request: AgentInputRequest
    @State private var answer = ""
    @State private var selected = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("?")
                    .foregroundStyle(Theme.background)
                    .frame(width: 16, height: 16)
                    .background(Theme.cyan)
                Text(request.kind.rawValue)
                    .font(Theme.monoFont(size: 11, weight: .bold))
                    .foregroundStyle(Theme.cyan)
                Spacer()
            }
            Text(request.prompt)
                .font(Theme.monoFont(size: 11))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)

            if !appState.canRespondToAgentRequests {
                Text("WebSocket reconnect required before replying")
                    .font(Theme.monoFont(size: 9))
                    .foregroundStyle(Theme.yellow)
            }

            if !request.choices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                    ForEach(request.choices, id: \.self) { choice in
                        Button("[ \(choice) ]") { select(choice) }
                            .buttonStyle(TUIButtonStyle(accent: selected.contains(choice) || answer == choice ? Theme.cyan : Theme.borderStrong))
                    }
                    }
                }
            }

            if request.kind.requiresSecureEntry {
                SecureField("value", text: $answer)
                    .textContentType(request.kind == .sudo ? .password : nil)
                    .font(Theme.monoFont(size: 11))
                    .padding(8)
                    .background(Theme.backgroundInput)
                    .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
            } else {
                TextField("answer", text: $answer, axis: .vertical)
                    .lineLimit(1...4)
                    .font(Theme.monoFont(size: 11))
                    .padding(8)
                    .background(Theme.backgroundInput)
                    .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
            }

            HStack {
                Spacer()
                Button("[ submit ]") {
                    let value = request.multiSelect && !selected.isEmpty
                        ? selected.sorted().joined(separator: ",")
                        : answer
                    Task { await appState.respond(to: request, answer: value) }
                }
                .buttonStyle(TUIButtonStyle(accent: Theme.cyan, filled: true))
                .disabled(
                    !appState.canRespondToAgentRequests
                        || (answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selected.isEmpty)
                )
            }
        }
        .padding(12)
        .background(Theme.backgroundRaised)
        .overlay(Rectangle().stroke(Theme.cyan.opacity(0.75), lineWidth: 1))
    }

    private func select(_ choice: String) {
        if request.multiSelect {
            if selected.contains(choice) { selected.remove(choice) } else { selected.insert(choice) }
            answer = selected.sorted().joined(separator: ",")
        } else {
            answer = choice
            selected = [choice]
        }
    }
}
