import SwiftUI

struct WordInputView: View {
    @EnvironmentObject var viewModel: WordListViewModel
    @State private var inputText: String = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("Enter a word...", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    viewModel.addWord(inputText)
                    inputText = ""
                }

            Button("Add") {
                viewModel.addWord(inputText)
                inputText = ""
            }
            .buttonStyle(.bordered)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

struct BatchInputSheet: View {
    @EnvironmentObject var viewModel: WordListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Batch Add Words")
                .font(.headline)

            Text("Paste words below, one per line:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                let count = text.components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .count
                Text("\(count) words")
                    .foregroundColor(.secondary)

                Button("Add All") {
                    viewModel.addWords(from: text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400, height: 350)
    }
}
