import DictKit
import Foundation
#if canImport(AVFAudio)
import AVFAudio

public struct DictionarySpeechClient: Sendable {
    private let configuration: SpeechSynthesisConfiguration
    private let lookup: @Sendable (LookupSpeechRequest) throws -> LookupResult
    private let synthesizer: any SpeechSynthesizing

    public init(
        dictionaryClient: SystemDictionaryClient = .init(),
        configuration: SpeechSynthesisConfiguration = .init()
    ) {
        self.configuration = configuration
        self.lookup = { request in
            try dictionaryClient.lookup(request.term, source: request.source, includeSource: false)
        }
        self.synthesizer = AVSpeechSynthesizerEngine()
    }

    init(
        dictionaryClient: SystemDictionaryClient,
        configuration: SpeechSynthesisConfiguration,
        lookup: @escaping @Sendable (LookupSpeechRequest) throws -> LookupResult,
        synthesizer: any SpeechSynthesizing
    ) {
        self.configuration = configuration
        self.lookup = lookup
        self.synthesizer = synthesizer
    }

    public func speak(_ request: SpeechRequest) async throws {
        let resolved = try resolve(request)
        try await synthesizer.speak(resolved)
    }

    public func synthesize(_ request: SpeechRequest) async throws -> SynthesizedSpeech {
        let resolved = try resolve(request)
        let payload = try await synthesizer.synthesize(resolved)
        return makeSynthesizedSpeech(from: resolved, payload: payload)
    }

    public func speak(_ request: LookupSpeechRequest) async throws {
        let resolved = try resolveLookup(request)
        try await synthesizer.speak(resolved)
    }

    public func synthesize(_ request: LookupSpeechRequest) async throws -> SynthesizedSpeech {
        let resolved = try resolveLookup(request)
        let payload = try await synthesizer.synthesize(resolved)
        return makeSynthesizedSpeech(from: resolved, payload: payload)
    }

    /// Synchronous synthesis that runs AVSpeechSynthesizer on the current thread
    /// with RunLoop spinning. Must be called from the main thread.
    public func synthesizeSync(_ request: LookupSpeechRequest) throws -> SynthesizedSpeech {
        let resolved = try resolveLookup(request)
        let payload = try MainThreadSpeechHelper.synthesize(resolved)
        return makeSynthesizedSpeech(from: resolved, payload: payload)
    }

    public func resolveSpeechRequests(_ request: LookupSpeechRequest) throws -> [SpeechRequest] {
        let lookupResult: LookupResult
        do {
            lookupResult = try lookup(request)
        } catch let error as LookupError {
            throw SpeechError.lookupFailed(error)
        } catch {
            throw error
        }

        let candidates = try pronunciationCandidates(for: request, in: lookupResult)
        guard !candidates.isEmpty else {
            throw SpeechError.noPronunciationCandidates
        }
        return candidates.map { candidate in
            SpeechRequest(text: lookupResult.entries.first?.headword ?? request.term, pronunciation: candidate, sourceLabel: "dictionary")
        }
    }

    public func synthesizeBatch(_ requests: [SpeechRequest]) async -> BatchSynthesizedSpeech {
        var successes: [SynthesizedSpeech] = []
        var failures: [BatchSpeechFailure] = []

        for request in requests {
            do {
                successes.append(try await synthesize(request))
            } catch let speechError as SpeechError {
                failures.append(BatchSpeechFailure(text: request.text, sourceLabel: request.sourceLabel, error: speechError))
            } catch {
                failures.append(BatchSpeechFailure(text: request.text, sourceLabel: request.sourceLabel, error: .synthesisUnavailable))
            }
        }

        return BatchSynthesizedSpeech(successes: successes, failures: failures)
    }

    public func synthesizeBatch(_ requests: [LookupSpeechRequest]) async -> BatchSynthesizedSpeech {
        var successes: [SynthesizedSpeech] = []
        var failures: [BatchSpeechFailure] = []

        for request in requests {
            do {
                let resolvedRequests = try expandedRequests(for: request)
                let batch = await synthesizeBatch(resolvedRequests)
                successes.append(contentsOf: batch.successes)
                failures.append(contentsOf: batch.failures)
            } catch let speechError as SpeechError {
                failures.append(BatchSpeechFailure(text: request.term, sourceLabel: "dictionary", error: speechError))
            } catch {
                failures.append(BatchSpeechFailure(text: request.term, sourceLabel: "dictionary", error: .synthesisUnavailable))
            }
        }

        return BatchSynthesizedSpeech(successes: successes, failures: failures)
    }

