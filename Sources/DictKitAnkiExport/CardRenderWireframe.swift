import Foundation

/// ASCII wireframe generator for Standard cards.
///
/// Output width is fixed at `WireframeLayout.contentWidth` visual columns,
/// where East-Asian wide characters count as 2. Lines that exceed the width
/// are wrapped; single artifacts/definitions that would span more than three
/// lines get an ellipsis at the tail (the Agent can call `read_card_snapshot`
/// for the full text).
///
/// See `docs/specs/llm-features/50-agent-chat.md` §4.4 for the full contract.
enum StandardWireframeRenderer {
    static func render(
        word: String,
        phonetic: String,
        senses: [StructuredSense],
        artifacts: AIArtifacts,
        aiPresence: AIArtifactPresence
    ) -> String {
        var blocks: [String] = []
        blocks.append(renderFront(word: word, phonetic: phonetic))
        blocks.append(renderBack(senses: senses, artifacts: artifacts, aiPresence: aiPresence))
        return blocks.joined(separator: "\n")
    }

    private static func renderFront(word: String, phonetic: String) -> String {
        var lines: [String] = []
        lines.append(contentsOf: WireframeTextWrapper.wrap(word))
        if !phonetic.isEmpty {
            for phoneticLine in phonetic.split(whereSeparator: \.isNewline) {
                lines.append(contentsOf: WireframeTextWrapper.wrap(String(phoneticLine)))
            }
        }
        return WireframeFrame.frame(title: "FRONT", lines: lines)
    }

    private static func renderBack(
        senses: [StructuredSense],
        artifacts: AIArtifacts,
        aiPresence: AIArtifactPresence
    ) -> String {
        var lines: [String] = []

        lines.append(contentsOf: renderSenses(senses))

        for section in CardRenderSnapshotBuilder.canonicalAISectionOrder where aiPresence.isPresent(section) {
            if !lines.isEmpty { lines.append("") }
            lines.append(contentsOf: renderAISection(section, artifacts: artifacts))
        }

        if lines.isEmpty {
            lines.append("(empty)")
        }

        return WireframeFrame.frame(title: "BACK", lines: lines)
    }

    // MARK: - Senses

    private static func renderSenses(_ senses: [StructuredSense]) -> [String] {
        guard !senses.isEmpty else { return [] }

        var lines: [String] = []
        let groupedByPOS = groupConsecutive(senses) { $0.partOfSpeech == $1.partOfSpeech }
        for group in groupedByPOS {
            guard let first = group.first else { continue }
            lines.append("[\(first.partOfSpeech)]")
            for (index, sense) in group.enumerated() {
                let prefix = "  \(index + 1). "
                let definition = senseDefinitionText(sense)
                let definitionLines = WireframeTextWrapper.wrap(
                    definition,
                    initialIndent: prefix,
                    hangingIndent: String(repeating: " ", count: WireframeMetrics.visualWidth(of: prefix))
                )
                lines.append(contentsOf: WireframeTextWrapper.truncate(definitionLines, maxLines: 3))

                for example in sense.examples {
                    let exampleLines = WireframeTextWrapper.wrap(
                        example,
                        initialIndent: "     • ",
                        hangingIndent: "       "
                    )
                    lines.append(contentsOf: WireframeTextWrapper.truncate(exampleLines, maxLines: 2))
                }
            }
        }
        return lines
    }

    private static func senseDefinitionText(_ sense: StructuredSense) -> String {
        var prefix = ""
        if let hint = sense.semanticHint {
            prefix += "(\(hint)) "
        }
        for register in sense.registers {
            prefix += "\(register) "
        }
        return prefix + sense.definition
    }

    // MARK: - AI sections

