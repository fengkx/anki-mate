import DictKitSystemDictionary
import SwiftUI

struct CollectionEditorSheet: View {
    @EnvironmentObject var viewModel: WordListViewModel
    @Environment(\.dismiss) private var dismiss
    let mode: CollectionEditorMode
    let onSubmit: (CollectionEditorFormData) -> Bool
    @State private var form: CollectionEditorFormData
    @State private var availableDictionaries: [String] = []

    init(mode: CollectionEditorMode, initialForm: CollectionEditorFormData, onSubmit: @escaping (CollectionEditorFormData) -> Bool) {
        self.mode = mode
        self.onSubmit = onSubmit
        _form = State(initialValue: initialForm)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(mode == .create ? "New Collection" : "Rename Collection")
                .font(.headline)

            TextField("Collection name", text: $form.collectionName)
                .textFieldStyle(.roundedBorder)

            Picker("Dictionary", selection: $form.dictionaryName) {
                Text("Automatic").tag("")
                ForEach(availableDictionaries, id: \.self) { name in
                    Text(name).tag(name)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Deck description")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $form.deckDescription)
                    .frame(minHeight: 90)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2))
                    )
            }

            if let errorMessage = viewModel.collectionEditorErrorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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
        .padding()
        .frame(width: 420)
        .onAppear {
            viewModel.collectionEditorErrorMessage = nil
            availableDictionaries = SystemDictionaryClient().listAvailableDictionaries().sorted()
        }
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