    private func expandedRequests(for request: LookupSpeechRequest) throws -> [SpeechRequest] {
        if request.selection == .allCandidates {
            let requests = try resolveSpeechRequests(request)
            guard !requests.isEmpty else {
                throw SpeechError.noPronunciationCandidates
            }
            return requests
        }

        let lookupResult: LookupResult
        do {
            lookupResult = try lookup(request)
        } catch let error as LookupError {
            throw SpeechError.lookupFailed(error)
        } catch {
            throw error
        }

        let resolved = try resolveLookup(request, lookupResult: lookupResult)
        return [SpeechRequest(text: resolved.text, pronunciation: resolved.pronunciation, sourceLabel: resolved.sourceLabel)]
    }

    private func resolveLookup(_ request: LookupSpeechRequest) throws -> ResolvedSpeechRequest {
        // For automatic source, prefer public API first — it returns real IPA
        // that AVSpeechSynthesizer can use. Fall back to HTML source only when
        // the public API has no usable IPA (e.g. word not found).
        if request.source == .automatic {
            let publicRequest = LookupSpeechRequest(
                term: request.term,
                source: .publicAPI,
                selection: request.selection
            )
            if let publicResult = try? lookup(publicRequest),
               let resolved = try? resolveLookup(publicRequest, lookupResult: publicResult),
               !resolved.didFallbackToText {
                return resolved
            }
        }

        let lookupResult: LookupResult
        do {
            lookupResult = try lookup(request)
        } catch let error as LookupError {
            throw SpeechError.lookupFailed(error)
        } catch {
            throw error
        }

        return try resolveLookup(request, lookupResult: lookupResult)
    }

    private func resolveLookup(_ request: LookupSpeechRequest, lookupResult: LookupResult) throws -> ResolvedSpeechRequest {
        guard request.selection != .allCandidates else {
            throw SpeechError.invalidRequest("Use resolveSpeechRequests(_:) or synthesizeBatch(_:) with .allCandidates.")
        }

        let candidates = try pronunciationCandidates(for: request, in: lookupResult)
        let selected = try selectPronunciation(for: request, candidates: candidates)
        if selected == nil, request.selection != .preferredDialectFirst {
            throw SpeechError.noPronunciationCandidates
        }

        return try resolve(
            SpeechRequest(
                text: lookupResult.entries.first?.headword ?? request.term,
                pronunciation: selected,
                sourceLabel: "dictionary"
            )
        )
    }

    private func pronunciationCandidates(for request: LookupSpeechRequest, in lookupResult: LookupResult) throws -> [Pronunciation] {
        let entries = lookupResult.entries
        let allHeadwordPronunciations = uniquePronunciations(entries.flatMap(\.pronunciations))

        switch request.selection {
        case .preferredDialectFirst, .exactDialect, .allCandidates:
            let lexical = entries.flatMap(\.lexicalEntries).flatMap(\.pronunciations)
            return sortPronunciations(uniquePronunciations(allHeadwordPronunciations + lexical))

        case let .exact(pronunciation):
            return [pronunciation]

        case let .lexicalEntry(index, dialect):
            let lexicalEntries = entries.flatMap(\.lexicalEntries)
            guard lexicalEntries.indices.contains(index) else {
                throw SpeechError.noPronunciationCandidates
            }
            let pronunciations = sortPronunciations(lexicalEntries[index].pronunciations)
            if let dialect {
                return pronunciations.filter { $0.dialect?.caseInsensitiveCompare(dialect) == .orderedSame }
            }
            return pronunciations
        }
    }

    private func selectPronunciation(
        for request: LookupSpeechRequest,
        candidates: [Pronunciation]
    ) throws -> Pronunciation? {
        switch request.selection {
        case .preferredDialectFirst, .lexicalEntry:
            return candidates.first
        case let .exact(pronunciation):
            return pronunciation
        case let .exactDialect(dialect):
            return candidates.first { $0.dialect?.caseInsensitiveCompare(dialect) == .orderedSame }
        case .allCandidates:
            return candidates.first
        }
    }