    private static func renderAISection(
        _ section: CardRenderSnapshot.AISection,
        artifacts: AIArtifacts
    ) -> [String] {
        switch section {
        case .usageCue:
            guard let note = artifacts.definitionNote.accepted?.text else { return [] }
            var lines = ["[AI · usage cue]"]
            let wrapped = WireframeTextWrapper.wrap(
                note,
                initialIndent: "  ",
                hangingIndent: "  "
            )
            lines.append(contentsOf: WireframeTextWrapper.truncate(wrapped, maxLines: 3))
            return lines

        case .examples:
            let examples = artifacts.exampleSentences.accepted ?? []
            guard !examples.isEmpty else { return [] }
            var lines = ["[AI · examples]       (\(itemCountLabel(examples.count)))"]
            for example in examples.prefix(CardRenderSnapshotLimits.exampleItemsShown) {
                let wrapped = WireframeTextWrapper.wrap(
                    example.text,
                    initialIndent: "  • ",
                    hangingIndent: "    "
                )
                lines.append(contentsOf: WireframeTextWrapper.truncate(wrapped, maxLines: 2))
            }
            if examples.count > CardRenderSnapshotLimits.exampleItemsShown {
                let hidden = examples.count - CardRenderSnapshotLimits.exampleItemsShown
                lines.append("  • … (\(hidden) more, collapsed)")
            }
            return lines

        case .pitfalls:
            return renderBulletSection(
                title: "[AI · pitfalls]",
                items: (artifacts.pitfalls.accepted ?? []).map(\.text)
            )

        case .mnemonics:
            return renderBulletSection(
                title: "[AI · mnemonics]",
                items: (artifacts.mnemonics.accepted ?? []).map(\.text)
            )

        case .collocations:
            return renderBulletSection(
                title: "[AI · collocations]",
                items: (artifacts.collocations.accepted ?? []).map { collocation in
                    if let note = collocation.note, !note.isEmpty {
                        return "\(collocation.phrase) — \(note)"
                    }
                    return collocation.phrase
                }
            )
        }
    }

    private static func renderBulletSection(title: String, items: [String]) -> [String] {
        guard !items.isEmpty else { return [] }
        let shown = CardRenderSnapshotLimits.bulletItemsShown
        var lines = ["\(title) (\(itemCountLabel(items.count)))"]
        for item in items.prefix(shown) {
            let wrapped = WireframeTextWrapper.wrap(
                item,
                initialIndent: "  • ",
                hangingIndent: "    "
            )
            lines.append(contentsOf: WireframeTextWrapper.truncate(wrapped, maxLines: 2))
        }
        if items.count > shown {
            lines.append("  • … (\(items.count - shown) more, collapsed)")
        }
        return lines
    }

    private static func itemCountLabel(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    private static func groupConsecutive<T>(
        _ items: [T],
        where predicate: (T, T) -> Bool
    ) -> [[T]] {
        var groups: [[T]] = []
        for item in items {
            if var last = groups.last, let pivot = last.first, predicate(pivot, item) {
                last.append(item)
                groups[groups.count - 1] = last
            } else {
                groups.append([item])
            }
        }
        return groups
    }
}

enum RecallWireframeRenderer {
    static func render(
        word: String,
        phonetic: String,
        draft: RecallCardDraft?,
        senses: [StructuredSense]
    ) -> String {
        var blocks: [String] = []
        blocks.append(renderFront(draft: draft))
        blocks.append(renderBack(word: word, phonetic: phonetic, draft: draft, senses: senses))
        return blocks.joined(separator: "\n")
    }

    private static func renderFront(draft: RecallCardDraft?) -> String {
        guard let draft else {
            return WireframeFrame.frame(
                title: "FRONT (Recall · no draft)",
                lines: ["(no accepted recall card)"]
            )
        }

        var lines: [String] = []
        let wrapped = WireframeTextWrapper.wrap(draft.front)
        lines.append(contentsOf: WireframeTextWrapper.truncate(wrapped, maxLines: 4))
        if let hint = draft.hint, !hint.isEmpty {
            lines.append(contentsOf: WireframeTextWrapper.wrap(
                "hint: \(hint)",
                initialIndent: "",
                hangingIndent: "      "
            ))
        }
        return WireframeFrame.frame(
            title: "FRONT (Recall · \(draft.mode.rawValue))",
            lines: lines
        )
    }

