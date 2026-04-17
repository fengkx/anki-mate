// Model registry types — describes available GGUF models for download.

import Foundation

public struct ModelInfo: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let fileName: String
    public let url: String
    public let sizeBytes: Int64
    public let quantization: String
    public let contextSize: Int
    public let recommended: Bool

    public init(
        id: String,
        displayName: String,
        fileName: String,
        url: String,
        sizeBytes: Int64,
        quantization: String,
        contextSize: Int,
        recommended: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.fileName = fileName
        self.url = url
        self.sizeBytes = sizeBytes
        self.quantization = quantization
        self.contextSize = contextSize
        self.recommended = recommended
    }

    /// Human-readable file size (e.g., "2.8 GB").
    public var formattedSize: String {
        let gb = Double(sizeBytes) / 1_000_000_000
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        } else {
            let mb = Double(sizeBytes) / 1_000_000
            return String(format: "%.0f MB", mb)
        }
    }
}
