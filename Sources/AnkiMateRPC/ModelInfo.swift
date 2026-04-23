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
    public let supportsVision: Bool
    public let mmprojFileName: String?
    public let mmprojURL: String?
    public let mmprojSizeBytes: Int64?

    public init(
        id: String,
        displayName: String,
        fileName: String,
        url: String,
        sizeBytes: Int64,
        quantization: String,
        contextSize: Int,
        recommended: Bool = false,
        supportsVision: Bool = false,
        mmprojFileName: String? = nil,
        mmprojURL: String? = nil,
        mmprojSizeBytes: Int64? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.fileName = fileName
        self.url = url
        self.sizeBytes = sizeBytes
        self.quantization = quantization
        self.contextSize = contextSize
        self.recommended = recommended
        self.supportsVision = supportsVision
        self.mmprojFileName = mmprojFileName
        self.mmprojURL = mmprojURL
        self.mmprojSizeBytes = mmprojSizeBytes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case fileName
        case url
        case sizeBytes
        case quantization
        case contextSize
        case recommended
        case supportsVision
        case mmprojFileName
        case mmprojURL
        case mmprojSizeBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.fileName = try container.decode(String.self, forKey: .fileName)
        self.url = try container.decode(String.self, forKey: .url)
        self.sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        self.quantization = try container.decode(String.self, forKey: .quantization)
        self.contextSize = try container.decode(Int.self, forKey: .contextSize)
        self.recommended = try container.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
        self.supportsVision = try container.decodeIfPresent(Bool.self, forKey: .supportsVision) ?? false
        self.mmprojFileName = try container.decodeIfPresent(String.self, forKey: .mmprojFileName)
        self.mmprojURL = try container.decodeIfPresent(String.self, forKey: .mmprojURL)
        self.mmprojSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .mmprojSizeBytes)
    }

    public var requiresMMProj: Bool {
        supportsVision && mmprojFileName != nil
    }

    public var totalSizeBytes: Int64 {
        sizeBytes + (mmprojSizeBytes ?? 0)
    }

    /// Human-readable file size (e.g., "2.8 GB").
    public var formattedSize: String {
        let gb = Double(totalSizeBytes) / 1_000_000_000
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        } else {
            let mb = Double(totalSizeBytes) / 1_000_000
            return String(format: "%.0f MB", mb)
        }
    }
}