    private static func renderBack(
        word: String,
        phonetic: String,
        draft: RecallCardDraft?,
        senses: [StructuredSense]
    ) -> String {
        var lines: [String] = []

        if let draft {
            lines.append(contentsOf: WireframeTextWrapper.wrap(draft.back))
        } else {
            lines.append(word)
        }
        if !phonetic.isEmpty {
            for phoneticLine in phonetic.split(whereSeparator: \.isNewline) {
                lines.append(contentsOf: WireframeTextWrapper.wrap(String(phoneticLine)))
            }
        }

        if !senses.isEmpty {
            lines.append("")
            lines.append("[Source dictionary]")
            for sense in senses.prefix(CardRenderSnapshotLimits.recallReferenceSensesShown) {
                let text = "\(sense.partOfSpeech) — \(sense.definition)"
                let wrapped = WireframeTextWrapper.wrap(
                    text,
                    initialIndent: "  ",
                    hangingIndent: "  "
                )
                lines.append(contentsOf: WireframeTextWrapper.truncate(wrapped, maxLines: 2))
            }
            let remaining = senses.count - CardRenderSnapshotLimits.recallReferenceSensesShown
            if remaining > 0 {
                lines.append("  … (\(remaining) more senses, collapsed)")
            }
        }

        return WireframeFrame.frame(title: "BACK", lines: lines)
    }
}

// MARK: - Shared pieces

enum CardRenderSnapshotLimits {
    /// AI example section shows the first N items; the remainder gets a
    /// `collapsed` summary line.
    static let exampleItemsShown = 3
    /// Other bullet sections (pitfalls, mnemonics, collocations) share one
    /// cap: show the first N, summarize the rest.
    static let bulletItemsShown = 3
    /// Recall back shows the first N reference senses, summarizes the rest.
    static let recallReferenceSensesShown = 2
}

/// Fixed layout constants that define wireframe geometry.
///
/// We target a visual width of 50 columns (East-Asian characters count as 2),
/// which is enough for real card content while staying readable in a monospace
/// prompt context without horizontal scrolling.
enum WireframeLayout {
    static let contentWidth = 50
    static let borderHorizontal: Character = "─"
    static let borderVertical: Character = "│"
    static let cornerTopLeft: Character = "┌"
    static let cornerTopRight: Character = "┐"
    static let cornerBottomLeft: Character = "└"
    static let cornerBottomRight: Character = "┘"
}

enum WireframeFrame {
    static func frame(title: String, lines: [String]) -> String {
        let width = WireframeLayout.contentWidth
        var output: [String] = []
        output.append(topBorder(title: title, width: width))
        for raw in lines.isEmpty ? [""] : lines {
            for line in WireframeTextWrapper.wrap(raw) {
                output.append(encloseLine(line, width: width))
            }
        }
        output.append(bottomBorder(width: width))
        return output.joined(separator: "\n")
    }

    private static func topBorder(title: String, width: Int) -> String {
        // Layout: ┌── TITLE ──────────────────────────────┐
        // The title is right-padded with dashes; the "before" side uses a
        // small fixed dash count so similar titles look visually aligned.
        let leading = " \(title.uppercased()) "
        let leadingVisualWidth = WireframeMetrics.visualWidth(of: leading)
        let leftDashCount = 2
        let rightDashCount = max(width - leftDashCount - leadingVisualWidth, 1)
        let left = String(repeating: String(WireframeLayout.borderHorizontal), count: leftDashCount)
        let right = String(repeating: String(WireframeLayout.borderHorizontal), count: rightDashCount)
        return "\(WireframeLayout.cornerTopLeft)\(left)\(leading)\(right)\(WireframeLayout.cornerTopRight)"
    }

    private static func bottomBorder(width: Int) -> String {
        let dashes = String(repeating: String(WireframeLayout.borderHorizontal), count: width)
        return "\(WireframeLayout.cornerBottomLeft)\(dashes)\(WireframeLayout.cornerBottomRight)"
    }

