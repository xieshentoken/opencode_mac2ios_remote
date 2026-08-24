import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var username = "opencode"
    @State private var password = ""
    @State private var kind: ServerKind = .openCode
    @State private var editingID: String?
    @State private var testing = false
    @State private var testResult = ""
    @State private var testOK = false

    private var mustConnect: Bool { appState.connectionState != .connected }

    var body: some View {
        VStack(spacing: 0) {
            TUIScreenHeader(title: "server settings", detail: "Cloudflare Tunnel / authenticated agent", close: { if !mustConnect { dismiss() } })
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    BorderedBox(title: "connection") {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(connectionDiagram)
                            Text(connectionNote).foregroundStyle(Theme.textMuted)
                        }
                        .font(Theme.monoFont(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                    }

                    section("saved servers")
                    VStack(spacing: 0) {
                        ForEach(appState.servers) { server in serverRow(server) }
                        if appState.servers.isEmpty {
                            Text("~ no saved server")
                                .font(Theme.monoFont(size: 10))
                                .foregroundStyle(Theme.textMuted)
                                .frame(maxWidth: .infinity, minHeight: 42)
                        }
                    }
                    .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))

                    section("add / edit server")
                    VStack(spacing: 7) {
                        Picker("agent", selection: $kind) {
                            ForEach(ServerKind.allCases) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: kind) { _, newKind in
                            if username.isEmpty || username == "opencode" {
                                username = newKind == .openCode ? "opencode" : "admin"
                            }
                        }
                        TUIField(prompt: "name", text: $name)
                        TUIField(prompt: "https://your-tunnel.example.com", text: $url)
                        TUIField(prompt: "username", text: $username)
                        TUIField(prompt: passwordPrompt, text: $password, secure: true)
                    }
                    HStack {
                        Button(testing ? "[ testing... ]" : "[ test ]", action: testConnection)
                            .buttonStyle(TUIButtonStyle(accent: Theme.borderStrong))
                            .disabled(url.isEmpty || testing)
                        Button("[ save + connect ]", action: saveAndConnect)
                            .buttonStyle(TUIButtonStyle(accent: Theme.accent, filled: true))
                            .disabled(name.isEmpty || url.isEmpty || password.isEmpty)
                    }
                    if !testResult.isEmpty {
                        Text(testResult)
                            .font(Theme.monoFont(size: 10))
                            .foregroundStyle(testOK ? Theme.green : Theme.red)
                    }
                }
                .padding(12)
            }
            .scrollDismissesKeyboard(.immediately)
            .onTapGesture { hideKeyboard() }
            StatusBar(path: appState.activeServer?.baseURL ?? "server", connected: appState.connectionState == .connected, version: appState.serverVersion, running: false)
        }
        .background(Theme.background.ignoresSafeArea())
        .dismissKeyboardOnTapOutside()
        .overlay(alignment: .bottom) { PermissionBarOverlay() }
    }

    private func section(_ value: String) -> some View {
        Text("┤ \(value) ├").font(Theme.monoFont(size: 10, weight: .semibold)).foregroundStyle(Theme.textMuted)
    }

    private func serverRow(_ server: ServerConfig) -> some View {
        HStack {
            Text(appState.activeServer?.id == server.id ? ">" : " ").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(server.name) · \(server.kind.displayName)").foregroundStyle(Theme.textPrimary)
                Text(server.baseURL).font(Theme.monoFont(size: 9)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            Spacer()
            Button("[ use ]") {
                appState.switchServer(to: KeychainStore.resolvePassword(for: server))
                dismiss()
            }.buttonStyle(.plain).foregroundStyle(Theme.green)
            Button("[ edit ]") { edit(server) }
                .buttonStyle(.plain).foregroundStyle(Theme.cyan)
            Button("[ x ]") {
                KeychainStore.delete(config: server)
                appState.servers = KeychainStore.storedConfigs()
            }.buttonStyle(.plain).foregroundStyle(Theme.red)
        }
        .font(Theme.monoFont(size: 10))
        .padding(.horizontal, 8)
        .frame(minHeight: 43)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .bottom)
    }

    private func testConnection() {
        testing = true
        testResult = ""
        let draft = draftConfig
        Task {
            do {
                let detail = try await appState.probeServer(draft)
                testOK = true
                testResult = detail
            } catch {
                testOK = false
                testResult = error.localizedDescription
            }
            testing = false
        }
    }

    private func saveAndConnect() {
        let config = draftConfig
        try? KeychainStore.save(config: config)
        appState.servers = KeychainStore.storedConfigs()
        appState.switchServer(to: config)
        if !mustConnect { dismiss() }
    }

    private var draftConfig: ServerConfig {
        ServerConfig(
            id: editingID ?? UUID().uuidString,
            kind: kind,
            name: name,
            baseURL: url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            username: username,
            password: password
        )
    }

    private var connectionDiagram: String {
        "iPhone → Cloudflare Tunnel → \(kind == .openCode ? "opencode serve" : "hermes serve")"
    }

    private var connectionNote: String {
        kind == .openCode
            ? "Quick Tunnel uses REST polling because its SSE body is buffered."
            : "Hermes uses WSS JSON-RPC; a blocked upgrade falls back to read-only history."
    }

    private var passwordPrompt: String {
        kind == .openCode ? "OPENCODE_SERVER_PASSWORD" : "Hermes login password"
    }

    private func edit(_ server: ServerConfig) {
        let resolved = KeychainStore.resolvePassword(for: server)
        editingID = resolved.id
        kind = resolved.kind
        name = resolved.name
        url = resolved.baseURL
        username = resolved.username
        password = resolved.password
    }
}
