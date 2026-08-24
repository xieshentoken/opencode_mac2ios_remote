import SwiftUI

// MARK: - Markdown rendering

/// Two display modes for assistant output:
/// - `rendered == false`: the legacy lightweight source view (code fences +
///   inline code styled, everything else as-is). This is the DEFAULT.
/// - `rendered == true`: block-level Markdown renderer. Handles headings,
///   lists, quotes, code fences, bold/italic/inline code AND pipe tables
///   (GFM — the system `AttributedString(markdown:)` does NOT support tables
///   and collapses single newlines, so we parse blocks ourselves).
struct MarkdownText: View {
    let text: String
    var rendered: Bool = false

    var body: some View {
        Group {
            if rendered {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(attributed)
                    .font(Theme.monoFont(size: 13))
                    .foregroundColor(Theme.textPrimary)
            }
        }
        .textSelection(.enabled)
    }

    // MARK: - Block parsing

    private enum Block: Hashable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([String])
        case quote(String)
        case code([String])
        case table(headers: [String], rows: [[String]])
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCode = false
        var tableBuffer: [String] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        func flushParagraph() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        func flushTable() {
            if tableBuffer.count >= 2, let t = parseTable(tableBuffer) {
                result.append(.table(headers: t.0, rows: t.1))
            } else if !tableBuffer.isEmpty {
                // Not a real table (missing separator etc.): keep the lines
                // as plain paragraphs instead of dropping them.
                result.append(.paragraph(tableBuffer.joined(separator: "\n")))
            }
            tableBuffer = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inCode {
                if trimmed.hasPrefix("```") {
                    inCode = false
                    result.append(.code(codeLines))
                    codeLines = []
                } else {
                    codeLines.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushParagraph(); flushTable()
                inCode = true
                continue
            }
            if trimmed.hasPrefix("|") || (trimmed.hasSuffix("|") && trimmed.contains("|")) {
                flushParagraph()
                tableBuffer.append(trimmed)
                continue
            }
            if !tableBuffer.isEmpty {
                flushTable()
            }
            if let heading = parseHeading(line) {
                flushParagraph()
                result.append(heading)
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                result.append(.quote(String(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))))
            } else if isListMarker(trimmed) {
                flushParagraph()
                if case .list(var items) = result.last {
                    items.append(stripListMarker(trimmed))
                    result[result.count - 1] = .list(items)
                } else {
                    result.append(.list([stripListMarker(trimmed)]))
                }
            } else if trimmed.isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph(); flushTable()
        if inCode { result.append(.code(codeLines)) }
        return result
    }

