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
        var front = AnkiCardTemplate.frontTemplate
        front = front.replacingOccurrences(of: "{{Word}}", with: escapeHTML(note.word))
        front = front.replacingOccurrences(of: "{{Phonetic}}", with: escapeHTML(note.phonetic))
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

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escapeHTMLPreservingLineBreaks(_ text: String) -> String {
        escapeHTML(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func aiSupplementHTML(aiArtifacts: AIArtifacts) -> String {
        var html = ""
        if let acceptedDefinitionNote = aiArtifacts.definitionNote.accepted?.text,
           !acceptedDefinitionNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            html += "<p class=\"ai-inline-note\">"
            html += "<span class=\"def\">\(escapeHTMLPreservingLineBreaks(acceptedDefinitionNote))</span>"
            html += aiGeneratedTagHTML()
            html += "</p>"
        }
        if let acceptedExampleSentences = aiArtifacts.exampleSentences.accepted,
           !acceptedExampleSentences.isEmpty {
            html += "<ul class=\"examples examples-supplement\">"
            for sentence in acceptedExampleSentences {
                html += "<li>"
                html += escapeHTML(sentence.text)
                if let note = sentence.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                    html += "<div class=\"ai-subnote\">\(escapeHTMLPreservingLineBreaks(note))</div>"
                }
                html += aiGeneratedTagHTML()
                html += "</li>"
            }
            html += "</ul>"
        }
        html += aiArtifactSectionHTML(
            title: "Recall Cards",
            items: (aiArtifacts.recallCardDrafts.accepted ?? []).map { draft in
                recallCardDraftHTML(for: draft)
            }
        )
        html += aiArtifactSectionHTML(
            title: "Pitfalls",
            items: (aiArtifacts.pitfalls.accepted ?? []).map { item in
                escapeHTML(item.text) + aiGeneratedTagHTML()
            }
        )
        html += aiArtifactSectionHTML(
            title: "Mnemonics",
            items: (aiArtifacts.mnemonics.accepted ?? []).map { item in
                escapeHTMLPreservingLineBreaks(item.text) + aiGeneratedTagHTML()
            }
        )
        html += aiArtifactSectionHTML(
            title: "Collocations",
            items: (aiArtifacts.collocations.accepted ?? []).map { artifact in
                collocationHTML(for: artifact)
            }
        )
        return html
    }

    private static func aiGeneratedTagHTML() -> String {
        "<span class=\"ai-tag\">AI-generated</span>"
    }

    private static func aiArtifactSectionHTML(title: String, items: [String]) -> String {
        guard !items.isEmpty else { return "" }

        var html = "<div class=\"ai-artifact-section\">"
        html += "<h4 class=\"ai-artifact-title\">\(escapeHTML(title))</h4>"
        html += "<ul class=\"ai-artifact-list\">"
        for item in items {
            html += "<li>\(item)</li>"
        }
        html += "</ul></div>"
        return html
    }

    private static func recallCardDraftHTML(for draft: RecallCardDraft) -> String {
        var html = "<div class=\"ai-recall-draft\">"
        html += "<span class=\"ai-recall-mode\">\(escapeHTML(draft.mode.displayName))</span>"
        html += "<div><strong>Front:</strong> \(escapeHTMLPreservingLineBreaks(draft.front))</div>"
        html += "<div><strong>Back:</strong> \(escapeHTMLPreservingLineBreaks(draft.back))</div>"
        if let hint = draft.hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            html += "<div><strong>Hint:</strong> \(escapeHTMLPreservingLineBreaks(hint))</div>"
        }
        html += aiGeneratedTagHTML()
        html += "</div>"
        return html
    }

    private static func collocationHTML(for artifact: CollocationArtifact) -> String {
        var html = "<span class=\"ai-collocation-phrase\">\(escapeHTML(artifact.phrase))</span>"
        if let note = artifact.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            html += "<div class=\"ai-subnote\">\(escapeHTMLPreservingLineBreaks(note))</div>"
        }
        html += aiGeneratedTagHTML()
        return html
    }
}
