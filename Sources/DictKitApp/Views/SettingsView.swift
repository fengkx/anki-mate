import DictKitSystemDictionary
import SwiftUI

struct SettingsView: View {
    @AppStorage("selectedDictionary") private var selectedDictionary: String = ""
    @State private var availableDictionaries: [String] = []

    var body: some View {
        Form {
            Picker("Dictionary", selection: $selectedDictionary) {
                Text("Automatic").tag("")
                ForEach(availableDictionaries, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .onAppear {
            availableDictionaries = SystemDictionaryClient().listAvailableDictionaries().sorted()
        }
    }
}
