import SwiftUI

struct SettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dictionary settings are configured per collection.")
                .font(.body)
            Text("Edit a collection to choose its preferred dictionary and fallback behavior.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 400, height: 120, alignment: .topLeading)
        .padding()
    }
}
