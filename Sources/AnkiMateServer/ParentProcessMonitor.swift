import Darwin
import Foundation

final class ParentProcessMonitor {
    private let expectedParentProcessID: Int32
    private let pollInterval: TimeInterval
    private let onParentExit: @Sendable () -> Void
    private var timer: DispatchSourceTimer?
    private var hasTriggered = false

    init(
        expectedParentProcessID: Int32,
        pollInterval: TimeInterval = 1.0,
        onParentExit: @escaping @Sendable () -> Void
    ) {
        self.expectedParentProcessID = expectedParentProcessID
        self.pollInterval = pollInterval
        self.onParentExit = onParentExit
    }

    func start() {
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.pollParentProcess()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit {
        stop()
    }

    private func pollParentProcess() {
        guard !hasTriggered else { return }

        if Self.hasLostExpectedParent(
            expectedParentProcessID: expectedParentProcessID,
            currentParentProcessID: getppid()
        ) {
            hasTriggered = true
            stop()
            onParentExit()
        }
    }

    static func hasLostExpectedParent(
        expectedParentProcessID: Int32,
        currentParentProcessID: Int32
    ) -> Bool {
        currentParentProcessID != expectedParentProcessID
    }
}
