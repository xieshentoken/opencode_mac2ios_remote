import SwiftUI
import Observation

// MARK: - Theme palette

struct ThemePalette {
    let isLight: Bool
    let background: Color
    let backgroundRaised: Color
    let backgroundInput: Color
    let selection: Color
    let border: Color
    let borderStrong: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let accent: Color
    let green: Color
    let yellow: Color
    let red: Color
    let magenta: Color
    let cyan: Color
    let orange: Color
}

struct ThemeDefinition: Identifiable {
    let id: String
    let name: String
    let palette: ThemePalette
}

extension ThemePalette {
    static let opencode = ThemePalette(
        isLight: false,
        background: Color.black,
        backgroundRaised: Color(red: 0.075, green: 0.075, blue: 0.075),
        backgroundInput: Color(red: 0.12, green: 0.12, blue: 0.12),
        selection: Color(red: 0.18, green: 0.18, blue: 0.18),
        border: Color(red: 0.22, green: 0.22, blue: 0.22),
        borderStrong: Color(red: 0.42, green: 0.42, blue: 0.42),
        textPrimary: Color(red: 0.88, green: 0.88, blue: 0.88),
        textSecondary: Color(red: 0.58, green: 0.58, blue: 0.58),
        textMuted: Color(red: 0.36, green: 0.36, blue: 0.36),
        accent: Color(red: 0.42, green: 0.65, blue: 1.0),
        green: Color(red: 0.48, green: 0.78, blue: 0.52),
        yellow: Color(red: 0.91, green: 0.74, blue: 0.35),
        red: Color(red: 0.92, green: 0.38, blue: 0.38),
        magenta: Color(red: 0.82, green: 0.55, blue: 0.92),
        cyan: Color(red: 0.44, green: 0.78, blue: 0.82),
        orange: Color(red: 0.94, green: 0.61, blue: 0.29)
    )

    static let light = ThemePalette(
        isLight: true,
        background: Color(red: 0.97, green: 0.97, blue: 0.97),
        backgroundRaised: Color(red: 0.92, green: 0.92, blue: 0.92),
        backgroundInput: Color(red: 0.87, green: 0.87, blue: 0.87),
        selection: Color(red: 0.8, green: 0.8, blue: 0.8),
        border: Color(red: 0.72, green: 0.72, blue: 0.72),
        borderStrong: Color(red: 0.5, green: 0.5, blue: 0.5),
        textPrimary: Color(red: 0.13, green: 0.13, blue: 0.13),
        textSecondary: Color(red: 0.38, green: 0.38, blue: 0.38),
        textMuted: Color(red: 0.55, green: 0.55, blue: 0.55),
        accent: Color(red: 0.15, green: 0.45, blue: 0.9),
        green: Color(red: 0.2, green: 0.55, blue: 0.3),
        yellow: Color(red: 0.7, green: 0.5, blue: 0.1),
        red: Color(red: 0.8, green: 0.2, blue: 0.2),
        magenta: Color(red: 0.65, green: 0.3, blue: 0.8),
        cyan: Color(red: 0.1, green: 0.55, blue: 0.6),
        orange: Color(red: 0.85, green: 0.45, blue: 0.1)
    )

    static let dracula = ThemePalette(
        isLight: false,
        background: Color(red: 0.09, green: 0.09, blue: 0.13),
        backgroundRaised: Color(red: 0.13, green: 0.14, blue: 0.19),
        backgroundInput: Color(red: 0.17, green: 0.18, blue: 0.24),
        selection: Color(red: 0.23, green: 0.23, blue: 0.32),
        border: Color(red: 0.27, green: 0.28, blue: 0.37),
        borderStrong: Color(red: 0.46, green: 0.47, blue: 0.6),
        textPrimary: Color(red: 0.93, green: 0.93, blue: 0.96),
        textSecondary: Color(red: 0.62, green: 0.63, blue: 0.72),
        textMuted: Color(red: 0.42, green: 0.43, blue: 0.52),
        accent: Color(red: 0.95, green: 0.55, blue: 0.76),
        green: Color(red: 0.4, green: 0.9, blue: 0.6),
        yellow: Color(red: 0.9, green: 0.78, blue: 0.4),
        red: Color(red: 1.0, green: 0.5, blue: 0.5),
        magenta: Color(red: 0.9, green: 0.6, blue: 0.96),
        cyan: Color(red: 0.5, green: 0.86, blue: 0.9),
        orange: Color(red: 0.96, green: 0.68, blue: 0.4)
    )

