import DictKit
import DictKitSystemDictionary
import Foundation
import SwiftUI

enum DictionaryPreviewComparisonState: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case partialFailure
    case failure
}

enum DictionaryPreviewPaneState: Equatable {
    case loading
    case loaded
    case empty
    case failed(message: String)
}

enum DictionaryPreviewSectionKind: String, Equatable, Sendable {
    case summary
    case pronunciation
    case lexicalEntry
    case phraseGroup
    case note
}

enum DictionaryPreviewRowEmphasis: Equatable, Sendable {
    case primary
    case secondary
}

struct DictionaryPreviewRow: Equatable, Sendable, Identifiable {
    let id: String
    let label: String?
    let value: String
    let emphasis: DictionaryPreviewRowEmphasis
}

struct DictionaryPreviewSection: Equatable, Sendable, Identifiable {
    let id: String
    let kind: DictionaryPreviewSectionKind
    let title: String
    let rows: [DictionaryPreviewRow]
    let isExpandable: Bool
}

struct DictionaryPreviewPane: Equatable, Sendable {
    let title: String
    let dictionaryName: String
    let sections: [DictionaryPreviewSection]
    let state: DictionaryPreviewPaneState
}

struct DictionaryPreviewComparison: Equatable, Sendable {
    let sampleWord: String
    let current: DictionaryPreviewPane
    let candidate: DictionaryPreviewPane
}

@MainActor
final class DictionarySelectionPreviewModel: ObservableObject {
    @Published private(set) var availableDictionaries: [String]
    @Published private(set) var comparisonState: DictionaryPreviewComparisonState = .idle
    @Published private(set) var comparison: DictionaryPreviewComparison?
    @Published var sampleWord: String

    let currentDictionaryName: String
    var selectedDictionaryName: String { candidateDictionaryName }

    private var candidateDictionaryName: String
    private let lookup: @Sendable (String, DictionaryLookupSource) async throws -> LookupResult
    private var didLoad = false
    private var requestID: UInt64 = 0

    init(
        currentDictionaryName: String,
        candidateDictionaryName: String,
        sampleWord: String = "apple",
        listDictionaries: @escaping @Sendable () -> [String] = {
            SystemDictionaryClient().listAvailableDictionaries().sorted()
        },
        lookup: @escaping @Sendable (String, DictionaryLookupSource) async throws -> LookupResult = { term, source in
            try SystemDictionaryClient().lookup(term, source: source, includeSource: false)
        }
    ) {
        let availableDictionaries = listDictionaries()
        self.availableDictionaries = availableDictionaries
        self.currentDictionaryName = Self.canonicalDictionaryName(
            for: currentDictionaryName,
            availableDictionaries: availableDictionaries
        )
        self.candidateDictionaryName = Self.canonicalDictionaryName(
            for: candidateDictionaryName,
            availableDictionaries: availableDictionaries
        )
        self.sampleWord = sampleWord
        self.lookup = lookup
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        await refresh()
    }

    func setCandidateDictionaryName(_ dictionaryName: String) async {
        let canonicalName = Self.canonicalDictionaryName(
            for: dictionaryName,
            availableDictionaries: availableDictionaries
        )
        guard candidateDictionaryName != canonicalName else { return }
        candidateDictionaryName = canonicalName
        await refresh()
    }

    func isCurrentDictionary(_ dictionaryName: String) -> Bool {
        currentDictionaryName == Self.canonicalDictionaryName(
            for: dictionaryName,
            availableDictionaries: availableDictionaries
        )
    }

    func isCandidateDictionary(_ dictionaryName: String) -> Bool {
        candidateDictionaryName == Self.canonicalDictionaryName(
            for: dictionaryName,
            availableDictionaries: availableDictionaries
        )
    }