    private func resolve(_ request: SpeechRequest) throws -> ResolvedSpeechRequest {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw SpeechError.invalidRequest("Speech text must not be empty.")
        }

        var warnings: [String] = []
        let pronunciation = request.pronunciation?.ttsIPANotation == nil ? nil : request.pronunciation
        let didFallbackToText = pronunciation == nil

        if didFallbackToText {
            switch configuration.fallbackPolicy {
            case .useHeadwordText:
                warnings.append("missing_pronunciation_fallback")
            case .failIfNoPronunciation:
                throw SpeechError.noPronunciationCandidates
            }
        }

        let availableVoices = SpeechVoiceResolver.availableVoices()
        let resolvedVoice = SpeechVoiceResolver.resolveVoice(
            for: pronunciation,
            configuration: configuration,
            availableVoices: availableVoices
        )

        if let voiceIdentifier = configuration.voiceIdentifier, resolvedVoice == nil {
            throw SpeechError.voiceNotFound(voiceIdentifier)
        }

        return ResolvedSpeechRequest(
            text: text,
            pronunciation: pronunciation,
            sourceLabel: request.sourceLabel,
            didFallbackToText: didFallbackToText,
            warnings: warnings,
            configuration: configuration,
            voice: resolvedVoice,
            languageHint: resolvedVoice?.language
                ?? pronunciation?.defaultSpeechLanguageCode
                ?? configuration.languageHint
        )
    }

    private func sortPronunciations(_ pronunciations: [Pronunciation]) -> [Pronunciation] {
        let order = configuration.preferredDialectOrder
        return pronunciations.sorted { lhs, rhs in
            let lhsIndex = order.firstIndex { $0.caseInsensitiveCompare(lhs.dialect ?? "") == .orderedSame } ?? Int.max
            let rhsIndex = order.firstIndex { $0.caseInsensitiveCompare(rhs.dialect ?? "") == .orderedSame } ?? Int.max
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return lhs.ipa < rhs.ipa
        }
    }

    private func makeSynthesizedSpeech(
        from request: ResolvedSpeechRequest,
        payload: SynthesizedSpeechPayload
    ) -> SynthesizedSpeech {
        SynthesizedSpeech(
            audioData: payload.audioData,
            textSpoken: request.text,
            pronunciationUsed: request.pronunciation,
            voiceIdentifier: payload.voiceIdentifier,
            language: payload.language,
            didFallbackToText: request.didFallbackToText,
            warnings: request.warnings
        )
    }
}

private actor AVSpeechSynthesizerEngine: SpeechSynthesizing {
    func speak(_ request: ResolvedSpeechRequest) async throws {
        try MainThreadSpeechHelper.speak(request)
    }

    func synthesize(_ request: ResolvedSpeechRequest) async throws -> SynthesizedSpeechPayload {
        try MainThreadSpeechHelper.synthesize(request)
    }
}

/// Runs AVSpeechSynthesizer synchronously on the main thread.
/// AVSpeechSynthesizer requires the main RunLoop to process its audio callbacks.
/// This helper ensures the synthesizer is created, used, and waited on directly
/// from the main thread, spinning the RunLoop to process callbacks.
private enum MainThreadSpeechHelper {
    static func speak(_ request: ResolvedSpeechRequest) throws {
        assert(Thread.isMainThread, "Must be called from the main thread")
        let synthesizer = AVSpeechSynthesizer()
        let delegate = SpeechDelegate()
        synthesizer.delegate = delegate
        synthesizer.speak(Self.makeUtterance(from: request))
        try waitUntilCompleted { delegate.didFinish || delegate.didCancel }
        if delegate.didCancel {
            throw SpeechError.synthesisUnavailable
        }
    }

    static func synthesize(_ request: ResolvedSpeechRequest) throws -> SynthesizedSpeechPayload {
        assert(Thread.isMainThread, "Must be called from the main thread")
        let synthesizer = AVSpeechSynthesizer()
        let delegate = SpeechDelegate()
        synthesizer.delegate = delegate
        let utterance = makeUtterance(from: request)
        var buffers: [AVAudioPCMBuffer] = []

        synthesizer.write(utterance) { buffer in
            if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                if let copy = copyBuffer(pcm) {
                    buffers.append(copy)
                }
            }
        }

