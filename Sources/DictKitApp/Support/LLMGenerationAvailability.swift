import AnkiMateLLM

enum LLMGenerationAvailability {
    static let alertTitle = "AI is not available"
    static let alertMessage = "Enable local AI in AI settings before generating content."
    static let settingsButtonTitle = "Open AI Settings"

    static func shouldPromptForManualAction(
        hasModel: Bool,
        serverState: ServerProcessManager.State,
        error: Error? = nil
    ) -> Bool {
        if !hasModel {
            return true
        }

        if case .failed = serverState {
            return true
        }

        if let error {
            return isAvailabilityError(error)
        }

        return false
    }

    static func isAvailabilityError(_ error: Error) -> Bool {
        if let serviceError = error as? LLMServiceError {
            switch serviceError {
            case .serverNotAvailable, .noModelSelected, .modelNotDownloaded:
                return true
            case .invalidStructuredOutput:
                return false
            }
        }

        if let rpcError = error as? RPCClientError {
            switch rpcError {
            case .serverNotRunning:
                return true
            case .httpError, .decodingError, .rpcError:
                return false
            }
        }

        return false
    }
}
