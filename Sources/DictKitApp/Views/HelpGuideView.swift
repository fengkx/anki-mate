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

                Text("Look up words, review dictionary results, and export study cards to Anki.")
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
                    ToolbarShortcutButton(title: "Sync", systemImage: "arrow.triangle.2.circlepath") {
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
                        title: "1. Add words",
                        systemImage: "text.badge.plus",
                        items: [
                            "Type one word at a time, or use Batch Add when you already have a list."
                        ]
                    )
                    GuideSection(
                        title: "2. Review the result and preview",
                        systemImage: "rectangle.on.rectangle",
                        items: [
                            "Selecting a word shows its dictionary result and card preview, so you can decide what to keep."
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
                        title: "3. Set up Local AI for generated study content",
                        systemImage: "sparkles",
                        items: [
                            "Local AI generates example sentences, recall cards, mnemonics, and more for your words.",
                            "Model downloads can take some time, so it is worth setting up before you need those features."
                        ]
                    )
                    GuideSection(
                        title: "4. Export when ready",
                        systemImage: "square.and.arrow.up",
                        items: [
                            "Export creates an .apkg file you can import into Anki.",
                            "The collection name becomes the deck name in Anki."
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
                    title: "1. Add words",
                    systemImage: "text.badge.plus",
                    items: [
                        "Type one word at a time, or use Batch Add when you already have a list."
                    ]
                )
                GuideSection(
                    title: "2. Review the result and preview",
                    systemImage: "rectangle.on.rectangle",
                    items: [
                        "Selecting a word shows its dictionary result and card preview, so you can decide what to keep."
                    ]
                )
                GuideSection(
                    title: "3. Set up Local AI for generated study content",
                    systemImage: "sparkles",
                    items: [
                        "Local AI generates example sentences, recall cards, mnemonics, and more for your words.",
                        "Model downloads can take some time, so it is worth setting up before you need those features."
                    ]
                )
                GuideSection(
                    title: "4. Export when ready",
                    systemImage: "square.and.arrow.up",
                    items: [
                        "Export creates an .apkg file you can import into Anki.",
                        "The collection name becomes the deck name in Anki."
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
                        title: "Do I need to set up AI before using the app?",
                        systemImage: "cpu",
                        items: [
                            "No.",
                            "You can add words, check dictionary results, and preview cards without it.",
                            "Local AI adds generated content like example sentences, recall cards, and mnemonics.",
                            "Set it up when you want those features."
                        ]
                    )
                    GuideSection(
                        title: "Why are some words not ready yet?",
                        systemImage: "clock.badge.exclamationmark",
                        items: [
                            "A word may still be loading, the lookup may need another try, or an AI-generated section may still be unavailable.",
                            "Open the word again or refresh the lookup if something looks incomplete."
                        ]
                    )
                    GuideSection(
                        title: "When should I use Batch Add?",
                        systemImage: "text.insert",
                        items: [
                            "Use Batch Add when you already have a list from notes, copied text, or another app.",
                            "Use single-word entry when you want to review each word as you add it."
                        ]
                    )
                }

                VStack(alignment: .leading, spacing: 16) {
                    GuideSection(
                        title: "What is a collection?",
                        systemImage: "books.vertical",
                        items: [
                            "A collection is a group of words.",
                            "The collection name becomes the deck name when you export to Anki.",
                            "You can use one collection for everything, or separate collections for different topics."
                        ]
                    )
                    GuideSection(
                        title: "Do I need sync right away?",
                        systemImage: "arrow.triangle.2.circlepath",
                        items: [
                            "No.",
                            "Sync is useful for backup and multi-device use, but it isn't required to start adding words."
                        ]
                    )
                }
                .frame(width: 300, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 16) {
                GuideSection(
                    title: "Do I need to set up AI before using the app?",
                    systemImage: "cpu",
                    items: [
                        "No.",
                        "You can add words, check dictionary results, and preview cards without it.",
                        "Local AI adds generated content like example sentences, recall cards, and mnemonics.",
                        "Set it up when you want those features."
                    ]
                )
                GuideSection(
                    title: "Why are some words not ready yet?",
                    systemImage: "clock.badge.exclamationmark",
                    items: [
                        "A word may still be loading, the lookup may need another try, or an AI-generated section may still be unavailable.",
                        "Open the word again or refresh the lookup if something looks incomplete."
                    ]
                )
                GuideSection(
                    title: "When should I use Batch Add?",
                    systemImage: "text.insert",
                    items: [
                        "Use Batch Add when you already have a list from notes, copied text, or another app.",
                        "Use single-word entry when you want to review each word as you add it."
                    ]
                )
                GuideSection(
                    title: "What is a collection?",
                    systemImage: "books.vertical",
                    items: [
                        "A collection is a group of words.",
                        "The collection name becomes the deck name when you export to Anki.",
                        "You can use one collection for everything, or separate collections for different topics."
                    ]
                )
                GuideSection(
                    title: "Do I need sync right away?",
                    systemImage: "arrow.triangle.2.circlepath",
                    items: [
                        "No.",
                        "Sync is useful for backup and multi-device use, but it isn't required to start adding words."
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

                    Text("Add words, review them with dictionary context, and export study cards to Anki.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: 12) {
                IntroFact(title: "Add", detail: "Add words one at a time or paste a list with Batch Add.")
                IntroFact(title: "Review", detail: "Check dictionary results and preview cards before keeping what you want.")
                IntroFact(title: "Export", detail: "Export your collection to Anki as a deck whenever you're ready.")
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
            Text("Helpful setup")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Local AI generates example sentences, recall cards, and other study content.")
                Text("Sync keeps your data backed up and available across devices.")
                Text("Neither is required to start adding words.")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                CompactShortcutRow(
                    title: "Local AI settings",
                    detail: "Set this up before you want generated study content, since model downloads can take some time.",
                    systemImage: "sparkles",
                    action: openAISettings
                )

                CompactShortcutRow(
                    title: "Sync settings",
                    detail: "Set up WebDAV if you want backup or sync across devices.",
                    systemImage: "arrow.triangle.2.circlepath",
                    action: openSyncSettings
                )
            }

            Text("You can always come back here from Help.")
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
