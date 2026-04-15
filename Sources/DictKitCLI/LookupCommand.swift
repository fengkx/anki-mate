import ArgumentParser
import DictKit
import DictKitSystemDictionary
import Foundation

struct LookupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lookup",
        abstract: "Look up a word in the macOS system dictionary."
    )

    @Flag(help: "Print the public API result as structured JSON.")
    var json = false

    @Flag(help: "Use the private HTML source and print a human-readable result.")
    var html = false

    @Flag(help: "Use the private HTML source and print structured JSON.")
    var htmlJSON = false

    @Flag(help: "Print the raw HTML returned by the private dictionary API.")
    var rawHTML = false

    @Flag(help: "List available macOS dictionary names.")
    var listDicts = false

    @Argument(help: "The word or phrase to look up.")
    var query: [String] = []

    mutating func run() throws {
        let client = SystemDictionaryClient()

        if listDicts {
            for name in client.listAvailableDictionaries() {
                print(name)
            }
            return
        }

        let requestedModes = [json, html, htmlJSON, rawHTML].filter { $0 }
        guard requestedModes.count <= 1 else {
            throw ValidationError("Choose at most one output mode flag.")
        }

        let word = query.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else {
            throw ValidationError("Please provide a word to look up.")
        }

        let mode = outputMode
        do {
            switch mode {
            case .humanReadable:
                printHumanReadable(try client.lookup(word, source: .publicAPI, includeSource: true))
            case .json:
                printJSON(try client.lookup(word, source: .publicAPI, includeSource: true))
            case .htmlHuman:
                printHumanReadable(try client.lookup(word, source: .privateHTML(), includeSource: true))
            case .htmlJSON:
                printJSON(try client.lookup(word, source: .privateHTML(), includeSource: true))
            case .rawHTML:
                guard let html = client.lookupHTML(for: word) else {
                    print("Private dictionary HTML lookup did not return a record for \(word).")
                    return
                }
                print(html)
            }
        } catch LookupError.notFound {
            print("No entry found for \(word).")
            Foundation.exit(0)
        } catch let error as LookupError {
            throw DictKitCommand.commandFailure(for: error) ?? error
        }
    }

    private var outputMode: OutputMode {
        if json { return .json }
        if html { return .htmlHuman }
        if htmlJSON { return .htmlJSON }
        if rawHTML { return .rawHTML }
        return .humanReadable
    }
}

private enum OutputMode {
    case humanReadable
    case json
    case htmlHuman
    case htmlJSON
    case rawHTML
}

private func title(for lexicalEntry: LexicalEntry) -> String {
    let label = UnicodeScalar(65 + lexicalEntry.displayIndex).map { String(Character($0)) } ?? "\(lexicalEntry.displayIndex + 1)"
    return "\(label). \(lexicalEntry.partOfSpeechLabel)"
}

private func formatPronunciation(_ pronunciation: Pronunciation) -> String {
    var parts: [String] = []
    if let dialect = pronunciation.dialect {
        parts.append(dialect)
    }
    parts.append(pronunciation.ipa)
    if let respelling = pronunciation.respelling, respelling != pronunciation.ipa {
        parts.append("(\(respelling))")
    }
    return parts.joined(separator: " ")
}

private func printHumanReadable(_ result: LookupResult) {
    print("=== Lookup Result ===")
    print("Query: \(result.query)")
    print("Source: \(result.metadata.usedSource.rawValue)")
    if !result.metadata.warnings.isEmpty {
        print("Warnings: \(result.metadata.warnings.joined(separator: ", "))")
    }

    for entry in result.entries {
        print("Headword: \(entry.headword)")
        if entry.pronunciations.isEmpty {
            print("Pronunciations: -")
        } else {
            print("Pronunciations:")
            entry.pronunciations.forEach { print("  - \(formatPronunciation($0))") }
        }

        for lexicalEntry in entry.lexicalEntries {
            print("\n[\(title(for: lexicalEntry))]")
            for sense in lexicalEntry.senses {
                var header = "\(sense.number)."
                if let semanticHint = sense.semanticHint {
                    header += " \(semanticHint)"
                }
                if let countability = sense.countability {
                    header += " [\(countability.rawValue)]"
                }
                if !sense.registers.isEmpty {
                    header += " {\(sense.registers.joined(separator: ", "))}"
                }
                print(header)
                print(sense.definition)
                sense.examples.forEach { print("  - \($0)") }
            }
        }

        for group in entry.phraseGroups {
            print("\n[\(group.title)]")
            if !group.items.isEmpty {
                for item in group.items {
                    print("- \(item.phrase)")
                    if let definition = item.definition {
                        print("  \(definition)")
                    }
                    item.examples.forEach { print("  - \($0)") }
                }
            } else if let rawContent = group.rawContent {
                print(rawContent)
            }
        }

        for note in entry.notes {
            print("\n[\(note.kind.rawValue.uppercased())]")
            print(note.content)
        }
    }

    if let source = result.source {
        print("\n=== Source Payload ===")
        if let rawText = source.rawText {
            print(rawText)
        }
        if let rawHTML = source.rawHTML {
            print(rawHTML)
        }
    }
}

private func printJSON(_ result: LookupResult) {
    printEncodedJSON(result)
}
