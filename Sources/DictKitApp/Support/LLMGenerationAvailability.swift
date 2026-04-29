import AnkiMateLLM

enum LLMGenerationAvailability {
    enum State: Equatable {
        case available
        case noModelConfigured
        case byokNotConfigured
        case modelAvailableServiceIdle
        case preparing
        case runtimeMissing
        case serviceFailedToStart
        case temporarilyUnavailable
    }

    enum Action {
        case examples
        case learningAids
        case usage
        case recallCard
        case pronunciationEnhancement
        case agentChat
    }

    struct AlertContent: Equatable, Identifiable {
        let state: State
        let title: String
        let message: String
        let settingsButtonTitle: String

        var id: String { "\(state)" }
    }

    static let settingsButtonTitle = "Open AI Settings"

    static func resolvedState(
        backendMode: LLMBackendMode = .local,
        hasModel: Bool,
        hasBYOKConfiguration: Bool = false,
        serverState: ServerProcessManager.State,
        error: Error? = nil
    ) -> State {
        if backendMode == .openAICompatible {
            return hasBYOKConfiguration ? .available : .byokNotConfigured
        }

        if !hasModel {
            return .noModelConfigured
        }

        if let error {
            if let resolvedFailure = stateForFailedServer(serverState) {
                return resolvedFailure
            }

            if isAvailabilityError(error) {
                return .temporarilyUnavailable
            }
        }

        switch serverState {
        case .running:
            return .available
        case .starting:
            return .preparing
        case .stopped:
            return .modelAvailableServiceIdle
        case .failed:
            return stateForFailedServer(serverState) ?? .temporarilyUnavailable
        }
    }

    static func shouldPromptForManualAction(
        hasModel: Bool,
        serverState: ServerProcessManager.State,
        error: Error? = nil
    ) -> Bool {
        switch resolvedState(hasModel: hasModel, serverState: serverState, error: error) {
        case .available, .modelAvailableServiceIdle, .preparing:
            return false
        case .noModelConfigured, .byokNotConfigured, .runtimeMissing, .serviceFailedToStart, .temporarilyUnavailable:
            return true
        }
    }

    static func isAvailabilityError(_ error: Error) -> Bool {
        if let serviceError = error as? LLMServiceError {
            switch serviceError {
            case .serverNotAvailable, .noModelSelected, .modelNotDownloaded, .byokNotConfigured:
                return true
            case .invalidStructuredOutput:
                return false
            }
        }

        if let rpcError = error as? RPCClientError {
            switch rpcError {
            case .serverNotRunning:
                return true
            case .httpError, .decodingError, .rpcError, .upstreamError:
                return false
            }
        }

        return false
    }

    static func alertContent(
        for state: State
    ) -> AlertContent {
        switch state {
        case .noModelConfigured:
            return AlertContent(
                state: state,
                title: "Local AI is not set up yet",
                message: "Download and select a model in AI Settings to generate AI content.",
                settingsButtonTitle: settingsButtonTitle
            )
        case .byokNotConfigured:
            return AlertContent(
                state: state,
                title: "Bring Your Own Key is not set up yet",
                message: "Add an OpenAI-compatible base URL, model, and API key in AI Settings to generate AI content.",
                settingsButtonTitle: settingsButtonTitle
            )
        case .runtimeMissing:
            return AlertContent(
                state: state,
                title: "Local AI runtime is missing",
                message: "This copy of the app is missing the local AI runtime. Reinstall or update the app. If you built from source, run `just build` and launch the app again.",
                settingsButtonTitle: settingsButtonTitle
            )
        case .serviceFailedToStart:
            return AlertContent(
                state: state,
                title: "Local AI could not start",
                message: "Try again. If it keeps failing, restart the app or open AI Settings.",
                settingsButtonTitle: settingsButtonTitle
            )
        case .temporarilyUnavailable:
            return AlertContent(
                state: state,
                title: "Local AI is temporarily unavailable",
                message: "Try again in a moment, or open AI Settings if the problem keeps happening.",
                settingsButtonTitle: settingsButtonTitle
            )
        case .available, .modelAvailableServiceIdle, .preparing:
            return AlertContent(
                state: state,
                title: "AI is not available",
                message: "Enable local AI in AI settings before generating content.",
                settingsButtonTitle: settingsButtonTitle
            )
        }
    }

    static func actionMessage(for action: Action, state: State) -> String? {
        switch state {
        case .noModelConfigured:
            switch action {
            case .examples:
                return "Set up local AI in AI Settings to generate examples."
            case .learningAids:
                return "Set up local AI in AI Settings to generate learning aids."
            case .usage:
                return "Set up local AI in AI Settings to generate a usage cue."
            case .recallCard:
                return "Set up local AI in AI Settings to draft a recall card."
            case .pronunciationEnhancement:
                return "Set up local AI in AI Settings to generate pronunciation aids."
            case .agentChat:
                return "Set up local AI in AI Settings to start Agent Chat."
            }
        case .byokNotConfigured:
            switch action {
            case .examples:
                return "Set up Bring Your Own Key in AI Settings to generate examples."
            case .learningAids:
                return "Set up Bring Your Own Key in AI Settings to generate learning aids."
            case .usage:
                return "Set up Bring Your Own Key in AI Settings to generate a usage cue."
            case .recallCard:
                return "Set up Bring Your Own Key in AI Settings to draft a recall card."
            case .pronunciationEnhancement:
                return "Set up Bring Your Own Key in AI Settings to generate pronunciation aids."
            case .agentChat:
                return "Set up Bring Your Own Key in AI Settings to start Agent Chat."
            }
        case .runtimeMissing:
            return "This copy of the app is missing the local AI runtime."
        case .serviceFailedToStart:
            return "Local AI needs attention before it can generate new content."
        case .temporarilyUnavailable:
            return "Local AI is temporarily unavailable."
        case .available, .modelAvailableServiceIdle, .preparing:
            return nil
        }
    }

    static func bannerContent(for state: State) -> AlertContent? {
        switch state {
        case .noModelConfigured, .byokNotConfigured, .runtimeMissing, .serviceFailedToStart:
            return alertContent(for: state)
        case .available, .modelAvailableServiceIdle, .preparing, .temporarilyUnavailable:
            return nil
        }
    }

    private static func stateForFailedServer(_ state: ServerProcessManager.State) -> State? {
        guard case .failed(let message) = state else { return nil }
        if message == "Server binary not found" {
            return .runtimeMissing
        }
        return .serviceFailedToStart
    }
}
