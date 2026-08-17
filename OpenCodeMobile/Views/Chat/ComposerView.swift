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
                Button(running ? "[■]" : "[↵]") { running ? onAbort() : onSend() }
                    .buttonStyle(.plain)
                    .font(Theme.monoFont(size: 11, weight: .bold))
                    .foregroundStyle(running ? Theme.red : Theme.textPrimary)
                    .padding(.trailing, 8)
                    .padding(.top, 8)
                    .disabled(!running && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(minHeight: 34, maxHeight: text.isEmpty ? 42 : 108, alignment: .top)
            .background(Theme.backgroundInput)
            .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5.5) {
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
        if !appState.pendingPermissions.isEmpty {
            ZStack(alignment: .top) {
                Color.black.opacity(0.55).ignoresSafeArea().onTapGesture {}
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(appState.pendingPermissions) { permission in
                            PermissionDialogView(permission: permission)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 48)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.visible)
            }
        }
    }
}
