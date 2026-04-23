import Foundation

actor LLMInferenceRequestGate {
    struct Lease: Equatable, Sendable {
        fileprivate let id: UUID
    }

    private var activeLeaseID: UUID?
    private var waitingForegroundRequests = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquireForegroundLease() async throws -> Lease {
        waitingForegroundRequests += 1
        var acquiredLease = false
        defer {
            if !acquiredLease {
                waitingForegroundRequests -= 1
                if activeLeaseID == nil {
                    resumeWaiters()
                }
            }
        }

        while activeLeaseID != nil {
            try Task.checkCancellation()
            await waitUntilAvailable()
        }

        let lease = Lease(id: UUID())
        activeLeaseID = lease.id
        waitingForegroundRequests -= 1
        acquiredLease = true
        return lease
    }

    func tryAcquireWarmupLease() -> Lease? {
        guard waitingForegroundRequests == 0, activeLeaseID == nil else {
            return nil
        }

        let lease = Lease(id: UUID())
        activeLeaseID = lease.id
        return lease
    }

    func release(_ lease: Lease) {
        guard activeLeaseID == lease.id else { return }
        activeLeaseID = nil
        resumeWaiters()
    }

    private func waitUntilAvailable() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func resumeWaiters() {
        let pendingWaiters = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}
