import Darwin
import Foundation

final class ServerSignalShutdownCoordinator {
    private let signalNumbers: [Int32]
    private let shutdown: () -> Void
    private var sources: [DispatchSourceSignal] = []
    private var didRequestShutdown = false
    private let lock = NSLock()

    init(
        signalNumbers: [Int32] = [SIGTERM, SIGINT],
        shutdown: @escaping () -> Void
    ) {
        self.signalNumbers = signalNumbers
        self.shutdown = shutdown
    }

    func start() {
        guard sources.isEmpty else { return }

        sources = signalNumbers.map { signalNumber in
            signal(signalNumber, SIG_IGN)

            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler { [weak self] in
                self?.requestShutdown()
            }
            source.resume()
            return source
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources = []
    }

    deinit {
        stop()
    }

    func handleSignalForTesting() {
        requestShutdown()
    }

    private func requestShutdown() {
        lock.lock()
        defer { lock.unlock() }

        guard !didRequestShutdown else { return }
        didRequestShutdown = true
        shutdown()
    }
}
