import DictKit
import Foundation

public enum AnkiFieldFormatter {
    /// Extract the first available IPA pronunciation from a LookupResult.
    public static func phonetic(from result: LookupResult) -> String {
        for entry in result.entries {
            // Prefer headword-level pronunciations
            for p in entry.pronunciations {
                let ipa = p.ipa.trimmingCharacters(in: .whitespacesAndNewlines)
                if !ipa.isEmpty { return ipa }
            }
            // Fall back to lexical entry pronunciations
            for lex in entry.lexicalEntries {
                for p in lex.pronunciations {
                    let ipa = p.ipa.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !ipa.isEmpty { return ipa }
                }
            }
        }
        return ""
    }

    public static func phoneticDisplay(from result: LookupResult) -> String {
        for entry in result.entries {
            for p in entry.pronunciations {
                let display = formattedDisplayPhonetic(for: p)
                if !display.isEmpty { return display }
            }

            for lex in entry.lexicalEntries {
                for p in lex.pronunciations {
                    let display = formattedDisplayPhonetic(for: p)
                    if !display.isEmpty { return display }
                }
            }
        }

        return ""
    }

    public static func phoneticDisplay(
        from result: LookupResult,
        aiArtifacts: AIArtifacts
    ) -> String {
        let basePhonetic = phoneticDisplay(from: result)
        guard let stressSyllables = preferredStressSyllables(from: aiArtifacts) else {
            return basePhonetic
        }
        guard !basePhonetic.isEmpty else {
            return stressSyllables
        }
        return "\(basePhonetic)\n\(stressSyllables)"
    }

    /// Build HTML definitions grouped by part of speech.
    public static func definitionsHTML(
        from result: LookupResult,
        aiArtifacts: AIArtifacts = .empty
    ) -> String {
        var html = ""
        for entry in result.entries {
            for lex in entry.lexicalEntries {
                html += "<div class=\"pos-group\">"
                html += "<h3 class=\"pos\">\(escapeHTML(lex.partOfSpeechLabel))</h3>"
                html += "<ol class=\"senses\">"
                for sense in lex.senses {
                    html += "<li>"
                    if let hint = sense.semanticHint {
                        html += "<span class=\"hint\">(\(escapeHTML(hint)))</span> "
                    }
                    for register in sense.registers {
                        html += "<span class=\"register\">\(escapeHTML(register))</span> "
                    }
                    html += "<span class=\"def\">\(escapeHTML(sense.definition))</span>"
                    if !sense.examples.isEmpty {
                        html += "<ul class=\"examples\">"
                        for example in sense.examples {
                            html += "<li>\(escapeHTML(example))</li>"
                        }
                        html += "</ul>"
                    }
                    html += "</li>"
                }
                html += "</ol>"
                html += "</div>"
            }
        }
        return html + aiSupplementHTML(aiArtifacts: aiArtifacts)
    }

    /// Build HTML definitions grouped by part of speech.
    public static func definitionsHTML(
        from result: LookupResult,
        aiAcceptedExampleSentences: [String] = [],
        aiAcceptedDefinitionNote: String? = nil,
        aiAcceptedRecallCardDrafts: [RecallCardDraft] = [],
        aiAcceptedPitfalls: [String] = [],
        aiAcceptedMnemonics: [String] = [],
        aiAcceptedCollocations: [String] = []
    ) -> String {
        definitionsHTML(
            from: result,
            aiArtifacts: AIArtifacts(
                legacyAcceptedExampleSentences: aiAcceptedExampleSentences,
                legacyAcceptedDefinitionNote: aiAcceptedDefinitionNote,
                legacyAcceptedRecallCardDrafts: aiAcceptedRecallCardDrafts,
                legacyAcceptedPitfalls: aiAcceptedPitfalls,
                legacyAcceptedMnemonics: aiAcceptedMnemonics,
                legacyAcceptedCollocations: aiAcceptedCollocations
            )
        )
    }

