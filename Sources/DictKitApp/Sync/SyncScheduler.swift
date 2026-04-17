import Foundation
import Network

/// Triggers sync on a timer and when network becomes available.
@MainActor
final class SyncScheduler {
    private var timer: Timer?
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "sync-network-monitor")
    private nonisolated(unsafe) var isNetworkAvailable = true

    let engine: SyncEngine
    let status: SyncStatus

    init(engine: SyncEngine, status: SyncStatus) {
        self.engine = engine
        self.status = status
    }

    func start() {
        // Start network monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let wasAvailable = self.isNetworkAvailable
            self.isNetworkAvailable = path.status == .satisfied
            if !wasAvailable && path.status == .satisfied {
                Task { @MainActor [weak self] in
                    await self?.engine.sync()
                }
            }
        }
        monitor.start(queue: monitorQueue)

        // Start periodic timer based on saved interval
        restartTimer()
    }

    /// Update the sync interval and restart the timer.
    func updateInterval(_ interval: SyncInterval) {
        interval.save()
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil

        let interval = SyncInterval.load()
        guard interval != .manual else { return }

        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval.rawValue), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isNetworkAvailable else { return }
                guard WebDAVCredentials.load().isConfigured else { return }
                await self.engine.sync()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        monitor.cancel()
    }

    /// Trigger an immediate sync.
    func syncNow() async {
        guard WebDAVCredentials.load().isConfigured else { return }
        await engine.sync()
    }

    /// Synchronous sync for app termination. Blocks up to `timeout` seconds.
    nonisolated func syncBeforeQuit(timeout: TimeInterval = 15) {
        guard WebDAVCredentials.load().isConfigured else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor [weak self] in
            await self?.engine.sync()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }
}
