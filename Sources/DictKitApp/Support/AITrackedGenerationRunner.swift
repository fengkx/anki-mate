import Foundation

enum AITrackedGenerationRunner {
    @discardableResult
    @MainActor
    static func start(
        item: WordItem,
        action: AIGenerationAction,
        operation: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Never> {
        item.beginAIGeneration(action)

        return Task { @MainActor in
            defer {
                item.endAIGeneration(action)
            }

            do {
                try await operation()
            } catch is CancellationError {
                item.setAIGenerationError(nil, for: action)
            } catch {
                item.setAIGenerationError(error.localizedDescription, for: action)
            }
        }
    }
}