    private static func encloseLine(_ line: String, width: Int) -> String {
        let visualWidth = WireframeMetrics.visualWidth(of: line)
        let padCount = max(width - visualWidth - 1, 0)
        let padding = String(repeating: " ", count: padCount)
        return "\(WireframeLayout.borderVertical) \(line)\(padding)\(WireframeLayout.borderVertical)"
    }
}

enum WireframeTextWrapper {
    /// Wrap `text` to lines fitting inside `WireframeLayout.contentWidth - 2`
    /// visual columns (the extra 2 columns cover the leading and trailing
    /// " | " / "| " padding around each line).
    ///
    /// `initialIndent` is applied to the first wrapped line only; subsequent
    /// lines use `hangingIndent`.
    static func wrap(
        _ text: String,
        initialIndent: String = "",
        hangingIndent: String = ""
    ) -> [String] {
        let maxVisualWidth = WireframeLayout.contentWidth - 2
        let normalized = text.replacingOccurrences(of: "\t", with: "  ")
        guard !normalized.isEmpty else { return [initialIndent.isEmpty ? "" : initialIndent.trimmingCharacters(in: .whitespaces)] }

        var lines: [String] = []
        var current = initialIndent
        var currentVisualWidth = WireframeMetrics.visualWidth(of: initialIndent)
        let continuationIndent = hangingIndent
        let continuationWidth = WireframeMetrics.visualWidth(of: continuationIndent)

        func flush() {
            lines.append(current)
            current = continuationIndent
            currentVisualWidth = continuationWidth
        }

        let tokens = tokenize(normalized)
        for token in tokens {
            let tokenWidth = WireframeMetrics.visualWidth(of: token)
            let separatorWidth = (current == initialIndent && current == hangingIndent) ? 0 : 0
            _ = separatorWidth

            let wouldOverflow = currentVisualWidth + tokenWidth > maxVisualWidth
            let isLineEmpty = (current == initialIndent && currentVisualWidth == WireframeMetrics.visualWidth(of: initialIndent))
                || (current == continuationIndent && currentVisualWidth == continuationWidth)

            if wouldOverflow && !isLineEmpty {
                flush()
            }

            // A single token longer than the whole line: hard-split by visual width.
            if WireframeMetrics.visualWidth(of: current) + tokenWidth > maxVisualWidth {
                let splits = hardSplit(token, maxVisualWidth: maxVisualWidth - WireframeMetrics.visualWidth(of: current))
                for (index, chunk) in splits.enumerated() {
                    if index == 0 {
                        current += chunk
                        currentVisualWidth += WireframeMetrics.visualWidth(of: chunk)
                    } else {
                        flush()
                        current += chunk
                        currentVisualWidth += WireframeMetrics.visualWidth(of: chunk)
                    }
                }
                continue
            }

            current += token
            currentVisualWidth += tokenWidth
        }

        if WireframeMetrics.visualWidth(of: current) > 0 || lines.isEmpty {
            lines.append(current)
        }
        return lines
    }

    /// Truncate wrapped lines to `maxLines`. When truncation happens, the
    /// last kept line has its tail replaced with `…` to make it obvious
    /// content was cut.
    static func truncate(_ lines: [String], maxLines: Int) -> [String] {
        guard lines.count > maxLines else { return lines }
        var kept = Array(lines.prefix(maxLines))
        if var last = kept.last {
            last = appendEllipsis(last)
            kept[kept.count - 1] = last
        }
        return kept
    }

    private static func appendEllipsis(_ line: String) -> String {
        let maxVisualWidth = WireframeLayout.contentWidth - 2
        let ellipsis = "…"
        var result = line
        if WireframeMetrics.visualWidth(of: result) + WireframeMetrics.visualWidth(of: ellipsis) > maxVisualWidth {
            while !result.isEmpty,
                  WireframeMetrics.visualWidth(of: result) + WireframeMetrics.visualWidth(of: ellipsis) > maxVisualWidth {
                result.removeLast()
            }
        }
        return result + ellipsis
    }

