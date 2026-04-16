import DictKit
import Foundation

public struct SpeechSynthesisConfiguration: Sendable, Equatable {
    public var preferredDialectOrder: [String]
    public var fallbackPolicy: SpeechFallbackPolicy
    public var rate: Float?
    public var pitchMultiplier: Float?
    public var volume: Float?
    public var preUtteranceDelay: TimeInterval?
    public var postUtteranceDelay: TimeInterval?
    public var useIPA: Bool
    public var voiceIdentifier: String?
    public var languageHint: String?

    public init(
        preferredDialectOrder: [String] = ["AmE", "BrE"],
        fallbackPolicy: SpeechFallbackPolicy = .useHeadwordText,
        rate: Float? = nil,
        pitchMultiplier: Float? = nil,
        volume: Float? = nil,
        preUtteranceDelay: TimeInterval? = nil,
        postUtteranceDelay: TimeInterval? = nil,
        useIPA: Bool = false,
        voiceIdentifier: String? = nil,
        languageHint: String? = nil
    ) {
        self.preferredDialectOrder = preferredDialectOrder
        self.fallbackPolicy = fallbackPolicy
        self.rate = rate
        self.pitchMultiplier = pitchMultiplier
        self.volume = volume
        self.preUtteranceDelay = preUtteranceDelay
        self.postUtteranceDelay = postUtteranceDelay
        self.useIPA = useIPA
        self.voiceIdentifier = voiceIdentifier
        self.languageHint = languageHint
    }
}

public enum SpeechFallbackPolicy: Sendable, Equatable {
    case useHeadwordText
    case failIfNoPronunciation
}

public struct SpeechRequest: Sendable, Equatable {
    public let text: String
    public let pronunciation: Pronunciation?
    public let sourceLabel: String?

    public init(text: String, pronunciation: Pronunciation?, sourceLabel: String?) {
        self.text = text
        self.pronunciation = pronunciation
        self.sourceLabel = sourceLabel
    }
}

public struct LookupSpeechRequest: Sendable, Equatable {
    public let term: String
    public let source: DictionaryLookupSource
    public let selection: PronunciationSelection

    public init(term: String, source: DictionaryLookupSource, selection: PronunciationSelection) {
        self.term = term
        self.source = source
        self.selection = selection
    }
}

public enum PronunciationSelection: Sendable, Equatable {
    case preferredDialectFirst
    case exact(Pronunciation)
    case exactDialect(String)
    case lexicalEntry(index: Int, dialect: String?)
    case allCandidates
}

public struct SynthesizedSpeech: Sendable, Equatable {
    public let audioData: Data
    public let contentType: String
    public let fileExtension: String
    public let textSpoken: String
    public let pronunciationUsed: Pronunciation?
    public let voiceIdentifier: String?
    public let language: String?
    public let didFallbackToText: Bool
    public let warnings: [String]

    public init(
        audioData: Data,
        contentType: String = "audio/wav",
        fileExtension: String = "wav",
        textSpoken: String,
        pronunciationUsed: Pronunciation?,
        voiceIdentifier: String?,
        language: String?,
        didFallbackToText: Bool,
        warnings: [String]
    ) {
        self.audioData = audioData
        self.contentType = contentType
        self.fileExtension = fileExtension
        self.textSpoken = textSpoken
        self.pronunciationUsed = pronunciationUsed
        self.voiceIdentifier = voiceIdentifier
        self.language = language
        self.didFallbackToText = didFallbackToText
        self.warnings = warnings
    }
}

public struct BatchSpeechFailure: Sendable, Equatable {
    public let text: String
    public let sourceLabel: String?
    public let error: SpeechError

    public init(text: String, sourceLabel: String?, error: SpeechError) {
        self.text = text
        self.sourceLabel = sourceLabel
        self.error = error
    }
}

public struct BatchSynthesizedSpeech: Sendable, Equatable {
    public let successes: [SynthesizedSpeech]
    public let failures: [BatchSpeechFailure]

    public init(successes: [SynthesizedSpeech], failures: [BatchSpeechFailure]) {
        self.successes = successes
        self.failures = failures
    }
}

public enum SpeechError: Error, Sendable, Equatable {
    case synthesisUnavailable
    case voiceNotFound(String)
    case noPronunciationCandidates
    case audioEncodingFailed
    case invalidRequest(String)
    case lookupFailed(LookupError)
}

struct SpeechVoiceDescriptor: Sendable, Equatable {
    let identifier: String
    let language: String
    let name: String
    let quality: Int
}

struct ResolvedSpeechRequest: Sendable, Equatable {
    let text: String
    let pronunciation: Pronunciation?
    let sourceLabel: String?
    let didFallbackToText: Bool
    let warnings: [String]
    let configuration: SpeechSynthesisConfiguration
    let voice: SpeechVoiceDescriptor?
    let languageHint: String?
}

struct SynthesizedSpeechPayload: Sendable, Equatable {
    let audioData: Data
    let voiceIdentifier: String?
    let language: String?
}

protocol SpeechSynthesizing: Sendable {
    func speak(_ request: ResolvedSpeechRequest) async throws
    func synthesize(_ request: ResolvedSpeechRequest) async throws -> SynthesizedSpeechPayload
}
