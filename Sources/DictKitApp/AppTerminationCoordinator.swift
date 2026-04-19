import Foundation

struct AppTerminationSnapshot: Equatable {
    var hasActiveDownloads: Bool
    var hasPendingSyncChanges: Bool
    var isSyncConfigured: Bool
    var isLLMServerActive: Bool
}

struct AppTerminationPlan: Equatable {
    var shouldPauseDownloads: Bool
    var shouldSyncPendingChanges: Bool
    var shouldStopLLMServer: Bool

    var requiresAsyncPreparation: Bool {
        shouldPauseDownloads || shouldSyncPendingChanges || shouldStopLLMServer
    }
}

@MainActor
struct AppTerminationCoordinator {
    var pauseDownloads: () async -> Void = {}
    var syncNow: () async -> Void = {}
    var stopLLMServer: () async -> Void = {}

    func makePlan(for snapshot: AppTerminationSnapshot) -> AppTerminationPlan {
        AppTerminationPlan(
            shouldPauseDownloads: snapshot.hasActiveDownloads,
            shouldSyncPendingChanges: snapshot.isSyncConfigured && snapshot.hasPendingSyncChanges,
            shouldStopLLMServer: snapshot.isLLMServerActive
        )
    }

    func prepareForTermination(using plan: AppTerminationPlan) async {
        if plan.shouldPauseDownloads {
            await pauseDownloads()
        }

        if plan.shouldSyncPendingChanges {
            await syncNow()
        }

        if plan.shouldStopLLMServer {
            await stopLLMServer()
        }
    }
}