        // Wait for the delegate's didFinish callback rather than relying on
        // a zero-length completion buffer, which is not sent on all macOS versions.
        try waitUntilCompleted { delegate.didFinish || delegate.didCancel }
        if delegate.didCancel {
            throw SpeechError.synthesisUnavailable
        }
        let audioData = try SpeechAudioEncoder.encodeWave(from: buffers)
        return SynthesizedSpeechPayload(
            audioData: audioData,
            voiceIdentifier: utterance.voice?.identifier,
            language: utterance.voice?.language ?? request.languageHint
        )
    }

    private static func waitUntilCompleted(_ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard predicate() else {
            throw SpeechError.synthesisUnavailable
        }
    }

    private static func makeUtterance(from request: ResolvedSpeechRequest) -> AVSpeechUtterance {
        let utterance: AVSpeechUtterance
        if let ipa = request.pronunciation?.ttsIPANotation {
            let attributed = NSMutableAttributedString(string: request.text)
            attributed.addAttribute(
                NSAttributedString.Key(rawValue: AVSpeechSynthesisIPANotationAttribute),
                value: ipa,
                range: NSRange(location: 0, length: attributed.length)
            )
            utterance = AVSpeechUtterance(attributedString: attributed)
        } else {
            utterance = AVSpeechUtterance(string: request.text)
        }

        if let identifier = request.voice?.identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
        } else if let language = request.languageHint, let voice = AVSpeechSynthesisVoice(language: language) {
            utterance.voice = voice
        }

        if let rate = request.configuration.rate {
            utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, rate))
        }
        if let pitch = request.configuration.pitchMultiplier {
            utterance.pitchMultiplier = max(0.5, min(2.0, pitch))
        }
        if let volume = request.configuration.volume {
            utterance.volume = max(0, min(1, volume))
        }
        if let preDelay = request.configuration.preUtteranceDelay {
            utterance.preUtteranceDelay = max(0, preDelay)
        }
        if let postDelay = request.configuration.postUtteranceDelay {
            utterance.postUtteranceDelay = max(0, postDelay)
        }

        return utterance
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let source = buffer.floatChannelData, let destination = copy.floatChannelData else {
                return nil
            }
            for channel in 0..<channelCount {
                destination[channel].update(from: source[channel], count: frameCount)
            }
        case .pcmFormatInt16:
            guard let source = buffer.int16ChannelData, let destination = copy.int16ChannelData else {
                return nil
            }
            for channel in 0..<channelCount {
                destination[channel].update(from: source[channel], count: frameCount)
            }
        default:
            return nil
        }

        return copy
    }
}

private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var didFinish = false
    var didCancel = false

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        didFinish = true
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        didCancel = true
    }
}

private func uniquePronunciations(_ pronunciations: [Pronunciation]) -> [Pronunciation] {
    var result: [Pronunciation] = []
    for pronunciation in pronunciations where !result.contains(pronunciation) {
        result.append(pronunciation)
    }
    return result
}
#else
public struct DictionarySpeechClient: Sendable {
    public init(
        dictionaryClient: SystemDictionaryClient = .init(),
        configuration: SpeechSynthesisConfiguration = .init()
    ) {}

    public func speak(_ request: SpeechRequest) async throws { throw SpeechError.synthesisUnavailable }
    public func synthesize(_ request: SpeechRequest) async throws -> SynthesizedSpeech { throw SpeechError.synthesisUnavailable }
    public func speak(_ request: LookupSpeechRequest) async throws { throw SpeechError.synthesisUnavailable }
    public func synthesize(_ request: LookupSpeechRequest) async throws -> SynthesizedSpeech { throw SpeechError.synthesisUnavailable }
    public func synthesizeBatch(_ requests: [SpeechRequest]) async -> BatchSynthesizedSpeech { BatchSynthesizedSpeech(successes: [], failures: requests.map { BatchSpeechFailure(text: $0.text, sourceLabel: $0.sourceLabel, error: .synthesisUnavailable) }) }
    public func synthesizeBatch(_ requests: [LookupSpeechRequest]) async -> BatchSynthesizedSpeech { BatchSynthesizedSpeech(successes: [], failures: requests.map { BatchSpeechFailure(text: $0.term, sourceLabel: "dictionary", error: .synthesisUnavailable) }) }
    public func resolveSpeechRequests(_ request: LookupSpeechRequest) throws -> [SpeechRequest] { throw SpeechError.synthesisUnavailable }
}
#endif
