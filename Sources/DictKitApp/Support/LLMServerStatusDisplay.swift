import Foundation

enum LLMServerStatusDisplay {
    struct Endpoint: Equatable {
        let label: String
        let value: String
        let isAvailable: Bool
    }

    static func endpoints(
        ankimateServerPort: Int?,
        llamaServerPort: Int?
    ) -> [Endpoint] {
        [
            Endpoint(
                label: "AnkiMate server",
                value: endpointValue(for: ankimateServerPort, unavailableText: "Waiting for port"),
                isAvailable: ankimateServerPort != nil
            ),
            Endpoint(
                label: "llama-server",
                value: endpointValue(for: llamaServerPort ?? inferredLlamaServerPort(from: ankimateServerPort), unavailableText: "Waiting for model"),
                isAvailable: llamaServerPort != nil
            )
        ]
    }

    private static func inferredLlamaServerPort(from ankimateServerPort: Int?) -> Int? {
        ankimateServerPort.map { $0 + 1 }
    }

    private static func formattedPort(_ port: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: port), number: .decimal)
    }

    private static func endpointValue(for port: Int?, unavailableText: String) -> String {
        guard let port else { return unavailableText }
        return formattedPort(port)
    }
}
