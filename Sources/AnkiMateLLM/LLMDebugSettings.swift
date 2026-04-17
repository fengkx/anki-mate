import Foundation

public enum LLMDebugSettings {
    public static let streamDebugEnabledKey = "llm.streamDebugEnabled"

    public static var isStreamDebugEnabled: Bool {
        UserDefaults.standard.bool(forKey: streamDebugEnabledKey)
    }

    public static func setStreamDebugEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: streamDebugEnabledKey)
    }
}
