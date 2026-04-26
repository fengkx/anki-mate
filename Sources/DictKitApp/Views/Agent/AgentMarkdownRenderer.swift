import Foundation

enum AgentMarkdownRenderer {
    struct RenderedLine: Equatable {
        let content: AttributedString
        let isBlank: Bool
        let isCode: Bool
    }

    static func renderLines(_ text: String) -> [RenderedLine] {
        let normalized = normalizeInlineTokens(in: text)
        let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        var lines: [RenderedLine] = []
        var inCodeBlock = false

        for rawLine in rawLines {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCodeBlock.toggle()
                continue
            }

            if inCodeBlock {
                lines.append(
                    RenderedLine(
                        content: AttributedString(line),
                        isBlank: line.isEmpty,
                        isCode: true
                    )
                )
                continue
            }

            let prepared = normalizeBlockPrefix(in: line)
            let content = renderInlineMarkdown(prepared)

            lines.append(
                RenderedLine(
                    content: content,
                    isBlank: prepared.isEmpty,
                    isCode: false
                )
            )
        }

        return lines.isEmpty
            ? [RenderedLine(content: AttributedString(""), isBlank: true, isCode: false)]
            : lines
    }

    private static func normalizeInlineTokens(in text: String) -> String {
        text
            .replacingOccurrences(of: #"$\rightarrow$"#, with: "→")
            .replacingOccurrences(of: #"$\Rightarrow$"#, with: "⇒")
    }

    private static func normalizeBlockPrefix(in line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else { return "" }

        if let headingRange = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            return String(trimmed[headingRange.upperBound...])
        }

        if let bulletRange = trimmed.range(of: #"^[-+*]\s+"#, options: .regularExpression) {
            return "• " + trimmed[bulletRange.upperBound...]
        }

        if trimmed.hasPrefix("> ") {
            return String(trimmed.dropFirst(2))
        }

        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            return ""
        }

        return line
    }

    private static func renderInlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
