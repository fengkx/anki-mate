import SwiftUI

struct WordListView: View {
    @EnvironmentObject var viewModel: WordListViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if viewModel.words.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(viewModel.words.enumerated()), id: \.element.id) { index, item in
                                WordRowView(item: item)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        viewModel.selectedWordID = item.id
                                    }
                                    .contextMenu {
                                        Button("Delete") {
                                            viewModel.removeWord(item)
                                        }
                                    }
                                    .help(item.word)

                                if index < viewModel.words.count - 1
                                    && viewModel.selectedWordID != item.id
                                    && viewModel.selectedWordID != viewModel.words[index + 1].id {
                                    Divider()
                                        .padding(.leading, 42)
                                }
                            }
                        }
                        .padding(.top, 2)
                        .padding(.horizontal, 10)
                    }
                    .onChange(of: viewModel.selectedWordID) { newID in
                        if let newID {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(newID, anchor: nil)
                            }
                        }
                    }
                    .keyboardNavigation { offset in
                        moveSelection(by: offset)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDeleteCommand {
            viewModel.deleteSelectedWord()
        }
    }

    private func moveSelection(by offset: Int) {
        guard !viewModel.words.isEmpty else { return }
        guard let currentID = viewModel.selectedWordID,
              let currentIndex = viewModel.words.firstIndex(where: { $0.id == currentID }) else {
            viewModel.selectedWordID = viewModel.words.first?.id
            return
        }
        let newIndex = min(max(currentIndex + offset, 0), viewModel.words.count - 1)
        viewModel.selectedWordID = viewModel.words[newIndex].id
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)

            Text("No words yet")
                .font(.headline)

            Text("Add a word above, or use Batch Add for a list.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: 10) {
                Button("Batch Add") {
                    viewModel.showBatchInput = true
                }
                .buttonStyle(.borderedProminent)

                Button("Help") {
                    openWindow(id: AppWindowIDs.help)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct WordRowView: View {
    @ObservedObject var item: WordItem
    @EnvironmentObject var viewModel: WordListViewModel

    private var isSelected: Bool {
        viewModel.selectedWordID == item.id
    }

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.word)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let sourceDescription = item.sourceDescription {
                    Text(sourceDescription)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if !item.phonetic.isEmpty {
                    Text(item.phonetic)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if item.isReady {
                    Button(action: {
                        Task { await viewModel.playPronunciation(for: item) }
                    }) {
                        Image(systemName: "speaker.wave.2")
                            .font(.caption)
                            .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Play pronunciation")
                }

                if item.isSynthesizingAudio {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                } else if item.audioData != nil {
                    Button(action: {
                        Task { await viewModel.refreshPronunciationAudio(for: item) }
                    }) {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundStyle(isSelected ? .white.opacity(0.9) : .green)
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh audio")
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.lookupState {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(isSelected ? .white.opacity(0.6) : .secondary)
        case .loading:
            ProgressView()
                .scaleEffect(0.6)
        case .loaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(isSelected ? .white : .green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(isSelected ? .white : .red)
        }
    }
}

// MARK: - Keyboard Navigation

private struct KeyboardNavigationModifier: ViewModifier {
    let onMove: (Int) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .onKeyPress(.upArrow) {
                    onMove(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    onMove(1)
                    return .handled
                }
        } else {
            content
        }
    }
}

private extension View {
    func keyboardNavigation(onMove: @escaping (Int) -> Void) -> some View {
        modifier(KeyboardNavigationModifier(onMove: onMove))
    }
}
