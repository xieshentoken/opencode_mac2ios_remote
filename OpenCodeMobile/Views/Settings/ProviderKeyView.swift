import SwiftUI

struct ProviderKeyView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var customProviderID = ""
    @State private var customBaseURL = ""
    @State private var customKey = ""
    @State private var customSaving = false
    @State private var customStatus = ""

    /// Common API-key providers. `id` matches opencode's built-in provider
    /// IDs (verified via GET /provider); `url` is the open platform's API
    /// base URL, auto-filled when a preset is selected.
    private static let presets: [(id: String, name: String, url: String)] = [
        ("anthropic", "Anthropic", "https://api.anthropic.com"),
        ("openai", "OpenAI", "https://api.openai.com/v1"),
        ("xai", "xAI", "https://api.x.ai/v1"),
        ("google", "Gemini", "https://generativelanguage.googleapis.com/v1beta"),
        ("moonshotai", "Moonshot", "https://api.moonshot.ai/v1"),
        ("zhipuai", "GLM", "https://open.bigmodel.cn/api/paas/v4"),
        ("alibaba", "Qwen", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
        ("deepseek", "DeepSeek", "https://api.deepseek.com"),
        ("opencode", "OpenCode Zen", "https://opencode.ai/zen/v1"),
        ("opencode-go", "OpenCode Go", "https://opencode.ai/zen/go/v1"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TUIScreenHeader(title: "provider / api keys", detail: "stored by opencode on the Mac", close: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PixelWordmark()
                        .frame(maxWidth: 260)
                        .frame(height: 58)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)

                    Text("providers (from the Mac's real config)")
                        .font(Theme.monoFont(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                    VStack(spacing: 0) {
                        ForEach(appState.providers?.providers ?? []) { provider in
                            ProviderKeyRow(provider: provider, usageURL: usageURL(for: provider.id)) {
                                Task { await appState.deleteAPIKey(providerID: provider.id) }
                            }
                        }
                    }
                    .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
                    if appState.providers?.providers?.isEmpty != false {
                        Text("~ no providers configured on the Mac")
                            .font(Theme.monoFont(size: 10))
                            .foregroundStyle(Theme.textMuted)
                            .frame(maxWidth: .infinity, minHeight: 42)
                    }

                    usageBox

                    Text("┤ add provider (custom api key) ├")
                        .font(Theme.monoFont(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            ForEach(Self.presets, id: \.id) { preset in
                                Button(preset.name) {
                                    customProviderID = preset.id
                                    customBaseURL = preset.url
                                    customStatus = ""
                                }
                                .buttonStyle(.plain)
                                .font(Theme.monoFont(size: 9))
                                .foregroundStyle(customProviderID == preset.id ? Color.black : Theme.textSecondary)
                                .padding(.horizontal, 6)
                                .frame(height: 22)
                                .background(customProviderID == preset.id ? Theme.robotOrange : Theme.backgroundInput)
                                .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
                            }
                        }
                        TUIField(prompt: "provider id (e.g. mistral, groq)", text: $customProviderID)
                        TUIField(prompt: "api platform base url", text: $customBaseURL)
                        TUIField(prompt: "api key", text: $customKey, secure: true)
                        HStack {
                            Button(customSaving ? "[ saving... ]" : "[ + add provider ]") { saveCustom() }
                                .buttonStyle(TUIButtonStyle(accent: Theme.accent, filled: true))
                                .disabled(customProviderID.trimmingCharacters(in: .whitespaces).isEmpty || customKey.isEmpty || customSaving)
                            if !customStatus.isEmpty {
                                Text(customStatus)
                                    .font(Theme.monoFont(size: 10))
                                    .foregroundStyle(customStatus == "saved" ? Theme.green : Theme.red)
                            }
                        }
                        Text("key + base url stored by opencode on the Mac; the provider appears here and in the model picker. A serve restart makes the list authoritative.")
                            .font(Theme.monoFont(size: 9))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .padding(9)
                    .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
                }
                .padding(12)
            }
            .scrollDismissesKeyboard(.immediately)
            .onTapGesture { hideKeyboard() }
            StatusBar(
                path: appState.activeServer?.baseURL ?? "server",
                connected: appState.connectionState == .connected,
                version: appState.serverVersion,
                running: false
            )
        }
        .background(Theme.background.ignoresSafeArea())
        .dismissKeyboardOnTapOutside()
        .onAppear {
            if customProviderID.isEmpty {
                customProviderID = appState.selectedModel?.providerID ?? ""
            }
            Task { await appState.refreshSessions() }
        }
    }

    /// Per-provider token/cost totals, shown in a box under the key list.
    private var usageBox: some View {
        let usage = appState.providerUsage
        let known = appState.providers?.providers ?? []
        let rows = known.filter { usage[$0.id] != nil }
        let totalCost = rows.reduce(0.0) { $0 + (usage[$1.id]?.cost ?? 0) }
        let totalIn = rows.reduce(0) { $0 + (usage[$1.id]?.input ?? 0) }
        let totalOut = rows.reduce(0) { $0 + (usage[$1.id]?.output ?? 0) }
        return VStack(alignment: .leading, spacing: 3) {
            Text("┤ tokens used / provider ├")
                .font(Theme.monoFont(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
            if rows.isEmpty {
                Text("~ no usage yet")
                    .font(Theme.monoFont(size: 10))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 26)
            } else {
                ForEach(rows, id: \.id) { provider in
                    if let u = usage[provider.id] {
                        HStack {
                            Text(provider.name ?? provider.id)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("\(fmt(u.input)) in · \(fmt(u.output)) out · $\(String(format: "%.4f", u.cost))")
                                .foregroundStyle(Theme.textMuted)
                        }
                        .font(Theme.monoFont(size: 10))
                        .padding(.vertical, 2)
                    }
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack {
                    Text("total")
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(fmt(totalIn)) in · \(fmt(totalOut)) out · $\(String(format: "%.4f", totalCost))")
                        .foregroundStyle(Theme.textPrimary)
                }
                .font(Theme.monoFont(size: 10, weight: .bold))
                .padding(.vertical, 2)
            }
        }
        .padding(9)
        .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
    }

    private func fmt(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000)
        : n >= 1_000 ? String(format: "%.1fK", Double(n) / 1_000)
        : "\(n)"
    }

    /// Deep link to each platform's usage/billing page. opencode serve has
    /// no balance API; these are the official consoles. nil = no known page.
    private func usageURL(for providerID: String) -> URL? {
        switch providerID {
        case "opencode", "opencode-go":
            return URL(string: "https://opencode.ai/workspace")
        case "anthropic":
            return URL(string: "https://console.anthropic.com/settings/usage")
        case "openai":
            return URL(string: "https://platform.openai.com/usage")
        case "xai":
            return URL(string: "https://console.x.ai/account/usage")
        case "google":
            return URL(string: "https://aistudio.google.com/usage")
        case "moonshotai":
            return URL(string: "https://platform.moonshot.ai/usage")
        case "zhipuai":
            return URL(string: "https://open.bigmodel.cn/console/overview")
        case "alibaba":
            return URL(string: "https://dashscope.console.aliyun.com/usage")
        case "deepseek":
            return URL(string: "https://platform.deepseek.com/usage")
        default:
            return nil
        }
    }

    private func saveCustom() {
        let id = customProviderID.trimmingCharacters(in: .whitespaces)
        let url = customBaseURL.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !customKey.isEmpty else { return }
        customSaving = true
        customStatus = ""
        Task {
            do {
                try await appState.saveAPIKey(providerID: id, key: customKey, baseURL: url.isEmpty ? nil : url)
                customStatus = "saved"
                customKey = ""
            } catch {
                customStatus = error.localizedDescription
            }
            customSaving = false
        }
    }
}

private struct ProviderKeyRow: View {
    let provider: Provider
    let usageURL: URL?
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName).foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.monoFont(size: 9))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            if let usageURL {
                Link("[ used ]", destination: usageURL)
                    .font(Theme.monoFont(size: 10))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(provider.key == nil ? "[ key ]" : "[ set ]")
                .foregroundStyle(provider.key == nil ? Theme.textMuted : Theme.green)
            Button("[ del ]") { onDelete() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.red)
                .disabled(provider.key == nil)
        }
        .font(Theme.monoFont(size: 11))
        .padding(.horizontal, 9)
        .frame(minHeight: 43)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .bottom)
    }

    private var displayName: String { provider.name ?? provider.id }
    private var detail: String {
        let models = (provider.models ?? [:]).count
        return "\(provider.id) · \(provider.source ?? "unknown") · \(models) models"
    }
}
