import AppKit
import SwiftUI

private let wordListScrollCoordinateSpace = "WordListScroll"
private let wordListScrollVisibilityInset: CGFloat = 24

struct WordListView: View {
    @EnvironmentObject var viewModel: WordListViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var visibleViewport: CGRect = .zero
    @State private var rowFrames: [UUID: CGRect] = [:]
    @StateObject private var keyboardController = WordListKeyboardController()

    var body: some View {
        Group {
            if viewModel.words.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ZStack {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(viewModel.words.enumerated()), id: \.element.id) { index, item in
                                    WordRowView(item: item)
                                        .id(item.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            viewModel.selectedWordID = item.id
                                            viewModel.refreshSelectedWordIfNeeded()
                                            keyboardController.focus()
                                        }
                                        .contextMenu {
                                            Button("Delete") {
                                                viewModel.removeWord(item)
                                            }
                                        }
                                        .help(item.word)
                                        .background(
                                            GeometryReader { geometry in
                                                Color.clear.preference(
                                                    key: WordListRowFramesPreferenceKey.self,
                                                    value: [item.id: geometry.frame(in: .named(wordListScrollCoordinateSpace))]
                                                )
                                            }
                                        )

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
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: WordListViewportPreferenceKey.self,
                                    value: geometry.frame(in: .named(wordListScrollCoordinateSpace))
                                )
                            }
                        )

                        WordListKeyboardResponder(
                            controller: keyboardController,
                            onMove: { offset in
                                moveSelection(by: offset)
                            },
                            onDelete: {
                                viewModel.deleteSelectedWord()
                            }
                        )
                        .frame(width: 0, height: 0)
                    }
                    .coordinateSpace(name: wordListScrollCoordinateSpace)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        keyboardController.focus()
                    }
                    .onChange(of: viewModel.selectedWordID) { newID in
                        if let newID {
                            scrollSelectionIntoViewIfNeeded(id: newID, proxy: proxy)
                        }
                    }
                    .onPreferenceChange(WordListViewportPreferenceKey.self) { viewport in
                        visibleViewport = viewport
                    }
                    .onPreferenceChange(WordListRowFramesPreferenceKey.self) { frames in
                        rowFrames = frames
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

    private func scrollSelectionIntoViewIfNeeded(id: UUID, proxy: ScrollViewProxy) {
        guard let rowFrame = rowFrames[id] else {
            proxy.scrollTo(id, anchor: nil)
            return
        }

        guard let anchor = preferredScrollAnchor(
            for: rowFrame,
            within: visibleViewport,
            inset: wordListScrollVisibilityInset
        ) else {
            return
        }

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo(id, anchor: anchor.unitPoint)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)

            Text("No words yet")
                .font(.headline)

            Text("Add your first word, or use Batch Add if you already have a list.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: 10) {
                Button("Batch Add") {
                    viewModel.showBatchInput = true
                }
                .buttonStyle(.borderedProminent)

                Button("Open Guide") {
                    openWindow(id: AppWindowIDs.help)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

enum WordListScrollAnchor: Equatable {
    case top
    case bottom

    var unitPoint: UnitPoint {
        switch self {
        case .top:
            .top
        case .bottom:
            .bottom
        }
    }
}

func preferredScrollAnchor(for rowFrame: CGRect, within viewport: CGRect, inset: CGFloat) -> WordListScrollAnchor? {
    guard viewport.height > 0 else { return nil }

    let topThreshold = viewport.minY + inset
    let bottomThreshold = viewport.maxY - inset

    if rowFrame.minY < topThreshold {
        return .top
    }

    if rowFrame.maxY > bottomThreshold {
        return .bottom
    }

    return nil
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

enum WordListKeyboardAction: Equatable {
    case move(Int)
    case delete
}

func wordListKeyboardAction(for keyCode: UInt16) -> WordListKeyboardAction? {
    switch keyCode {
    case 125:
        return .move(1)
    case 126:
        return .move(-1)
    case 51, 117:
        return .delete
    default:
        return nil
    }
}

@MainActor
final class WordListKeyboardController: ObservableObject {
    fileprivate weak var responder: WordListKeyHandlingView?

    func focus() {
        guard let responder else { return }
        responder.window?.makeFirstResponder(responder)
    }
}

private struct WordListKeyboardResponder: NSViewRepresentable {
    let controller: WordListKeyboardController
    let onMove: (Int) -> Void
    let onDelete: () -> Void

    func makeNSView(context: Context) -> WordListKeyHandlingView {
        let view = WordListKeyHandlingView()
        view.onMove = onMove
        view.onDelete = onDelete
        controller.responder = view
        return view
    }

    func updateNSView(_ nsView: WordListKeyHandlingView, context: Context) {
        nsView.onMove = onMove
        nsView.onDelete = onDelete
        controller.responder = nsView
    }
}

private final class WordListKeyHandlingView: NSView {
    var onMove: ((Int) -> Void)?
    var onDelete: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        guard let action = wordListKeyboardAction(for: event.keyCode) else {
            super.keyDown(with: event)
            return
        }

        switch action {
        case .move(let offset):
            onMove?(offset)
        case .delete:
            onDelete?()
        }
    }
}

private struct WordListViewportPreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct WordListRowFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