    func refresh() async {
        let query = normalizedSampleWord
        requestID &+= 1
        let currentRequestID = requestID
        comparisonState = .loading

        async let currentPaneTask = buildPane(
            title: "Current",
            dictionaryName: currentDictionaryName,
            sampleWord: query
        )
        async let candidatePaneTask = buildPane(
            title: "Candidate",
            dictionaryName: candidateDictionaryName,
            sampleWord: query
        )

        let currentPane = await currentPaneTask
        let candidatePane = await candidatePaneTask

        guard currentRequestID == requestID else { return }

        let comparison = DictionaryPreviewComparison(
            sampleWord: query,
            current: currentPane,
            candidate: candidatePane
        )

        self.comparison = comparison
        comparisonState = Self.comparisonState(current: currentPane, candidate: candidatePane)
    }

    private var normalizedSampleWord: String {
        let trimmed = sampleWord.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "apple" : trimmed
    }

    private func buildPane(title: String, dictionaryName: String, sampleWord: String) async -> DictionaryPreviewPane {
        do {
            let result = try await lookup(sampleWord, Self.lookupSource(for: dictionaryName))
            let sections = Self.makeSections(from: result)
            let paneState: DictionaryPreviewPaneState = sections.isEmpty ? .empty : .loaded
            return DictionaryPreviewPane(
                title: title,
                dictionaryName: Self.displayName(for: dictionaryName),
                sections: sections,
                state: paneState
            )
        } catch LookupError.notFound {
            return DictionaryPreviewPane(
                title: title,
                dictionaryName: Self.displayName(for: dictionaryName),
                sections: [],
                state: .empty
            )
        } catch {
            return DictionaryPreviewPane(
                title: title,
                dictionaryName: Self.displayName(for: dictionaryName),
                sections: [],
                state: .failed(message: error.localizedDescription)
            )
        }
    }

    private static func lookupSource(for dictionaryName: String) -> DictionaryLookupSource {
        let trimmed = dictionaryName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .automatic : .privateHTML(dictionaryName: trimmed)
    }

    static func displayName(for dictionaryName: String) -> String {
        dictionaryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Automatic" : dictionaryName
    }

    private static func canonicalDictionaryName(
        for dictionaryName: String,
        availableDictionaries: [String]
    ) -> String {
        let trimmed = dictionaryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let exact = availableDictionaries.first(where: {
            normalizeDictionaryName($0) == normalizeDictionaryName(trimmed)
        }) {
            return exact
        }

        if let fuzzy = availableDictionaries.first(where: {
            let candidate = normalizeDictionaryName($0)
            let target = normalizeDictionaryName(trimmed)
            return candidate.contains(target) || target.contains(candidate)
        }) {
            return fuzzy
        }

        return trimmed
    }

