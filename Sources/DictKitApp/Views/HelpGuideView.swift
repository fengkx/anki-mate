import SwiftUI

struct HelpGuideView: View {
    @EnvironmentObject private var helpCenter: HelpCenterState
    @EnvironmentObject private var viewModel: WordListViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var selectedSection: HelpGuideSection = .quickStart
    let showsCloseButton: Bool

    init(showsCloseButton: Bool = true) {
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            navigationBar

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedSection {
                    case .quickStart:
                        quickStartContent
                    case .faq:
                        faqContent
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 20)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 560, idealHeight: 640)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to AnkiMate")
                    .font(.system(size: 22, weight: .semibold))

                Text("A simple place to get familiar with the app.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if showsCloseButton {
                Button("Close") {
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(.bar)
    }

    private var navigationBar: some View {
        HStack(alignment: .center, spacing: 16) {
            Picker("", selection: $selectedSection) {
                ForEach(HelpGuideSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)

            Spacer()

            if selectedSection == .quickStart {
                HStack(spacing: 6) {
                    ToolbarShortcutButton(title: "Batch Add", systemImage: "text.insert") {
                        viewModel.showBatchInput = true
                    }
                    ToolbarShortcutButton(title: "Local AI", systemImage: "sparkles") {
                        openWindow(id: AppWindowIDs.aiSettings)
                    }
                    ToolbarShortcutButton(title: "Sync", systemImage: "arrow.trianglehead.2.clockwise") {
                        openWindow(id: AppWindowIDs.syncSettings)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .top) {
                    Divider()
                }
                .overlay(alignment: .bottom) {
                    Divider()
                }
        )
    }

    private func close() {
        helpCenter.dismissGuide()
    }

    @ViewBuilder
    private var quickStartContent: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    IntroCard()
                    GuideSection(
                        title: "1. A collection can be a good place to start",
                        systemImage: "books.vertical",
                        items: [
                            "Collections can help keep different topics or decks separate.",
                            "One collection is also fine if everything belongs in the same place."
                        ]
                    )
                    GuideSection(
                        title: "2. Words can be added whenever they come up",
                        systemImage: "text.badge.plus",
                        items: [
                            "You can type one word at a time, or paste a list when you already have one."
                        ]
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 16) {
                    SetupCard(
                        openAISettings: { openWindow(id: AppWindowIDs.aiSettings) },
                        openSyncSettings: { openWindow(id: AppWindowIDs.syncSettings) }
                    )
                    GuideSection(
                        title: "3. The preview is there when you want a closer look",
                        systemImage: "rectangle.on.rectangle",
                        items: [
                            "Selecting a word shows its dictionary result and the card preview.",
                            "You can review the result, generate extra study content when needed, and then add what you want to keep."
                        ]
                    )
                    GuideSection(
                        title: "4. Export can wait until the list feels ready",
                        systemImage: "square.and.arrow.up",
                        items: [
                            "Export can wait until a collection feels ready.",
                            "Many people save words first and export later."
                        ]
                    )
                }
                .frame(width: 300, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 16) {
                IntroCard()
                SetupCard(
                    openAISettings: { openWindow(id: AppWindowIDs.aiSettings) },
                    openSyncSettings: { openWindow(id: AppWindowIDs.syncSettings) }
                )
                GuideSection(
                    title: "1. A collection can be a good place to start",
                    systemImage: "books.vertical",
                    items: [
                        "Collections can help keep different topics or decks separate.",
                        "One collection is also fine if everything belongs in the same place."
                    ]
                )
                GuideSection(
                    title: "2. Words can be added whenever they come up",
                    systemImage: "text.badge.plus",
                    items: [
                        "You can type one word at a time, or paste a list when you already have one."
                    ]
                )
                GuideSection(
                    title: "3. The preview is there when you want a closer look",
                    systemImage: "rectangle.on.rectangle",
                    items: [
                        "Selecting a word shows its dictionary result and the card preview.",
                        "You can review the result, generate extra study content when needed, and then add what you want to keep."
                    ]
                )
                GuideSection(
                    title: "4. Export can wait until the list feels ready",
                    systemImage: "square.and.arrow.up",
                    items: [
                        "Export can wait until a collection feels ready.",
                        "Many people save words first and export later."
                    ]
                )
            }
        }
    }

    @ViewBuilder
    private var faqContent: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    GuideSection(
                        title: "When should I create multiple collections?",
                        systemImage: "square.stack.3d.up",
                        items: [
                            "More than one collection can be useful when you want to keep topics or decks separate.",
                            "If everything belongs in one place, a single collection usually feels simpler."
                        ]
                    )
                    GuideSection(
                        title: "Why are some words not ready yet?",
                        systemImage: "clock.badge.exclamationmark",
                        items: [
                            "A word may still be loading, the lookup may not have finished, or it may need a quick check in the preview.",
                            "If something does not look right, opening the word again and trying the lookup once more can help."
                        ]
                    )
                    GuideSection(
                        title: "When should I use Batch Add?",
                        systemImage: "text.insert",
                        items: [
                            "Batch Add is useful when you already have a list from notes, copied text, or another app."
                        ]
                    )
                }

                VStack(alignment: .leading, spacing: 16) {
                    GuideSection(
                        title: "Do I need to set up AI before using the app?",
                        systemImage: "cpu",
                        items: [
                            "You can start without it.",
                            "Many people still prefer to set it up early."
                        ]
                    )
                    GuideSection(
                        title: "Do I need sync right away?",
                        systemImage: "arrow.trianglehead.2.clockwise",
                        items: [
                            "If you may use more than one device, or if you would like a WebDAV-based backup, setting up sync early is often worth it."
                        ]
                    )
                }
                .frame(width: 300, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 16) {
                GuideSection(
                    title: "When should I create multiple collections?",
                    systemImage: "square.stack.3d.up",
                    items: [
                        "More than one collection can be useful when you want to keep topics or decks separate.",
                        "If everything belongs in one place, a single collection usually feels simpler."
                    ]
                )
                GuideSection(
                    title: "Do I need to set up AI before using the app?",
                    systemImage: "cpu",
                    items: [
                        "You can start without it.",
                        "Many people still prefer to set it up early."
                    ]
                )
                GuideSection(
                    title: "Why are some words not ready yet?",
                    systemImage: "clock.badge.exclamationmark",
                    items: [
                        "A word may still be loading, the lookup may not have finished, or it may need a quick check in the preview.",
                        "If something does not look right, opening the word again and trying the lookup once more can help."
                    ]
                )
                GuideSection(
                    title: "When should I use Batch Add?",
                    systemImage: "text.insert",
                    items: [
                        "Batch Add is useful when you already have a list from notes, copied text, or another app."
                    ]
                )
                GuideSection(
                    title: "Do I need sync right away?",
                    systemImage: "arrow.trianglehead.2.clockwise",
                    items: [
                        "If you may use more than one device, or if you would like a WebDAV-based backup, setting up sync early is often worth it."
                    ]
                )
            }
        }
    }
}

