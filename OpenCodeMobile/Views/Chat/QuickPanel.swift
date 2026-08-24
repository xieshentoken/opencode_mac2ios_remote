import SwiftUI

struct QuickPanel: View {
    @EnvironmentObject private var appState: AppState
    let kind: QuickPanelKind
    @Binding var composerText: String
    let close: () -> Void
    @State private var page: QuickPanelKind
    @State private var query = ""
    @State private var files: [String] = []
    @State private var browsePath: String? = nil
    @State private var tree: [FileNode] = []
    @State private var searchTask: Task<Void, Never>?

    init(kind: QuickPanelKind, composerText: Binding<String>, close: @escaping () -> Void) {
        self.kind = kind
        self._composerText = composerText
        self.close = close
        self._page = State(initialValue: kind)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("┤ \(title) ├")
                Spacer()
                if page != kind {
                    Button("[ ← ]") { page = kind }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                }
                Button("[ esc ]", action: close).buttonStyle(.plain)
            }
            .font(Theme.monoFont(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 31)
            .background(Theme.backgroundRaised)
            if page == .files {
                VStack(spacing: 5) {
                    TUIField(prompt: "find file, or type a relative path", text: $query)
                        .onChange(of: query) {
                            scheduleFileLookup()
                        }
                        .onSubmit { insertQueryAsFile() }
                        .onChange(of: page) {
                            if page == .files {
                                browsePath = nil
                                query = ""
                                Task { tree = await appState.fileTree(path: nil) }
                            }
                        }
                    HStack(spacing: 6) {
                        Button("[ + insert typed path ]") { insertQueryAsFile() }
                            .buttonStyle(TUIButtonStyle(accent: Theme.accent, filled: true))
                            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                        Text("enter = insert · pick below")
                            .font(Theme.monoFont(size: 9))
                            .foregroundStyle(Theme.textMuted)
                        Spacer()
                    }
                }
                .padding(7)
            }
            ScrollView {
                LazyVStack(spacing: 0) { rows }
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: min(340, max(180, UIScreen.main.bounds.height * 0.45)))
        }
        .background(Theme.background)
        .overlay(Rectangle().stroke(Theme.borderStrong, lineWidth: 1))
        .onDisappear { searchTask?.cancel() }
    }

    @ViewBuilder private var rows: some View {
        switch page {
        case .files:
            filesRows
        case .models:
            modelsRows
        case .agents:
            ForEach(appState.agents.filter { $0.hidden != true }) { agent in
                row("\(agent.name)  \(agent.description ?? "")", selected: agent.id == appState.selectedAgentID) {
                    appState.selectedAgentID = agent.id
                    close()
                }
            }
        case .commands:
            let builtin = appState.commands.filter { $0.source == "command" }
            let skillCommands = appState.commands.filter { $0.source == "skill" }
            VStack(spacing: 0) {
                section("system")
                ForEach(builtin) { command in
                    row("/\(command.name)  \(command.description ?? "")") { insert("/\(command.name) ") }
                }
                row("/plugin") { insert("/plugin ") }
                row("switch theme") { page = .themes }
                row("switch to light mode") { ThemeSettings.shared.setLight(); close() }
                section("agent")
                ForEach(appState.agents.filter { $0.hidden != true }) { agent in
                    row("\(agent.name)  \(agent.description ?? "")", selected: agent.id == appState.selectedAgentID) {
                        appState.selectedAgentID = agent.id
                        close()
                    }
                }
                row("toggle MCPs") {
                    Task { await appState.toggleMCPs() }
                    close()
                }
                section("provider")
                ForEach(appState.providers?.providers ?? []) { provider in
                    row(providerRowLabel(provider), selected: provider.id == appState.selectedModel?.providerID) {
                        if let first = provider.models?.values.first {
                            appState.selectModel(providerID: provider.id, modelID: first.id)
                            close()
                        }
                    }
                }
                if !skillCommands.isEmpty {
                    section("skill")
                    ForEach(skillCommands) { command in
                        row("/\(command.name)  \(command.description ?? "")") { insert("/\(command.name) ") }
                    }
                }
            }
        case .skills:
            ForEach(appState.skills) { skill in
                row("/\(skill.name)  \(skill.description ?? "")") { insert("/\(skill.name) ") }
            }
        case .variants:
            variantsRows
        case .themes:
            ForEach(ThemePalette.all) { theme in
                row(theme.name, selected: theme.id == ThemeSettings.shared.themeID) {
                    ThemeSettings.shared.setTheme(theme.id)
                    close()
                }
            }
        }
    }

    private func providerRowLabel(_ provider: Provider) -> String {
        let models = (provider.models ?? [:]).values
        let first = models.first
        return "\(provider.name ?? provider.id)  ·  \(first?.name ?? first?.id ?? "no models")"
    }

    // MARK: - Reasoning effort (variant) picker

    @ViewBuilder private var variantsRows: some View {
        if let variants = appState.selectedModelVariants, !variants.isEmpty {
            row("Default", selected: appState.selectedVariant == nil) {
                appState.selectedVariant = nil
                close()
            }
            ForEach(variants, id: \.self) { variant in
                row(capitalized(variant), selected: appState.selectedVariant == variant) {
                    appState.selectedVariant = variant
                    close()
                }
            }
        } else {
            VStack(spacing: 6) {
                Text("~ this model has no thinking levels")
                    .font(Theme.monoFont(size: 10))
                    .foregroundStyle(Theme.textMuted)
                Text("variants come from the model's config on the Mac")
                    .font(Theme.monoFont(size: 9))
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
    }

    private func capitalized(_ s: String) -> String {
        s.first.map { String($0).uppercased() + s.dropFirst() } ?? s
    }

    // MARK: - Models: provider chips + that provider's models only

    private var modelsRows: some View {
        let providers = appState.providers?.providers ?? []
        let selectedProviderID = appState.selectedModel?.providerID
        let models = appState.availableModels.filter { $0.provider.id == selectedProviderID }
        return VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(providers) { provider in
                    Button {
                        if let first = provider.models?.values.first {
                            appState.selectModel(providerID: provider.id, modelID: first.id)
                        }
                    } label: {
                        Text(provider.name ?? provider.id)
                            .font(Theme.monoFont(size: 9, weight: provider.id == selectedProviderID ? .bold : .regular))
                            .foregroundStyle(provider.id == selectedProviderID ? Color.black : Theme.textSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .frame(height: 22)
                            .background(provider.id == selectedProviderID ? Theme.robotOrange : Theme.backgroundInput)
                            .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border.opacity(0.45)), alignment: .bottom)
            if models.isEmpty {
                Text("~ no models for this provider")
                    .font(Theme.monoFont(size: 10))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                ForEach(models, id: \.model.id) { item in
                    row(item.model.name ?? item.model.id,
                        selected: item.model.id == appState.selectedModel?.id && item.provider.id == appState.selectedModel?.providerID) {
                        appState.selectModel(providerID: item.provider.id, modelID: item.model.id)
                        close()
                    }
                }
            }
        }
    }

    // MARK: - Files: browse tree + search, relative paths only

    @ViewBuilder private var filesRows: some View {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        if searching {
            ForEach(files, id: \.self) { path in
                if let rel = relativePath(path) {
                    row("@\(rel)") { insertFile(rel) }
                }
            }
        } else {
            ForEach(tree) { node in
                if node.type == "directory" {
                    row("\(node.name)/") { enterDirectory(node.path) }
                } else if let rel = relativePath(node.path) {
                    row("@\(rel)") { insertFile(rel) }
                }
            }
            if !tree.isEmpty {
                row("↑ ..  (workspace root)") {
                    browsePath = nil
                    Task { tree = await appState.fileTree(path: nil) }
                }
            }
        }
    }

    private func enterDirectory(_ path: String) {
        browsePath = path
        Task { tree = await appState.fileTree(path: path) }
    }

    private func scheduleFileLookup() {
        searchTask?.cancel()
        let requestedQuery = query.trimmingCharacters(in: .whitespaces)
        let requestedPath = browsePath
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            if requestedQuery.isEmpty {
                let result = await appState.fileTree(path: requestedPath)
                guard !Task.isCancelled, query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                tree = result
            } else {
                let result = await appState.findFiles(requestedQuery)
                guard !Task.isCancelled, query.trimmingCharacters(in: .whitespaces) == requestedQuery else { return }
                files = result
            }
        }
    }

    /// Insert the typed text as a relative file reference (`@path`).
    /// Reuses the same relative-path guard as the browse results.
    private func insertQueryAsFile() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let rel = relativePath(trimmed) else { return }
        composerText += "@\(rel) "
        close()
    }

    /// Enforce "relative path only": drop absolute paths, parent traversal,
    /// and any path escaping the workspace root.
    private func relativePath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        let components = trimmed.split(separator: "/")
        guard !components.contains(where: { $0 == ".." }) else { return nil }
        guard !components.contains(where: { $0 == "~" }) else { return nil }
        return components.joined(separator: "/")
    }

    private func insertFile(_ relative: String) {
        composerText += "@\(relative) "
        close()
    }

    private func section(_ value: String) -> some View {
        Text("┤ \(value) ├")
            .font(Theme.monoFont(size: 9, weight: .semibold))
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .background(Theme.backgroundInput)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border.opacity(0.45)), alignment: .bottom)
    }

    private func row(_ label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("> \(label)")
                .font(Theme.monoFont(size: 10, weight: selected ? .bold : .regular))
                .foregroundStyle(selected ? Color.black : Theme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Theme.robotOrange : Color.clear)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border.opacity(0.45)), alignment: .bottom)
    }

    private func insert(_ value: String) {
        composerText += value
        close()
    }

    private var title: String {
        switch page {
        case .files: return "files"
        case .models: return "models / providers"
        case .agents: return "agents"
        case .commands: return "commands / ctrl+p"
        case .skills: return "skills"
        case .variants: return "thinking level"
        case .themes: return "themes"
        }
    }
}
