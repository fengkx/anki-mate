import AnkiMateLLM

struct LLMServerStatusGuidance: Equatable {
    let summary: String
    let statusText: String
    let actionHint: String
    let actionButtonTitle: String

    static func make(
        for state: ServerProcessManager.State,
        hasModel: Bool = true
    ) -> LLMServerStatusGuidance {
        if !hasModel {
            return .init(
                summary: "Local AI is not set up yet.",
                statusText: "Model required",
                actionHint: "Download and select a model in AI Settings to generate AI content.",
                actionButtonTitle: "Download Model"
            )
        }

        switch state {
        case .running:
            return .init(
                summary: "Ready for local AI features.",
                statusText: "Running",
                actionHint: "The local service is available and can be used when AI content is needed.",
                actionButtonTitle: "Stop"
            )
        case .starting:
            return .init(
                summary: "The local service is starting.",
                statusText: "Starting...",
                actionHint: "This usually takes a few seconds.",
                actionButtonTitle: "Starting..."
            )
        case .stopped:
            return .init(
                summary: "The service is currently off.",
                statusText: "Stopped",
                actionHint: "It can be started again when needed.",
                actionButtonTitle: "Start"
            )
        case .failed(let message):
            return failedGuidance(for: message)
        }
    }

    private static func failedGuidance(for message: String) -> LLMServerStatusGuidance {
        if message == "Server binary not found" {
            return .init(
                summary: "This copy of the app is missing the local AI runtime.",
                statusText: "Local AI components are missing",
                actionHint: "Reinstall or update the app. If you built from source, run `just build` and launch the app again.",
                actionButtonTitle: "Try Again"
            )
        }

        if message == "Server did not report listening port" {
            return .init(
                summary: "The local service did not finish starting.",
                statusText: "Local AI could not start",
                actionHint: "Try again. If it keeps failing, restart the app. Logs are only needed for advanced troubleshooting.",
                actionButtonTitle: "Try Again"
            )
        }

        if message.hasPrefix("Failed to launch server:") {
            return .init(
                summary: "The app could not launch the local AI service.",
                statusText: "Local AI could not start",
                actionHint: "Try again. If it keeps failing, restart the app or reinstall the app.",
                actionButtonTitle: "Try Again"
            )
        }

        return .init(
            summary: "The service needs attention before it can be used.",
            statusText: "Local AI needs attention",
            actionHint: "Try again. If it keeps failing, restart the app and then collect logs for support.",
            actionButtonTitle: "Try Again"
        )
    }
}
