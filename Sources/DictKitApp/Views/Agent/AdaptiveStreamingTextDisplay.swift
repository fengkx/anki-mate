import Foundation

struct AdaptiveStreamingRatePolicy: Equatable {
    var minimumCharactersPerSecond: Double = 160
    var cruisingCharactersPerSecond: Double = 360
    var maximumCharactersPerSecond: Double = 1_800
    var targetPreviewLead: Int = 180
    var catchUpRange: Int = 520
    var smallBacklogPunctuationThreshold: Int = 24
    var lightPunctuationPause: TimeInterval = 0.008
    var strongPunctuationPause: TimeInterval = 0.016

    func speed(forBacklog backlog: Int) -> Double {
        guard backlog > 0 else { return 0 }

        if backlog <= targetPreviewLead {
            let progress = Double(backlog) / Double(max(targetPreviewLead, 1))
            return minimumCharactersPerSecond + (cruisingCharactersPerSecond - minimumCharactersPerSecond) * progress
        }

        let overshoot = Double(backlog - targetPreviewLead) / Double(max(catchUpRange, 1))
        let pressure = min(1, max(0, overshoot))
        let easedPressure = pressure * pressure * (3 - 2 * pressure)
        return cruisingCharactersPerSecond + (maximumCharactersPerSecond - cruisingCharactersPerSecond) * easedPressure
    }

    func previewWindow(forBacklog backlog: Int) -> Int {
        min(360, max(96, backlog))
    }

    func punctuationPause(after character: Character, backlog: Int) -> TimeInterval {
        guard backlog <= smallBacklogPunctuationThreshold else { return 0 }
        if Self.strongPunctuation.contains(character) {
            return strongPunctuationPause
        }
        if Self.lightPunctuation.contains(character) {
            return lightPunctuationPause
        }
        return 0
    }

    private static let lightPunctuation = Set<Character>("，,、;；:")
    private static let strongPunctuation = Set<Character>("。.!?！？\n")
}

@MainActor
final class AdaptiveStreamingTextDisplay: ObservableObject {
    @Published private(set) var committedText = ""
    @Published private(set) var previewText = ""

    private let policy: AdaptiveStreamingRatePolicy
    private let tickInterval: TimeInterval
    private let startsTaskAutomatically: Bool
    private var targetText = ""
    private var targetCharacters: [Character] = []
    private var committedCount = 0
    private var revealBudget = 0.0
    private var pauseRemaining: TimeInterval = 0
    private var revealTask: Task<Void, Never>?

    init(
        policy: AdaptiveStreamingRatePolicy = .init(),
        tickInterval: TimeInterval = 1.0 / 60.0,
        startsTaskAutomatically: Bool = true
    ) {
        self.policy = policy
        self.tickInterval = tickInterval
        self.startsTaskAutomatically = startsTaskAutomatically
    }

    var isRevealing: Bool {
        committedCount < targetCharacters.count
    }

    var targetCharacterCount: Int {
        targetCharacters.count
    }

    var committedCharacterCount: Int {
        committedCount
    }

    func reset() {
        stop()
        targetText = ""
        targetCharacters = []
        committedCount = 0
        revealBudget = 0
        pauseRemaining = 0
        committedText = ""
        previewText = ""
    }

    func stop() {
        revealTask?.cancel()
        revealTask = nil
    }

    func setTarget(_ text: String) {
        guard text != targetText else { return }

        if !text.hasPrefix(targetText) {
            stop()
            committedCount = 0
            revealBudget = 0
            pauseRemaining = 0
            committedText = ""
            previewText = ""
        }

        targetText = text
        targetCharacters = Array(text)
        committedCount = min(committedCount, targetCharacters.count)
        refreshDisplayedText()
        startRevealTaskIfNeeded()
    }

    func advance(elapsed: TimeInterval) {
        guard elapsed > 0 else { return }

        if pauseRemaining > 0 {
            pauseRemaining = max(0, pauseRemaining - elapsed)
            refreshDisplayedText()
            return
        }

        let backlog = targetCharacters.count - committedCount
        guard backlog > 0 else {
            refreshDisplayedText()
            return
        }

        revealBudget += policy.speed(forBacklog: backlog) * elapsed
        let revealCount = min(backlog, Int(revealBudget))
        guard revealCount > 0 else {
            refreshDisplayedText()
            return
        }

        committedCount += revealCount
        revealBudget -= Double(revealCount)

        if let lastCommitted = targetCharacters.prefix(committedCount).last {
            let remainingBacklog = targetCharacters.count - committedCount
            pauseRemaining = policy.punctuationPause(after: lastCommitted, backlog: remainingBacklog)
        }

        refreshDisplayedText()
    }

    private func startRevealTaskIfNeeded() {
        guard startsTaskAutomatically else { return }
        guard revealTask == nil, isRevealing else { return }
        let tickNanoseconds = UInt64(tickInterval * 1_000_000_000)
        revealTask = Task { [weak self] in
            var previousDate = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: tickNanoseconds)
                await MainActor.run {
                    guard let self else { return }
                    let now = Date()
                    self.advance(elapsed: now.timeIntervalSince(previousDate))
                    previousDate = now
                    if !self.isRevealing {
                        self.stop()
                    }
                }
            }
        }
    }

    private func refreshDisplayedText() {
        let committedEnd = min(committedCount, targetCharacters.count)
        let backlog = targetCharacters.count - committedEnd
        let previewEnd = min(
            targetCharacters.count,
            committedEnd + policy.previewWindow(forBacklog: backlog)
        )

        committedText = String(targetCharacters[..<committedEnd])
        previewText = String(targetCharacters[committedEnd..<previewEnd])
    }
}
