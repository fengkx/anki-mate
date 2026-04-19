import SwiftUI

struct WordListView: View {
    @EnvironmentObject var viewModel: WordListViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if viewModel.words.isEmpty {
                emptyState
            } else {
                List(selection: $viewModel.selectedWordID) {
                    ForEach(viewModel.words) { item in
                        WordRowView(item: item)
                            .tag(item.id)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button("Delete") {
                                    viewModel.removeWord(item)
                                }
                            }
                            .help(item.word)
                            .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                        }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDeleteCommand {
            viewModel.deleteSelectedWord()
        }
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

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.word)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let sourceDescription = item.sourceDescription {
                    Text(sourceDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if !item.phonetic.isEmpty {
                    Text(item.phonetic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            HStack(spacing: 8) {
                if item.isReady {
                    Button(action: {
                        Task { await viewModel.playPronunciation(for: item) }
                    }) {
                        Image(systemName: "speaker.wave.2")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Play pronunciation")
                }

                if item.isSynthesizingAudio {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                } else if item.audioData != nil {
                    Image(systemName: "waveform")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .help("Audio ready")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.lookupState {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .loading:
            ProgressView()
                .scaleEffect(0.6)
        case .loaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}