private enum HelpGuideSection: String, CaseIterable, Identifiable {
    case quickStart
    case faq

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickStart:
            return "Quick Start"
        case .faq:
            return "FAQ"
        }
    }
}

private struct IntroCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("What AnkiMate helps with", systemImage: "text.book.closed")
                        .font(.headline)

                    Text("AnkiMate can help turn words you come across into study material.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: 12) {
                IntroFact(title: "Save", detail: "Collect words while reading, studying, or working.")
                IntroFact(title: "Review", detail: "Check the dictionary result and card preview before keeping a word.")
                IntroFact(title: "Export", detail: "Send the words you want to review into Anki when the list feels ready.")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.10),
                    Color.accentColor.opacity(0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.accentColor.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct IntroFact: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SetupCard: View {
    let openAISettings: () -> Void
    let openSyncSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings you may want early on")
                .font(.headline)

            Text("Local AI and sync can be useful early on, especially if richer card content or a backup copy would be helpful.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                CompactShortcutRow(
                    title: "Local AI settings",
                    detail: "A local model can be selected here whenever AI features feel useful.",
                    systemImage: "sparkles",
                    action: openAISettings
                )

                CompactShortcutRow(
                    title: "Sync settings",
                    detail: "WebDAV can be set up here if sync or backup would be helpful.",
                    systemImage: "arrow.trianglehead.2.clockwise",
                    action: openSyncSettings
                )
            }

            Text("This page is always available again from Help.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct CompactShortcutRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct ToolbarShortcutButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct GuideSection: View {
    let title: String
    let systemImage: String
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, alignment: .center)

                Text(title)
                    .font(.headline)
            }

            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.secondary)
                        .padding(.top, 7)

                    Text(item)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