    static let monokai = ThemePalette(
        isLight: false,
        background: Color(red: 0.13, green: 0.13, blue: 0.12),
        backgroundRaised: Color(red: 0.17, green: 0.17, blue: 0.15),
        backgroundInput: Color(red: 0.21, green: 0.2, blue: 0.18),
        selection: Color(red: 0.27, green: 0.26, blue: 0.23),
        border: Color(red: 0.33, green: 0.32, blue: 0.29),
        borderStrong: Color(red: 0.51, green: 0.5, blue: 0.45),
        textPrimary: Color(red: 0.94, green: 0.92, blue: 0.87),
        textSecondary: Color(red: 0.68, green: 0.65, blue: 0.6),
        textMuted: Color(red: 0.46, green: 0.44, blue: 0.4),
        accent: Color(red: 0.93, green: 0.83, blue: 0.38),
        green: Color(red: 0.67, green: 0.88, blue: 0.35),
        yellow: Color(red: 0.93, green: 0.83, blue: 0.38),
        red: Color(red: 0.98, green: 0.5, blue: 0.47),
        magenta: Color(red: 0.87, green: 0.53, blue: 0.8),
        cyan: Color(red: 0.57, green: 0.85, blue: 0.85),
        orange: Color(red: 0.98, green: 0.66, blue: 0.35)
    )

    static let tokyonight = ThemePalette(
        isLight: false,
        background: Color(red: 0.09, green: 0.11, blue: 0.18),
        backgroundRaised: Color(red: 0.13, green: 0.15, blue: 0.23),
        backgroundInput: Color(red: 0.17, green: 0.19, blue: 0.28),
        selection: Color(red: 0.23, green: 0.26, blue: 0.36),
        border: Color(red: 0.27, green: 0.3, blue: 0.42),
        borderStrong: Color(red: 0.45, green: 0.48, blue: 0.62),
        textPrimary: Color(red: 0.84, green: 0.87, blue: 0.96),
        textSecondary: Color(red: 0.6, green: 0.64, blue: 0.78),
        textMuted: Color(red: 0.42, green: 0.46, blue: 0.6),
        accent: Color(red: 0.5, green: 0.65, blue: 0.96),
        green: Color(red: 0.55, green: 0.82, blue: 0.75),
        yellow: Color(red: 0.9, green: 0.78, blue: 0.55),
        red: Color(red: 0.92, green: 0.5, blue: 0.62),
        magenta: Color(red: 0.75, green: 0.62, blue: 0.92),
        cyan: Color(red: 0.5, green: 0.82, blue: 0.9),
        orange: Color(red: 0.96, green: 0.65, blue: 0.4)
    )

    static let all: [ThemeDefinition] = [
        ThemeDefinition(id: "opencode", name: "opencode", palette: .opencode),
        ThemeDefinition(id: "light", name: "light", palette: .light),
        ThemeDefinition(id: "dracula", name: "dracula", palette: .dracula),
        ThemeDefinition(id: "monokai", name: "monokai", palette: .monokai),
        ThemeDefinition(id: "tokyonight", name: "tokyonight", palette: .tokyonight)
    ]

    static func forID(_ id: String) -> ThemePalette {
        all.first { $0.id == id }?.palette ?? .opencode
    }

    var diffAdd: Color { isLight ? Color(red: 0.2, green: 0.5, blue: 0.3) : Color(red: 0.24, green: 0.47, blue: 0.29) }
    var diffDel: Color { isLight ? Color(red: 0.75, green: 0.3, blue: 0.3) : Color(red: 0.52, green: 0.25, blue: 0.25) }
    var diffBgAdd: Color { isLight ? Color(red: 0.85, green: 0.95, blue: 0.87).opacity(0.6) : Color(red: 0.10, green: 0.22, blue: 0.13).opacity(0.5) }
    var diffBgDel: Color { isLight ? Color(red: 0.97, green: 0.87, blue: 0.87).opacity(0.6) : Color(red: 0.25, green: 0.08, blue: 0.08).opacity(0.5) }
}

// MARK: - Theme settings

/// App-wide theme selection. Views read `Theme.*` (computed from this) during
/// body evaluation, so a theme change re-renders everything.
@Observable
final class ThemeSettings {
    static let shared = ThemeSettings()
    private let key = "themeID"

