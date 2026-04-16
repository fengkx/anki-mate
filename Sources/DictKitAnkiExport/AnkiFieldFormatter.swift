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
    public static func definitionsHTML(from result: LookupResult) -> String {
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
        return html
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
}