    /// Render a full card HTML page for preview purposes (front or back).
    public static func renderCardHTML(note: AnkiNoteData, showBack: Bool) -> String {
        if note.kind == .recall {
            return renderRecallCardHTML(note: note, showBack: showBack)
        }

        var front = AnkiCardTemplate.frontTemplate
        front = front.replacingOccurrences(of: "{{Word}}", with: escapeHTML(note.word))
        front = front.replacingOccurrences(of: "{{Phonetic}}", with: escapeHTMLPreservingLineBreaks(note.phonetic))
        // Remove sound tag for preview
        front = front.replacingOccurrences(of: "{{Audio}}", with: "")

        var body = front
        if showBack {
            var back = AnkiCardTemplate.backTemplate
            back = back.replacingOccurrences(of: "{{FrontSide}}", with: front)
            back = back.replacingOccurrences(of: "{{Definitions}}", with: note.definitions)
            body = back
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>\(AnkiCardTemplate.css)</style>
        </head>
        <body class="card">
        \(body)
        </body>
        </html>
        """
    }

    private static func renderRecallCardHTML(note: AnkiNoteData, showBack: Bool) -> String {
        let prompt = note.fieldValue(at: 0)
        let mode = note.fieldValue(at: 1)
        let instruction = note.fieldValue(at: 2)
        let hint = note.fieldValue(at: 3)
        let answer = note.fieldValue(at: 4)
        let sourceWord = note.fieldValue(at: 5)
        let phonetic = note.fieldValue(at: 6)
        let definitions = note.fieldValue(at: 7)
        let audio = note.fieldValue(at: 8)

        let hintHTML = hint.isEmpty ? "" : """
        <div class="recall-support-card">
          <div class="recall-section-label">Hint</div>
          <div class="recall-support-text">\(hint)</div>
        </div>
        """

        let front = """
        <div class="front recall-shell">
          <div class="recall-eyebrow">Recall Card</div>
          <div class="recall-topline">
            <div class="recall-mode-chip">\(mode)</div>
            <div class="recall-stage-chip">\(showBack ? "Back" : "Front")</div>
          </div>
          <div class="recall-instruction">\(instruction)</div>
          <div class="recall-prompt-card">
            <div class="recall-section-label">Prompt</div>
            <div class="recall-front-text">\(prompt)</div>
          </div>
          \(hintHTML)
        </div>
        """

        if showBack == false {
            return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <style>\(AnkiRecallCardTemplate.css)</style>
            </head>
            <body class="card">
            \(front)
            </body>
            </html>
            """
        }

        let phoneticHTML = phonetic.isEmpty ? "" : "<div class=\"phonetic recall-phonetic\">\(phonetic)</div>"
        let audioHTML = audio.isEmpty ? "" : "<div class=\"recall-audio\">\(audio)</div>"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>\(AnkiRecallCardTemplate.css)</style>
        </head>
        <body class="card">
        \(front)
        <hr id="answer">
        <div class="back recall-answer-shell">
          <div class="recall-answer-card">
            <div class="recall-section-label">Answer</div>
            <div class="recall-answer-text">\(answer)</div>
          </div>
          <section class="recall-reference-shell">
            <div class="recall-reference-kicker">Source Entry</div>
            <div class="recall-reference-card">
              <div class="recall-reference-header">
                <div class="recall-source-word">\(sourceWord)</div>
                <div class="recall-reference-meta">
                  \(phoneticHTML)
                  \(audioHTML)
                </div>
              </div>
              \(definitions.isEmpty ? "" : """
              <div class="recall-definitions">
                <div class="recall-section-label">Reference</div>
                \(definitions)
              </div>
              """)
            </div>
          </section>
        </div>
        </body>
        </html>
        """
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func formattedDisplayPhonetic(for pronunciation: Pronunciation) -> String {
        let notation = pronunciation.displayNotation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notation.isEmpty else { return "" }
        if pronunciation.usesIPADelimitersForDisplay {
            return "/\(notation)/"
        }
        return notation
    }

    private static func escapeHTMLPreservingLineBreaks(_ text: String) -> String {
        escapeHTML(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func preferredStressSyllables(from aiArtifacts: AIArtifacts) -> String? {
        let normalized = aiArtifacts.normalized()
        let byDialect = normalized.generatedStressSyllablesByDialect
        let preferred = byDialect["AmE"] ?? byDialect["BrE"] ?? byDialect.values.first
        let trimmed = preferred?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func aiSupplementHTML(aiArtifacts: AIArtifacts) -> String {
        let aiArtifacts = aiArtifacts.normalized()
        var sections: [String] = []

        if let acceptedDefinitionNote = aiArtifacts.definitionNote.accepted?.text,
           !acceptedDefinitionNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(usageCueSectionHTML(note: acceptedDefinitionNote))
        }

        if let acceptedExampleSentences = aiArtifacts.exampleSentences.accepted,
           !acceptedExampleSentences.isEmpty {
            sections.append(exampleCardsSectionHTML(sentences: acceptedExampleSentences))
        }

        let learningAidsSection = learningAidsSectionHTML(
            pitfalls: aiArtifacts.pitfalls.accepted ?? [],
            mnemonics: aiArtifacts.mnemonics.accepted ?? [],
            collocations: aiArtifacts.collocations.accepted ?? []
        )
        if !learningAidsSection.isEmpty {
            sections.append(learningAidsSection)
        }

        guard !sections.isEmpty else { return "" }

        return """
        <section class="ai-study-layer">
          <div class="ai-study-header">
            <div class="ai-study-kicker">AI study layer</div>
            <h4 class="ai-study-title">Memory-focused notes</h4>
          </div>
          \(sections.joined())
        </section>
        """
    }

    private static func aiGeneratedTagHTML() -> String {
        "<span class=\"ai-tag\">AI-generated</span>"
    }

    private static func usageCueSectionHTML(note: String) -> String {
        """
        <section class="ai-panel ai-panel-highlight">
          <div class="ai-panel-header">
            <div>
              <div class="ai-panel-eyebrow">Quick cue</div>
              <h5 class="ai-panel-title">Usage</h5>
            </div>
          </div>
          <p class="ai-inline-note">\(escapeHTMLPreservingLineBreaks(note))</p>
          <div class="ai-meta-row">\(aiGeneratedTagHTML())</div>
        </section>
        """
    }

    private static func exampleCardsSectionHTML(sentences: [ExampleSentenceArtifact]) -> String {
        let cards = sentences.map(exampleSentenceCardHTML(for:)).joined()
        return """
        <section class="ai-panel">
          <div class="ai-panel-header">
            <div>
              <div class="ai-panel-eyebrow">Natural context</div>
              <h5 class="ai-panel-title">Examples</h5>
            </div>
          </div>
          <div class="ai-example-grid">
            \(cards)
          </div>
        </section>
        """
    }

    private static func learningAidsSectionHTML(
        pitfalls: [PitfallArtifact],
        mnemonics: [MnemonicArtifact],
        collocations: [CollocationArtifact]
    ) -> String {
        var blocks: [String] = []

        if !pitfalls.isEmpty {
            blocks.append(
                learningAidBlockHTML(
                    title: "Pitfalls",
                    modifierClass: "ai-learning-warning",
                    items: pitfalls.map { artifact in
                        learningAidItemHTML(text: artifact.text)
                    }
                )
            )
        }

        if !mnemonics.isEmpty {
            blocks.append(
                learningAidBlockHTML(
                    title: "Mnemonics",
                    modifierClass: "ai-learning-memory",
                    items: mnemonics.map { artifact in
                        learningAidItemHTML(text: artifact.text)
                    }
                )
            )
        }

        if !collocations.isEmpty {
            blocks.append(
                learningAidBlockHTML(
                    title: "Collocations",
                    modifierClass: "ai-learning-collocation",
                    items: collocations.map(collocationItemHTML(for:))
                )
            )
        }

        guard !blocks.isEmpty else { return "" }

        return """
        <section class="ai-panel">
          <div class="ai-panel-header">
            <div>
              <div class="ai-panel-eyebrow">Recall support</div>
              <h5 class="ai-panel-title">Learning Aids</h5>
            </div>
          </div>
          <div class="ai-learning-grid">
            \(blocks.joined())
          </div>
        </section>
        """
    }

    private static func exampleSentenceCardHTML(for artifact: ExampleSentenceArtifact) -> String {
        let source = escapeHTMLPreservingLineBreaks(exampleSourceText(for: artifact))
        let translationHTML: String
        if let translation = artifact.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !translation.isEmpty {
            translationHTML = "<div class=\"ai-example-translation\">\(escapeHTMLPreservingLineBreaks(translation))</div>"
        } else {
            translationHTML = ""
        }

        let noteHTML: String
        if let note = artifact.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            noteHTML = "<div class=\"ai-subnote\">\(escapeHTMLPreservingLineBreaks(note))</div>"
        } else {
            noteHTML = ""
        }

        return """
        <article class="ai-example-card">
          <div class="ai-example-text">\(source)</div>
          \(translationHTML)
          \(noteHTML)
          <div class="ai-meta-row">\(aiGeneratedTagHTML())</div>
        </article>
        """
    }

    private static func learningAidBlockHTML(title: String, modifierClass: String, items: [String]) -> String {
        """
        <section class="ai-learning-block \(modifierClass)">
          <h6 class="ai-learning-title">\(escapeHTML(title))</h6>
          <ul class="ai-learning-list">
            \(items.joined())
          </ul>
        </section>
        """
    }

    private static func learningAidItemHTML(text: String) -> String {
        """
        <li class="ai-learning-item">
          <div class="ai-learning-text">\(escapeHTMLPreservingLineBreaks(text))</div>
          <div class="ai-meta-row">\(aiGeneratedTagHTML())</div>
        </li>
        """
    }

    private static func collocationItemHTML(for artifact: CollocationArtifact) -> String {
        var html = "<li class=\"ai-learning-item\">"
        html += "<div class=\"ai-collocation-phrase\">\(escapeHTML(artifact.phrase))</div>"
        if let note = artifact.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            html += "<div class=\"ai-subnote\">\(escapeHTMLPreservingLineBreaks(note))</div>"
        }
        html += "<div class=\"ai-meta-row\">\(aiGeneratedTagHTML())</div>"
        html += "</li>"
        return html
    }

    private static func exampleSourceText(for artifact: ExampleSentenceArtifact) -> String {
        let trimmed = artifact.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard artifact.translation != nil,
              let separatorRange = trimmed.range(of: "—", options: .backwards) else {
            return trimmed
        }

        let source = trimmed[..<separatorRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? trimmed : source
    }

}