    private static func normalizeDictionaryName(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func comparisonState(
        current: DictionaryPreviewPane,
        candidate: DictionaryPreviewPane
    ) -> DictionaryPreviewComparisonState {
        switch (current.state, candidate.state) {
        case (.failed(message: _), .failed(message: _)):
            return .failure
        case (.empty, .empty):
            return .empty
        case (.failed(message: _), _), (_, .failed(message: _)):
            return .partialFailure
        default:
            return .loaded
        }
    }

    private static func makeSections(from result: LookupResult) -> [DictionaryPreviewSection] {
        guard let entry = result.entries.first else {
            return []
        }

        var sections: [DictionaryPreviewSection] = []

        let summaryRows = [
            DictionaryPreviewRow(
                id: "headword",
                label: "Headword",
                value: entry.headword,
                emphasis: .primary
            )
        ]
        sections.append(
            DictionaryPreviewSection(
                id: "summary",
                kind: .summary,
                title: "Headword",
                rows: summaryRows,
                isExpandable: false
            )
        )

        let pronunciations = entry.pronunciations + entry.lexicalEntries.flatMap(\.pronunciations)
        let uniquePronunciations = Array(NSOrderedSet(array: pronunciations.map { pronunciation in
            [
                pronunciation.dialect ?? "",
                pronunciation.displayNotation,
            ].joined(separator: "::")
        })) as? [String] ?? []

        if !uniquePronunciations.isEmpty {
            let rows = uniquePronunciations.enumerated().map { index, value in
                let parts = value.components(separatedBy: "::")
                let dialect = parts.first?.isEmpty == false ? parts.first : nil
                let notation = parts.count > 1 ? parts[1] : value
                return DictionaryPreviewRow(
                    id: "pronunciation-\(index)",
                    label: dialect,
                    value: notation,
                    emphasis: .primary
                )
            }

            sections.append(
                DictionaryPreviewSection(
                    id: "pronunciations",
                    kind: .pronunciation,
                    title: "Pronunciation",
                    rows: rows,
                    isExpandable: rows.count > 3
                )
            )
        }

        for lexicalEntry in entry.lexicalEntries {
            var rows: [DictionaryPreviewRow] = []

            if !lexicalEntry.grammar.isEmpty {
                rows.append(
                    DictionaryPreviewRow(
                        id: "\(lexicalEntry.partOfSpeechLabel)-grammar",
                        label: "Grammar",
                        value: lexicalEntry.grammar.joined(separator: ", "),
                        emphasis: .secondary
                    )
                )
            }

            if !lexicalEntry.inflections.isEmpty {
                rows.append(
                    DictionaryPreviewRow(
                        id: "\(lexicalEntry.partOfSpeechLabel)-inflections",
                        label: "Inflections",
                        value: lexicalEntry.inflections.joined(separator: ", "),
                        emphasis: .secondary
                    )
                )
            }

            for sense in lexicalEntry.senses {
                let definitionPrefix = sense.semanticHint.map { "\($0) " } ?? ""
                rows.append(
                    DictionaryPreviewRow(
                        id: "\(lexicalEntry.partOfSpeechLabel)-sense-\(sense.number)",
                        label: "Sense \(sense.number)",
                        value: definitionPrefix + sense.definition,
                        emphasis: .primary
                    )
                )

                for (index, example) in sense.examples.enumerated() {
                    rows.append(
                        DictionaryPreviewRow(
                            id: "\(lexicalEntry.partOfSpeechLabel)-sense-\(sense.number)-example-\(index)",
                            label: "Example",
                            value: example,
                            emphasis: .secondary
                        )
                    )
                }
            }

            guard !rows.isEmpty else { continue }
            sections.append(
                DictionaryPreviewSection(
                    id: "lexical-\(lexicalEntry.partOfSpeechLabel)-\(lexicalEntry.displayIndex)",
                    kind: .lexicalEntry,
                    title: lexicalEntry.partOfSpeechLabel,
                    rows: rows,
                    isExpandable: rows.count > 4
                )
            )
        }

        for (index, group) in entry.phraseGroups.enumerated() {
            var rows: [DictionaryPreviewRow] = []

            if let rawContent = group.rawContent, !rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rows.append(
                    DictionaryPreviewRow(
                        id: "phrase-group-\(index)-raw",
                        label: nil,
                        value: rawContent,
                        emphasis: .secondary
                    )
                )
            }

            for item in group.items {
                let description = item.definition ?? item.examples.first ?? item.phrase
                rows.append(
                    DictionaryPreviewRow(
                        id: "phrase-group-\(index)-\(item.phrase)",
                        label: item.phrase,
                        value: description,
                        emphasis: .primary
                    )
                )
            }

            guard !rows.isEmpty else { continue }
            sections.append(
                DictionaryPreviewSection(
                    id: "phrase-group-\(index)",
                    kind: .phraseGroup,
                    title: group.title,
                    rows: rows,
                    isExpandable: rows.count > 3
                )
            )
        }

        for (index, note) in entry.notes.enumerated() {
            sections.append(
                DictionaryPreviewSection(
                    id: "note-\(index)",
                    kind: .note,
                    title: note.kind.rawValue.capitalized,
                    rows: [
                        DictionaryPreviewRow(
                            id: "note-\(index)-content",
                            label: nil,
                            value: note.content,
                            emphasis: .secondary
                        )
                    ],
                    isExpandable: note.content.count > 180
                )
            )
        }

        return sections
    }
}
