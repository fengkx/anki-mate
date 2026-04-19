import Foundation

public enum LLMContentStyle: String, CaseIterable, Sendable {
    case steadier
    case balanced
    case moreVaried

    public static let defaultsKey = "ankimate.aiContentStyle"

    public static func current(defaults: UserDefaults = .standard) -> LLMContentStyle {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let style = LLMContentStyle(rawValue: rawValue) else {
            return .balanced
        }
        return style
    }

    public func adjustedTemperature(_ base: Float) -> Float {
        switch self {
        case .steadier:
            return min(max(min(base, 0.35), 0.05), 1.0)
        case .balanced:
            return min(max(base, 0.05), 1.0)
        case .moreVaried:
            return 0.7
        }
    }
}
