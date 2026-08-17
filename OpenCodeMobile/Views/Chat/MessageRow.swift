import SwiftUI

// MARK: - Message row

struct MessageRow: View {
    let message: Message

    private var isUser: Bool { message.info.role == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Rectangle()
                .fill(isUser ? Theme.green : Theme.accent)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(isUser ? "you" : (message.info.modelID ?? "assistant"))
                        .font(Theme.monoFont(size: 10, weight: .semibold))
                        .foregroundColor(isUser ? Theme.green : Theme.accent)
                    Text(relativeTime)
                        .font(Theme.monoFont(size: 9))
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                    if message.info.error != nil {
                        Text("[ error ]").foregroundColor(Theme.red)
                    }
                }
                ForEach(message.parts ?? []) { part in PartRow(part: part) }
            }
            .padding(.vertical, 8)
            .padding(.trailing, 4)
        }
        .background(isUser ? Theme.backgroundRaised.opacity(0.6) : Theme.background)
        .overlay(
            Rectangle().frame(height: 1).foregroundStyle(Theme.border.opacity(0.45)),
            alignment: .bottom
        )
    }

    private var relativeTime: String {
        guard let created = message.info.time?.created else { return "" }
        let date = Date(timeIntervalSince1970: Double(created) / 1000)
        return date.formatted(.dateTime.hour().minute())
    }
}

// MARK: - Part row

struct PartRow: View {
    @EnvironmentObject private var appState: AppState
    let part: Part

    var body: some View {
        switch part.type {
        case "text":
            if let text = part.text, !text.isEmpty {
                MarkdownText(text: text, rendered: appState.renderedMarkdown)
            }
        case "reasoning":
            if let text = part.text, !text.isEmpty {
                ReasoningBlock(text: text)
            }
        case "tool":
            ToolCallBlock(part: part)
        case "step-start":
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.yellow)
                Text("step started")
                    .font(Theme.monoFont(size: 10))
                    .foregroundColor(Theme.textMuted)
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - Tool call block

struct ToolCallBlock: View {
    let part: Part
    @State private var expanded = false

    private var stateColor: Color {
        switch part.state {
        case .running, .loading: return Theme.yellow
        case .completed: return Theme.green
        case .error: return Theme.red
        case .accepted: return Theme.green
        case .rejected: return Theme.red
        default: return Theme.borderStrong
        }
    }

    private var stateLabel: String {
        switch part.state {
        case .running, .loading: return "running"
        case .completed, .accepted: return "completed"
        case .error: return "failed"
        case .rejected: return "rejected"
        default: return "pending"
        }
    }

    var body: some View {
        BorderedBox(title: "\(part.tool ?? "tool") — \(stateLabel)", color: stateColor) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if part.state == .running || part.state == .loading {
                        ProgressView().controlSize(.mini).tint(Theme.yellow)
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    Text(callIDShort)
                        .font(Theme.monoFont(size: 9))
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                    if let progress = part.progress, progress.total ?? 0 > 0 {
                        Text("\(progress.current ?? 0)/\(progress.total ?? 0)")
                            .font(Theme.monoFont(size: 9))
                            .foregroundColor(Theme.textMuted)
                    }
                }
                if expanded {
                    if let input = part.input {
                        JSONPreview(title: "input", value: input)
                    }
                    if let output = part.output {
                        JSONPreview(title: "output", value: output)
                    }
                }
            }
        }
    }

    private var callIDShort: String {
        let id = part.callID ?? ""
        return id.count > 12 ? String(id.prefix(12)) + "…" : id
    }
}

// MARK: - JSON preview

struct JSONPreview: View {
    let title: String
    let value: JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.monoFont(size: 9, weight: .bold))
                .foregroundColor(Theme.textMuted)
            CollapsingText(text: pretty, prefix: "…")
                .font(Theme.monoFont(size: 10))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private var pretty: String {
        guard let data = try? JSONSerialization.data(withJSONObject: value.anyValue, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}

// MARK: - Reasoning block (tap to expand / collapse)

struct ReasoningBlock: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("reasoning")
                        .font(Theme.monoFont(size: 10, weight: .semibold))
                    if !expanded {
                        Text(oneLine)
                            .font(Theme.monoFont(size: 9))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .foregroundColor(Theme.textMuted)
                .contentShape(Rectangle())
            }
            .buttonStyle(BorderlessButtonStyle())
            if expanded {
                Text(text)
                    .font(Theme.monoFont(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { expanded = false } }
            }
        }
        .padding(8)
        .background(Theme.backgroundInput)
        .overlay(Rectangle().stroke(Theme.textMuted.opacity(0.5), lineWidth: 1))
    }

    private var oneLine: String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 64 ? String(flat.prefix(63)) + "…" : flat
    }
}

// MARK: - Collapsing text (truncated with expand)

struct CollapsingText: View {
    let text: String
    let prefix: String
    @State private var expanded = false
    private let collapseLimit = 180

    var body: some View {
        Group {
            if expanded || text.count <= collapseLimit {
                Text(text)
                    .textSelection(.enabled)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(text.prefix(collapseLimit)))
                    Text(prefix)
                }
                .onTapGesture { withAnimation { expanded = true } }
            }
        }
    }
}
