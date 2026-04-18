import SwiftUI

struct CollectionEditorSheet: View {
    @EnvironmentObject var viewModel: WordListViewModel
    @Environment(\.dismiss) private var dismiss

    let mode: CollectionEditorMode
    let onSubmit: (CollectionEditorFormData) -> Bool

    @State private var form: CollectionEditorFormData
    @State private var dictionarySearchText = ""
    @StateObject private var previewModel: DictionarySelectionPreviewModel

    init(mode: CollectionEditorMode, initialForm: CollectionEditorFormData, onSubmit: @escaping (CollectionEditorFormData) -> Bool) {
        self.mode = mode
        self.onSubmit = onSubmit
        _form = State(initialValue: initialForm)
        _previewModel = StateObject(
            wrappedValue: DictionarySelectionPreviewModel(
                currentDictionaryName: initialForm.dictionaryName,
                candidateDictionaryName: initialForm.dictionaryName
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerSection
            dictionarySection

            if mode != .dictionary {
                nameSection
                deckDescriptionSection
            }

            if let errorMessage = viewModel.collectionEditorErrorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            footerActions
        }
        .padding(20)
        .frame(width: 980)
        .frame(minHeight: mode == .dictionary ? 540 : 680)
        .task {
            viewModel.collectionEditorErrorMessage = nil
            await previewModel.loadIfNeeded()
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleText)
                .font(.title3.weight(.semibold))
            Text("Choose a dictionary and inspect the original entry content before saving.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Collection name")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Collection name", text: $form.collectionName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var dictionarySection: some View {
        HStack(alignment: .top, spacing: 16) {
            dictionaryListPane
                .frame(width: 310)

            dictionaryPreviewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: mode == .dictionary ? nil : .infinity)
    }

    private var dictionaryListPane: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 10) {
                Text("Dictionary")
                    .font(.headline)

                TextField("Search dictionaries", text: $dictionarySearchText)
                    .textFieldStyle(.roundedBorder)

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredDictionaryNames, id: \.self) { dictionaryName in
                            dictionaryRow(for: dictionaryName)
                                .id(dictionaryName)
                        }
                    }
                }
                .padding(.vertical, 2)

                if filteredDictionaryNames.isEmpty {
                    DictionarySelectionEmptyState(
                        title: "No dictionaries found",
                        systemImage: "text.magnifyingglass",
                        message: "Clear search to see all available sources."
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                }
            }
            .onAppear {
                scrollToSelectedDictionary(using: proxy)
            }
            .onChange(of: previewModel.selectedDictionaryName) { _ in
                scrollToSelectedDictionary(using: proxy)
            }
            .onChange(of: dictionarySearchText) { _ in
                scrollToSelectedDictionary(using: proxy)
            }
            .padding(14)
            .background(panelBackground)
        }
    }

    private func dictionaryRow(for dictionaryName: String) -> some View {
        let isCandidate = previewModel.isCandidateDictionary(dictionaryName)
        let isCurrent = previewModel.isCurrentDictionary(dictionaryName)
        let metadata = dictionaryMetadata(for: dictionaryName)

        return Button {
            selectDictionary(dictionaryName)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: isCandidate ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isCandidate ? Color.accentColor : Color.secondary)

                    Text(DictionarySelectionPreviewModel.displayName(for: dictionaryName))
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 8)

                    if isCurrent {
                        Text("Current")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                }

                if let subtitle = metadata.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let detail = metadata.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isCandidate ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isCandidate ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }

    private var dictionaryPreviewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Preview")
                    .font(.headline)

                Spacer()
            }

            HStack(spacing: 10) {
                TextField("Sample word", text: $previewModel.sampleWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await previewModel.refresh() }
                    }

                Button {
                    Task { await previewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload preview")
            }

            previewContent
        }
        .padding(14)
        .background(panelBackground)
    }

    @ViewBuilder
    private var previewContent: some View {
        if previewModel.comparison == nil && (previewModel.comparisonState == .idle || previewModel.comparisonState == .loading) {
            ProgressView("Loading preview...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            if let comparison = previewModel.comparison {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            DictionaryPreviewPaneCard(
                                pane: comparison.current
                            )
                            DictionaryPreviewPaneCard(
                                pane: comparison.candidate
                            )
                        }

                        statusMessage(for: previewModel.comparisonState)
                    }
                }
            } else {
                DictionarySelectionEmptyState(
                    title: "Preview unavailable",
                    systemImage: "exclamationmark.triangle",
                    message: "Could not load dictionary data."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func statusMessage(for state: DictionaryPreviewComparisonState) -> some View {
        switch state {
        case .partialFailure:
            Text("One side could not load complete preview data. You can still save the selection.")
                .font(.caption)
                .foregroundStyle(.orange)
        case .empty:
            Text("Try a more common word to compare dictionaries.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failure:
            Text("Both preview requests failed. You can still save the selection.")
                .font(.caption)
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private var deckDescriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Deck description")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $form.deckDescription)
                .frame(height: 84)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.2))
                )
        }
    }

    private var footerActions: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Spacer()

            Button(mode == .create ? "Create" : "Save") {
                if onSubmit(form) {
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(form.collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var titleText: String {
        switch mode {
        case .create:
            return "New Collection"
        case .rename:
            return "Collection Settings"
        case .dictionary:
            return "Dictionary Settings"
        }
    }

    private var filteredDictionaryNames: [String] {
        let allNames = [""] + previewModel.availableDictionaries
        let query = dictionarySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allNames }
        return allNames.filter {
            DictionarySelectionPreviewModel.displayName(for: $0)
                .localizedCaseInsensitiveContains(query)
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color(NSColor.controlBackgroundColor))
    }

    private func selectDictionary(_ dictionaryName: String) {
        form.dictionaryName = dictionaryName
        Task {
            await previewModel.setCandidateDictionaryName(dictionaryName)
        }
    }

    private func scrollToSelectedDictionary(using proxy: ScrollViewProxy) {
        let selectedID = previewModel.selectedDictionaryName
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(selectedID, anchor: .center)
            }
        }
    }

    private func dictionaryMetadata(for dictionaryName: String) -> (subtitle: String?, detail: String?) {
        let trimmed = dictionaryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("System default fallback", "Uses the default system dictionary path.")
        }

        if trimmed.localizedCaseInsensitiveContains("英汉") {
            return ("Bilingual", "Usually better for CN-forward reading.")
        }

        if trimmed.localizedCaseInsensitiveContains("Oxford Dictionary of English") {
            return ("English monolingual", "Rich definitions and example coverage.")
        }

        if trimmed.localizedCaseInsensitiveContains("New Oxford American Dictionary") {
            return ("System dictionary", "Often the richest default macOS source.")
        }

        return (nil, nil)
    }
}