    /// Tokenize preserving whitespace runs. This keeps spaces attached to the
    /// following word in a predictable way, so wrapping produces natural-looking
    /// word boundaries rather than raw character splits.
    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentIsSpace = false

        for scalar in text.unicodeScalars {
            let character = Character(scalar)
            let isSpace = character == " "
            if current.isEmpty {
                current.append(character)
                currentIsSpace = isSpace
                continue
            }
            if isSpace == currentIsSpace {
                current.append(character)
            } else {
                tokens.append(current)
                current = String(character)
                currentIsSpace = isSpace
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func hardSplit(_ token: String, maxVisualWidth: Int) -> [String] {
        guard maxVisualWidth > 0 else { return [token] }
        var chunks: [String] = []
        var current = ""
        var currentWidth = 0
        for character in token {
            let w = WireframeMetrics.visualWidth(of: String(character))
            if currentWidth + w > maxVisualWidth {
                if !current.isEmpty { chunks.append(current) }
                current = String(character)
                currentWidth = w
            } else {
                current.append(character)
                currentWidth += w
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

/// Visual-width math for monospace rendering.
///
/// We treat characters in CJK / full-width / emoji ranges as 2 columns,
/// otherwise 1. This lets Chinese-heavy definitions align the same as English
/// ones when viewed in a monospace font.
enum WireframeMetrics {
    static func visualWidth(of string: String) -> Int {
        var total = 0
        for scalar in string.unicodeScalars {
            total += visualWidth(of: scalar)
        }
        return total
    }

    static func visualWidth(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        // Control characters and zero-width joiners contribute 0 visual columns.
        if value < 0x20 || (value >= 0x7F && value < 0xA0) { return 0 }
        if value == 0x200B || value == 0x200C || value == 0x200D || value == 0xFEFF { return 0 }
        // Combining marks contribute 0 visual columns.
        if (0x0300...0x036F).contains(value) { return 0 }
        if (0x1AB0...0x1AFF).contains(value) { return 0 }
        if (0x1DC0...0x1DFF).contains(value) { return 0 }
        if (0x20D0...0x20FF).contains(value) { return 0 }
        if (0xFE20...0xFE2F).contains(value) { return 0 }
        // CJK Unified Ideographs, Hiragana, Katakana, Hangul, full-width forms, etc.
        if isWide(value) { return 2 }
        return 1
    }

    private static func isWide(_ value: UInt32) -> Bool {
        // A conservative set of the common East-Asian wide ranges. This is
        // not exhaustive (Unicode TR11 has many more), but covers the cases
        // that matter for card content in this app.
        switch value {
        case 0x1100...0x115F: return true   // Hangul Jamo
        case 0x2E80...0x303E: return true   // CJK Radicals, Kangxi, symbols
        case 0x3041...0x33FF: return true   // Hiragana, Katakana, CJK letters
        case 0x3400...0x4DBF: return true   // CJK Unified Extension A
        case 0x4E00...0x9FFF: return true   // CJK Unified Ideographs
        case 0xA000...0xA4CF: return true   // Yi Syllables
        case 0xAC00...0xD7A3: return true   // Hangul Syllables
        case 0xF900...0xFAFF: return true   // CJK Compatibility
        case 0xFE30...0xFE4F: return true   // CJK Compatibility Forms
        case 0xFF00...0xFF60: return true   // Full-width ASCII + punctuation
        case 0xFFE0...0xFFE6: return true   // Full-width signs
        case 0x1F300...0x1F64F: return true // Emoji
        case 0x1F680...0x1F6FF: return true // Transport / symbols
        case 0x1F900...0x1F9FF: return true // Supplemental symbols / pictographs
        case 0x20000...0x2FFFD: return true // CJK Extension B-F
        default: return false
        }
    }
}
