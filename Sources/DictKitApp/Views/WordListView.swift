import SwiftUI

struct WordListView: View {
    @EnvironmentObject var viewModel: WordListViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(viewModel.words) { item in
                    WordRowView(
                        item: item,
                        isSelected: viewModel.selectedWordID == item.id
                    )
                    .contentShape(Rectangle())
                    .hoverCursor()
                    .onTapGesture {
                        viewModel.selectedWordID = item.id
                    }
                    .contextMenu {
                        Button("Delete") {
                            viewModel.removeWord(item)
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDeleteCommand {
            viewModel.deleteSelectedWord()
        }
    }
}

struct WordRowView: View {
    private static let selectionTint = Color.blue.opacity(0.18)

    @ObservedObject var item: WordItem
    @EnvironmentObject var viewModel: WordListViewModel
    let isSelected: Bool
    @State private var isHovered: Bool = false

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
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Self.selectionTint)
        } else if isHovered {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        } else {
            Color.clear
        }
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