    private func parseHeading(_ line: String) -> Block? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return .heading(level: level, text: rest)
    }

    private func isListMarker(_ s: String) -> Bool {
        s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") || s.range(of: #"^\d+[\.\)] "#, options: .regularExpression) != nil
    }

    private func stripListMarker(_ s: String) -> String {
        for prefix in ["- ", "* ", "+ "] where s.hasPrefix(prefix) {
            return String(s.dropFirst(2))
        }
        if let range = s.range(of: #"^\d+[\.\)] "#, options: .regularExpression) {
            return String(s[range.upperBound...])
        }
        return s
    }

    /// Parse a GFM pipe table: `| h1 | h2 |` + `| --- | --- |` + rows.
    private func parseTable(_ lines: [String]) -> (([String], [[String]]))? {
        func cells(_ line: String) -> [String] {
            line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        guard lines.count >= 2 else { return nil }
        let headers = cells(lines[0])
        let separator = lines[1]
        guard separator.contains("-"), headers.count > 0 else { return nil }
        let rows = lines.dropFirst(2).map(cells).filter { $0.count == headers.count }
        return (headers, rows)
    }

    // MARK: - Block views

    @ViewBuilder private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(Theme.monoFont(size: level == 1 ? 15 : (level == 2 ? 14 : 13), weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .padding(.top, level <= 2 ? 4 : 0)
        case .paragraph(let text):
            inline(text)
                .font(Theme.monoFont(size: 13))
                .foregroundColor(Theme.textPrimary)
        case .list(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").font(Theme.monoFont(size: 13)).foregroundColor(Theme.accent)
                        inline(item)
                            .font(Theme.monoFont(size: 13))
                            .foregroundColor(Theme.textPrimary)
                    }
                }
            }
        case .quote(let text):
            HStack(spacing: 0) {
                Rectangle().fill(Theme.borderStrong).frame(width: 2)
                inline(text)
                    .font(Theme.monoFont(size: 12))
                    .foregroundColor(Theme.textMuted)
                    .padding(.leading, 7)
            }
        case .code(let lines):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(Theme.monoFont(size: 12))
                        .foregroundColor(Theme.cyan)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(7)
            .background(Theme.backgroundInput)
            .overlay(Rectangle().stroke(Theme.border.opacity(0.6), lineWidth: 1))
        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
        }
    }

    /// Pipe table rendered in mono with box borders, header highlighted.
    private func tableView(headers: [String], rows: [[String]]) -> some View {
        let all = [headers] + rows
        let widths = headers.indices.map { col in
            all.map { $0[col].count }.max() ?? 1
        }
        func rowText(_ cells: [String]) -> String {
            "│" + cells.enumerated()
                .map { i, cell in " " + cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) + " " }
                .joined(separator: "│")
                + "│"
        }
        let separator = widths.map { String(repeating: "─", count: $0 + 2) }.joined(separator: "┼")
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text("┌\(separator)┐")
                    .font(Theme.monoFont(size: 12))
                    .foregroundColor(Theme.borderStrong)
                Text(rowText(headers))
                    .font(Theme.monoFont(size: 12, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .background(Theme.backgroundRaised)
                Text("├\(separator)┤")
                    .font(Theme.monoFont(size: 12))
                    .foregroundColor(Theme.borderStrong)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Text(rowText(row))
                        .font(Theme.monoFont(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                Text("└\(separator)┘")
                    .font(Theme.monoFont(size: 12))
                    .foregroundColor(Theme.borderStrong)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(1)
        .overlay(Rectangle().stroke(Theme.border.opacity(0.5), lineWidth: 1))
    }

    // MARK: - Inline styling

    /// Inline markdown: **bold**, *italic*, `code`.
    private func inline(_ text: String) -> Text {
        var out = AttributedString()
        var processed = text
        // inline code
        while let range = processed.range(of: "`[^`]*`", options: .regularExpression) {
            out += AttributedString(String(processed[..<range.lowerBound]))
            var cs = AttributedString(String(processed[range].dropFirst().dropLast()))
            cs.font = Theme.monoFont(size: 12)
            cs.foregroundColor = Theme.cyan
            cs.backgroundColor = Theme.backgroundInput
            out += cs
            processed = String(processed[range.upperBound...])
        }
        var rest = AttributedString(processed)
        // bold
        if let boldRange = rest.range(of: #"\*\*[^*]+\*\*"#, options: .regularExpression) {
            var bold = AttributedString(String(rest.characters[boldRange]).replacingOccurrences(of: "**", with: ""))
            bold.font = Theme.monoFont(size: 13, weight: .bold)
            rest.replaceSubrange(boldRange, with: bold)
        }
        // italic
        if let italicRange = rest.range(of: #"(?<!\*)\*[^*\n]+\*(?!\*)"#, options: .regularExpression) {
            var italic = AttributedString(String(rest.characters[italicRange]).replacingOccurrences(of: "*", with: ""))
            italic.font = Theme.monoFont(size: 13).italic()
            rest.replaceSubrange(italicRange, with: italic)
        }
        out += rest
        return Text(out)
    }

    // MARK: - Legacy source-mode state machine

    private var attributed: AttributedString {
        var out = AttributedString()
        var inCodeBlock = false

        // Simple state machine: ``` blocks, `inline code`, **bold**
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            let lineStr = String(line)
            if inCodeBlock {
                if lineStr.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    inCodeBlock = false
                    out.append(AttributedString("\n"))
                    continue
                }
                var cs = AttributedString(lineStr)
                cs.font = Theme.monoFont(size: 12)
                cs.foregroundColor = Theme.cyan
                out.append(cs)
                out.append(AttributedString("\n"))
                continue
            }
            if lineStr.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCodeBlock = true
                out.append(AttributedString("\n"))
                continue
            }
            var processed = lineStr
            var attributedLine = AttributedString()
            // inline code
            while let range = processed.range(of: "`[^`]*`", options: .regularExpression) {
                attributedLine.append(AttributedString(String(processed[..<range.lowerBound])))
                var cs = AttributedString(String(processed[range].dropFirst().dropLast()))
                cs.font = Theme.monoFont(size: 12)
                cs.foregroundColor = Theme.cyan
                cs.backgroundColor = Theme.backgroundInput
                attributedLine.append(cs)
                processed = String(processed[range.upperBound...])
            }
            attributedLine.append(AttributedString(processed))
            out.append(attributedLine)
            if i < lines.count - 1 {
                out.append(AttributedString("\n"))
            }
        }
        return out
    }
}
