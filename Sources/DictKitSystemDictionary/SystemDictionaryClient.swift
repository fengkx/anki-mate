import Foundation
import DictKit

#if os(macOS)
import CoreServices
import DictPrivate

public enum DictionaryLookupSource: Sendable, Equatable {
    case automatic
    case publicAPI
    case privateHTML(dictionaryName: String = SystemDictionaryClient.defaultDictionaryName)
}

public struct SystemDictionaryClient: Sendable {
    public static let defaultDictionaryName = "New Oxford American Dictionary"

    public init() {}

    public func listAvailableDictionaries() -> [String] {
        guard let raw = DCSCopyAvailableDictionaries() else {
            return []
        }

        return asElements(raw).compactMap { element -> String? in
            let pointer = unsafeBitCast(element as AnyObject, to: DCSDictRef.self)
            return DCSDictionaryGetName(pointer)
        }
    }

    public func lookupDefinition(for word: String) -> String? {
        let nsWord = word as NSString
        let range = CFRange(location: 0, length: nsWord.length)

        guard let definition = DCSCopyTextDefinition(nil, nsWord, range) else {
            return nil
        }

        return definition.takeRetainedValue() as String
    }

    public func lookupHTML(
        for word: String,
        dictionaryName: String = SystemDictionaryClient.defaultDictionaryName
    ) -> String? {
        switch lookupHTMLRecord(for: word, dictionaryName: dictionaryName) {
        case let .html(html):
            return html
        case .dictionaryUnavailable, .notFound, .sourceUnavailable:
            return nil
        }
    }

    public func lookup(
        _ term: String,
        source: DictionaryLookupSource = .automatic,
        includeSource: Bool = false
    ) throws -> LookupResult {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw LookupError.notFound
        }

        switch source {
        case .publicAPI:
            guard let raw = lookupDefinition(for: query) else {
                throw LookupError.notFound
            }
            return try DictionaryTextParser.parse(query: query, raw: raw, includeSource: includeSource)

        case let .privateHTML(dictionaryName):
            switch lookupHTMLRecord(for: query, dictionaryName: dictionaryName) {
            case let .html(html):
                do {
                    return try DictionaryHTMLParser.parse(query: query, html: html, includeSource: includeSource)
                } catch LookupError.parseFailed {
                    // Dictionary HTML format not supported by the parser; fall back to public API.
                    guard let raw = lookupDefinition(for: query) else {
                        throw LookupError.notFound
                    }
                    return try DictionaryTextParser.parse(query: query, raw: raw, includeSource: includeSource)
                }
            case .dictionaryUnavailable, .notFound:
                // Selected dictionary unavailable or word not found; fall back to public API.
                guard let raw = lookupDefinition(for: query) else {
                    throw LookupError.notFound
                }
                return try DictionaryTextParser.parse(query: query, raw: raw, includeSource: includeSource)
            case .sourceUnavailable:
                throw LookupError.sourceUnavailable
            }

        case .automatic:
            switch lookupHTMLRecord(for: query, dictionaryName: Self.defaultDictionaryName) {
            case let .html(html):
                return try DictionaryHTMLParser.parse(query: query, html: html, includeSource: includeSource)
            case .dictionaryUnavailable, .sourceUnavailable, .notFound:
                guard let raw = lookupDefinition(for: query) else {
                    throw LookupError.notFound
                }

                let result = try DictionaryTextParser.parse(query: query, raw: raw, includeSource: includeSource)
                let warnings = result.metadata.warnings.contains("source_fallback")
                    ? result.metadata.warnings
                    : ["source_fallback"] + result.metadata.warnings

                return LookupResult(
                    query: result.query,
                    entries: result.entries,
                    metadata: LookupMetadata(usedSource: result.metadata.usedSource, warnings: warnings),
                    source: result.source
                )
            }
        }
    }
}

private enum HTMLLookupRecord {
    case html(String)
    case dictionaryUnavailable
    case notFound
    case sourceUnavailable
}

private func lookupHTMLRecord(for word: String, dictionaryName: String) -> HTMLLookupRecord {
    guard let rawDicts = DCSCopyAvailableDictionaries() else {
        return .sourceUnavailable
    }

    var targetReference: DCSDictRef?
    for element in asElements(rawDicts) {
        let pointer = unsafeBitCast(element as AnyObject, to: DCSDictRef.self)
        if let name = DCSDictionaryGetName(pointer), name.contains(dictionaryName) {
            targetReference = pointer
            break
        }
    }

    guard let dictionaryPointer = targetReference else {
        return .dictionaryUnavailable
    }

    guard let rawRecords = DCSCopyRecordsForSearchString(dictionaryPointer, word, nil, nil) else {
        return .notFound
    }

    let records = asElements(rawRecords)
    guard !records.isEmpty, let html = DCSRecordCopyData(records[0]) else {
        return .notFound
    }

    return .html(html)
}

private func asElements(_ collection: Any?) -> [Any] {
    switch collection {
    case let array as NSArray:
        return array as! [Any]
    case let set as NSSet:
        return set.allObjects
    case let orderedSet as NSOrderedSet:
        return orderedSet.array
    default:
        return []
    }
}
#else
public enum DictionaryLookupSource: Sendable, Equatable {
    case automatic
    case publicAPI
    case privateHTML(dictionaryName: String = "")
}

public struct SystemDictionaryClient: Sendable {
    public static let defaultDictionaryName = "New Oxford American Dictionary"

    public init() {}

    public func listAvailableDictionaries() -> [String] { [] }
    public func lookupDefinition(for word: String) -> String? { nil }
    public func lookupHTML(for word: String, dictionaryName: String = Self.defaultDictionaryName) -> String? { nil }

    public func lookup(
        _ term: String,
        source: DictionaryLookupSource = .automatic,
        includeSource: Bool = false
    ) throws -> LookupResult {
        throw LookupError.sourceUnavailable
    }
}
#endif
