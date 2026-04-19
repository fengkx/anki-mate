import XCTest
@testable import DictKitApp

@MainActor
final class AppTerminationCoordinatorTests: XCTestCase {
    func testRunningServerRequiresAsyncPreparationEvenWithoutSyncOrDownloads() {
        let coordinator = AppTerminationCoordinator()

        let plan = coordinator.makePlan(
            for: AppTerminationSnapshot(
                hasActiveDownloads: false,
                hasPendingSyncChanges: false,
                isSyncConfigured: false,
                isLLMServerActive: true
            )
        )

        XCTAssertEqual(
            plan,
            AppTerminationPlan(
                shouldPauseDownloads: false,
                shouldSyncPendingChanges: false,
                shouldStopLLMServer: true
            )
        )
        XCTAssertTrue(plan.requiresAsyncPreparation)
    }

    func testSyncRequiresConfigurationBeforeQuitPreparationIncludesIt() {
        let coordinator = AppTerminationCoordinator()

        let plan = coordinator.makePlan(
            for: AppTerminationSnapshot(
                hasActiveDownloads: false,
                hasPendingSyncChanges: true,
                isSyncConfigured: false,
                isLLMServerActive: false
            )
        )

        XCTAssertFalse(plan.shouldSyncPendingChanges)
        XCTAssertFalse(plan.requiresAsyncPreparation)
    }

    func testPrepareForTerminationRunsCleanupStepsInOrder() async {
        var events: [String] = []
        let coordinator = AppTerminationCoordinator(
            pauseDownloads: { events.append("pause") },
            syncNow: { events.append("sync") },
            stopLLMServer: { events.append("stop-server") }
        )
        let plan = AppTerminationPlan(
            shouldPauseDownloads: true,
            shouldSyncPendingChanges: true,
            shouldStopLLMServer: true
        )

        await coordinator.prepareForTermination(using: plan)

        XCTAssertEqual(events, ["pause", "sync", "stop-server"])
    }
}
