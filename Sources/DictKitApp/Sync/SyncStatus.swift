import Foundation

/// Observable sync state for UI binding.
@MainActor
final class SyncStatus: ObservableObject {
    @Published var state: SyncState = .idle
    @Published var lastSyncDate: Date?
    @Published var lastError: String?
    @Published var isConfigured: Bool = false
    @Published var hasPendingChanges: Bool = false

    enum SyncState: Equatable {
        case idle
        case syncing(phase: String)
        case error
    }

    var statusDescription: String {
        switch state {
        case .idle:
            if hasPendingChanges {
                return "Changes pending"
            }
            if let lastSync = lastSyncDate {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .abbreviated
                return "Synced \(formatter.localizedString(for: lastSync, relativeTo: Date()))"
            }
            return isConfigured ? "Not synced yet" : "Not configured"
        case .syncing(let phase):
            return phase
        case .error:
            return lastError ?? "Sync error"
        }
    }

    var systemImage: String {
        switch state {
        case .idle:
            if hasPendingChanges { return "arrow.up.icloud" }
            return isConfigured ? "checkmark.icloud" : "icloud.slash"
        case .syncing:
            return "arrow.triangle.2.circlepath.icloud"
        case .error:
            return "exclamationmark.icloud"
        }
    }
}
