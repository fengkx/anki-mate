import Foundation

@MainActor
final class HelpCenterState: ObservableObject {
    static let hasSeenGuideKey = "ankimate.help.hasSeenGuide"

    @Published var isGuidePresented = false

    private let defaults: UserDefaults
    private var shouldAutoPresentOnFirstLaunch: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.shouldAutoPresentOnFirstLaunch = defaults.object(forKey: Self.hasSeenGuideKey) == nil
    }

    func presentGuideIfNeededOnFirstLaunch() {
        guard shouldAutoPresentOnFirstLaunch else { return }
        shouldAutoPresentOnFirstLaunch = false
        defaults.set(true, forKey: Self.hasSeenGuideKey)
        isGuidePresented = true
    }

    func presentGuide() {
        isGuidePresented = true
    }

    func dismissGuide() {
        isGuidePresented = false
    }
}
