import SwiftUI

struct CollectionEditorSheet: View {
    @EnvironmentObject var viewModel: WordListViewModel
    @Environment(\.dismiss) private var dismiss
    let mode: CollectionEditorMode
    let initialName: String
    let onSubmit: (String) -> Bool
    @State private var name: String

    init(mode: CollectionEditorMode, initialName: String, onSubmit: @escaping (String) -> Bool) {
        self.mode = mode
        self.initialName = initialName
        self.onSubmit = onSubmit
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(mode == .create ? "New Collection" : "Rename Collection")
                .font(.headline)

            TextField("Collection name", text: $name)
                .textFieldStyle(.roundedBorder)

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
                    if onSubmit(name) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 360)
        .onAppear {
            viewModel.collectionEditorErrorMessage = nil
        }
    }
}

struct ExportCollectionsSheet: View {
    @EnvironmentObject var viewModel: WordListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCollectionIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 16) {
            Text("Export Collections")
                .font(.headline)

            List(viewModel.collections) { collection in
                Toggle(
                    isOn: Binding(
                        get: { selectedCollectionIDs.contains(collection.id) },
                        set: { isSelected in
                            if isSelected {
                                selectedCollectionIDs.insert(collection.id)
                            } else {
                                selectedCollectionIDs.remove(collection.id)
                            }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(collection.name)
                        if collection.ankiDeckName != collection.name {
                            Text(collection.ankiDeckName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Text("\(viewModel.exportableWordCount(for: collection.id)) ready")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(minHeight: 220)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Export") {
                    let selection = selectedCollectionIDs
                    dismiss()
                    viewModel.exportCollections(selection)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCollectionIDs.isEmpty)
            }
        }
        .padding()
        .frame(width: 420, height: 360)
        .onAppear {
            if selectedCollectionIDs.isEmpty {
                selectedCollectionIDs = viewModel.defaultExportCollectionIDs()
            }
        }
    }
}