private struct DictionarySelectionEmptyState: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(.subheadline.weight(.semibold))

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }
}

private struct DictionaryPreviewPaneCard: View {
    let pane: DictionaryPreviewPane

    @State private var expandedSections = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(pane.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))

                    Text(pane.dictionaryName)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            switch pane.state {
            case .empty:
                emptyState(message: "No result for this word.")
            case let .failed(message):
                emptyState(message: "Preview unavailable: \(message)")
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .loaded:
                let sections = pane.sections
                if sections.isEmpty {
                    emptyState(message: "No entry content available in this dictionary.")
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(sections) { section in
                            sectionView(section)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.14))
        )
    }

    @ViewBuilder
    private func sectionView(_ section: DictionaryPreviewSection) -> some View {
        let isExpanded = Binding(
            get: { expandedSections.contains(section.id) || !section.isExpandable },
            set: { newValue in
                if newValue {
                    expandedSections.insert(section.id)
                } else {
                    expandedSections.remove(section.id)
                }
            }
        )

        if section.isExpandable {
            DisclosureGroup(isExpanded: isExpanded) {
                sectionRows(section.rows, expanded: true)
                    .padding(.top, 6)
            } label: {
                Text(section.title)
                    .font(.body.weight(.semibold))
            }
            .padding(.vertical, 2)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(section.title)
                    .font(.body.weight(.semibold))
                sectionRows(section.rows, expanded: true)
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func sectionRows(_ rows: [DictionaryPreviewRow], expanded: Bool) -> some View {
        let visibleRows = expanded ? rows : Array(rows.prefix(4))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(visibleRows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    if let label = row.label {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(row.value)
                        .font(row.emphasis == .primary ? .body : .callout)
                        .foregroundStyle(row.emphasis == .primary ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func emptyState(message: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
    }
}

struct ExportCollectionsSheet: View {
    @EnvironmentObject var viewModel: WordListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var deckDescription: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Export Collection")
                .font(.headline)

            if let collection = viewModel.currentCollection {
                VStack(alignment: .leading, spacing: 4) {
                    Text(collection.name)
                        .font(.body.weight(.medium))
                    Text("\(viewModel.exportableWordCount(for: collection.id)) ready")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Deck description")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $deckDescription)
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2))
                    )
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Export") {
                    guard let currentCollection = viewModel.currentCollection else { return }
                    let request = CollectionExportRequest(
                        collectionID: currentCollection.id,
                        deckDescription: deckDescription
                    )
                    dismiss()
                    viewModel.exportCollection(request)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.currentCollection == nil)
            }
        }
        .padding()
        .frame(width: 420, height: 280)
        .onAppear {
            deckDescription = viewModel.currentCollection?.ankiDeckDescription ?? ""
        }
    }
}
