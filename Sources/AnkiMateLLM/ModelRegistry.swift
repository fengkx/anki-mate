// Model registry — reads the bundled models-registry.json.

import Foundation
import AnkiMateRPC

public struct ModelRegistry: Sendable {
    public let models: [ModelInfo]

    public init() {
        guard let url = Bundle.module.url(forResource: "models-registry", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ModelInfo].self, from: data) else {
            self.models = []
            return
        }
        self.models = decoded
    }

    public var recommended: ModelInfo? {
        models.first(where: \.recommended) ?? models.first
    }
}
