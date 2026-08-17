import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @State private var composerText = ""
    @State private var showingSessions = false
    @State private var showingProjects = false
    @State private var showingProviderKeys = false
    @State private var showingSettings = false
    @State private var showingNewProject = false
    @State private var showingMenu = false
    @State private var quickPanel: QuickPanelKind?
    @FocusState private var composerFocused: Bool
    @State private var keyboardHeight: CGFloat = 0
    @State private var keyboardObservers: [NSObjectProtocol] = []

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { composerFocused = false }
            VStack(spacing: 0) {
                compactHeader
                if appState.messages.isEmpty {
                    emptyState
                } else {
                    transcript
                    composer
                }
                StatusBar(
                    path: appState.activeSession?.directory ?? appState.activeDirectory ?? "~",
                    connected: appState.connectionState == .connected,
                    version: appState.serverVersion,
                    running: appState.activeSessionRunning
                )
            }
            .padding(.bottom, keyboardHeight == 0 ? 0 : keyboardHeight)
            if showingMenu || quickPanel != nil {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismissSubmenus() }
                    .zIndex(1)
            }
            if showingMenu { headerMenu }
        }
        .background(Theme.background.ignoresSafeArea())
        .ignoresSafeArea(.keyboard)
        .overlay(alignment: .bottom) {
            if let quickPanel {
                QuickPanel(kind: quickPanel, composerText: $composerText) {
                    self.quickPanel = nil
                }
                .environmentObject(appState)
                .padding(.horizontal, 8)
                .padding(.bottom, 27)
                .transition(.move(edge: .bottom))
            }
        }
        .fullScreenCover(isPresented: $showingSessions) { SessionListView() }
        .fullScreenCover(isPresented: $showingProjects) { ProjectListView() }
        .fullScreenCover(isPresented: $showingProviderKeys) { ProviderKeyView() }
        .fullScreenCover(isPresented: $showingSettings) { SettingsView() }
        .fullScreenCover(isPresented: $showingNewProject) { NewProjectView() }
        .overlay(alignment: .top) { PermissionBanner() }
        .onAppear { observeKeyboard() }
        .onDisappear { keyboardObservers = [] }
    }

    /// Track the keyboard so the transcript keeps its height while the
    /// composer rises above the keyboard (default avoidance would compress
    /// the ScrollView and hide the last messages behind the composer).
    private func observeKeyboard() {
        let center = NotificationCenter.default
        keyboardObservers = [
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { note in
                let h = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
                withAnimation(.easeOut(duration: 0.22)) { keyboardHeight = h }
            },
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
                withAnimation(.easeOut(duration: 0.22)) { keyboardHeight = 0 }
            },
        ]
    }

    private func dismissSubmenus() {
        showingMenu = false
        quickPanel = nil
    }

    private var compactHeader: some View {
        HStack(spacing: 8) {
            PixelRobot(rendered: appState.renderedMarkdown)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
                .onTapGesture { appState.renderedMarkdown.toggle() }
                .onLongPressGesture(minimumDuration: 0.5) { showingSessions = true }
            Button { showingProviderKeys = true } label: {
                PixelWordmark().frame(width: 88, height: 23)
            }
            .buttonStyle(.plain)
            Rectangle().fill(Theme.border).frame(width: 1, height: 25)
            VStack(alignment: .leading, spacing: 1) {
                Text(projectName)
                    .font(Theme.monoFont(size: 9))
                    .foregroundStyle(Theme.textMuted)
                Text(sessionTitle)
                    .font(Theme.monoFont(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            Button("[ + ]") { showingNewProject = true }
                .buttonStyle(.plain)
            Button("[ : ]") { showingMenu.toggle() }
                .buttonStyle(.plain)
        }
        .font(Theme.monoFont(size: 10))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 9)
        .frame(height: 44)
        .background(Theme.background)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .bottom)
    }

    private var headerMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuButton("switch session") { showingSessions = true }
            menuButton("switch project") { showingProjects = true }
            menuButton("new session") { Task { await appState.createSession() } }
            menuButton("new project") { showingNewProject = true }
            menuButton("server settings") { showingSettings = true }
        }
        .frame(width: 170)
        .background(Theme.backgroundRaised)
        .overlay(Rectangle().stroke(Theme.borderStrong, lineWidth: 1))
        .padding(.top, 42)
        .padding(.trailing, 8)
        .zIndex(8)
    }

    private func menuButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            showingMenu = false
            action()
        } label: {
            Text("> \(label)")
                .font(Theme.monoFont(size: 10))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        GeometryReader { proxy in
            VStack(spacing: 12) {
                Spacer().frame(height: max(28, proxy.size.height * 0.14))
                HStack(spacing: 9) {
                    Button { showingSessions = true } label: {
                        PixelRobot().frame(width: 75, height: 66)
                    }.buttonStyle(.plain)
                    Button { showingProviderKeys = true } label: {
                        PixelWordmark().frame(maxWidth: 235).frame(height: 58)
                    }.buttonStyle(.plain)
                }
                composer
                Spacer()
            }
            .padding(.horizontal, 13)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        Color.clear.frame(height: 1).id("top")
                        ForEach(appState.messages) { message in
                            MessageRow(message: message).id(message.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                }
                .scrollDismissesKeyboard(.immediately)
                .onTapGesture { composerFocused = false }
                .onChange(of: appState.messages.count) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: transcriptLength) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: appState.activeSessionID) {
                    scrollToBottom(proxy)
                }
                .onChange(of: keyboardHeight) {
                    // The viewport shrinks as the layout is padded up by the
                    // keyboard, and the ScrollView keeps its contentOffset, so
                    // the visible window would slide up into older messages.
                    // Re-pin to the bottom once the animation settles so the
                    // newest content stays visible right above the keyboard.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }

                VStack(spacing: 4) {
                    arrowButton(.up) { withAnimation { proxy.scrollTo("top", anchor: .top) } }
                    arrowButton(.down) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .padding(.trailing, 7)
            }
            .onAppear { scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private func arrowButton(_ direction: PixelArrow.Direction, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PixelArrow(direction: direction, color: Theme.textSecondary)
                .frame(width: 13, height: 23)
        }
        .buttonStyle(.plain)
        .padding(3)
        .background(Theme.backgroundRaised.opacity(0.92))
        .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
    }

    private var transcriptLength: Int {
        appState.messages.reduce(0) { $0 + ($1.parts?.reduce(0) { $0 + ($1.text?.count ?? 0) } ?? 0) }
    }

    private var composer: some View {
        ComposerView(
            text: $composerText,
            focused: $composerFocused,
            running: appState.activeSessionRunning,
            model: modelLabel,
            agent: appState.selectedAgentID,
            variant: appState.selectedVariant,
            onOpen: { quickPanel = $0 },
            onToggleMode: toggleMode,
            onSend: send,
            onAbort: { Task { await appState.abortSession() } }
        )
        .padding(.horizontal, appState.messages.isEmpty ? 0 : 8)
        .padding(.vertical, appState.messages.isEmpty ? 0 : 7)
    }

    private var modelLabel: String {
        let id = appState.selectedModel?.id
        return appState.availableModels.first(where: { $0.model.id == id })?.model.name ?? id ?? "model"
    }

    private func toggleMode() {
        appState.selectedAgentID = appState.selectedAgentID == "plan" ? "build" : "plan"
    }

    private func send() {
        let text = composerText
        composerText = ""
        quickPanel = nil
        Task { await appState.sendPrompt(text) }
    }

    private var sessionTitle: String {
        if let title = appState.activeSession?.title, !title.isEmpty { return title }
        return appState.activeSession?.slug ?? "new session"
    }

    private var projectName: String {
        let path = appState.activeSession?.directory ?? appState.activeDirectory ?? "~"
        return URL(fileURLWithPath: path).lastPathComponent.isEmpty ? "~" : URL(fileURLWithPath: path).lastPathComponent
    }
}