    var themeID: String {
        get { UserDefaults.standard.string(forKey: key) ?? "opencode" }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    var palette: ThemePalette { ThemePalette.forID(themeID) }
    var isLight: Bool { palette.isLight }

    func setTheme(_ id: String) { themeID = id }
    func toggle() { setTheme(isLight ? "opencode" : "light") }
    func setLight() { setTheme("light") }
}

// MARK: - Palette accessors

enum Theme {
    static var palette: ThemePalette { ThemeSettings.shared.palette }

    static var background: Color { palette.background }
    static var backgroundRaised: Color { palette.backgroundRaised }
    static var backgroundInput: Color { palette.backgroundInput }
    static var selection: Color { palette.selection }
    static var border: Color { palette.border }
    static var borderStrong: Color { palette.borderStrong }
    static var textPrimary: Color { palette.textPrimary }
    static var textSecondary: Color { palette.textSecondary }
    static var textMuted: Color { palette.textMuted }
    static var accent: Color { palette.accent }
    static var green: Color { palette.green }
    static var yellow: Color { palette.yellow }
    static var red: Color { palette.red }
    static var magenta: Color { palette.magenta }
    static var cyan: Color { palette.cyan }
    static var orange: Color { palette.orange }

    /// The robot's pixel orange; used for selection highlights.
    static var robotOrange: Color { Color(red: 0.85, green: 0.47, blue: 0.34) }

    static var diffAdd: Color { palette.diffAdd }
    static var diffDel: Color { palette.diffDel }
    static var diffBgAdd: Color { palette.diffBgAdd }
    static var diffBgDel: Color { palette.diffBgDel }

    static var mono = "SF Mono"
    static var monoFallback = "Menlo"

    static func monoFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if UIFont(name: mono, size: size) != nil {
            return .custom(mono, size: size).weight(weight)
        }
        return .custom(monoFallback, size: size).weight(weight)
    }
}

struct BorderedBox<Content: View>: View {
    let title: String?
    let color: Color
    let content: Content

    init(title: String? = nil, color: Color = Theme.border, @ViewBuilder content: () -> Content) {
        self.title = title
        self.color = color
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text("┤ \(title) ├")
                    .font(Theme.monoFont(size: 10, weight: .semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.top, 5)
            }
            content.padding(8)
        }
        .background(Theme.backgroundRaised)
        .overlay(Rectangle().stroke(color, lineWidth: 1))
    }
}

struct TUIButtonStyle: ButtonStyle {
    var accent: Color = Theme.borderStrong
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.monoFont(size: 11, weight: .semibold))
            .foregroundStyle(filled ? Theme.background : (configuration.isPressed ? Theme.textPrimary : accent))
            .padding(.horizontal, 9)
            .frame(minHeight: 30)
            .background(filled ? accent : (configuration.isPressed ? Theme.selection : Theme.backgroundRaised))
            .overlay(Rectangle().stroke(accent, lineWidth: 1))
    }
}

struct TUIField: View {
    let prompt: String
    @Binding var text: String
    var secure = false

    var body: some View {
        Group {
            if secure {
                SecureField(prompt, text: $text)
            } else {
                TextField(prompt, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .font(Theme.monoFont(size: 12))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(Theme.backgroundInput)
        .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
    }
}

struct TUIScreenHeader: View {
    let title: String
    var detail: String? = nil
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("┌")
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(Theme.textPrimary)
                if let detail { Text(detail).font(Theme.monoFont(size: 9)).foregroundStyle(Theme.textMuted) }
            }
            Spacer()
            Button("[ esc ]", action: close)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
            Text("┐")
        }
        .font(Theme.monoFont(size: 11, weight: .semibold))
        .padding(.horizontal, 10)
        .frame(height: 45)
        .background(Theme.backgroundRaised)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .bottom)
    }
}

struct StatusBar: View {
    let path: String
    let connected: Bool
    let version: String?
    let running: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(shortPath)
                .lineLimit(1)
            Spacer()
            Text(running ? "● running" : (connected ? "● connected" : "○ offline"))
                .foregroundStyle(running ? Theme.yellow : (connected ? Theme.green : Theme.red))
            Text(version ?? "—")
        }
        .font(Theme.monoFont(size: 9))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 9)
        .frame(height: 25)
        .background(Theme.background)
    }

    private var shortPath: String {
        guard path.count > 28 else { return path.isEmpty ? "~" : path }
        return "…" + path.suffix(27)
    }
}
