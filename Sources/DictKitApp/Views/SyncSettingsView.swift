import SwiftUI

/// Sheet for configuring WebDAV sync.
struct SyncSettingsView: View {
    @EnvironmentObject var syncStatus: SyncStatus
    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var testResult: TestResult?
    @State private var isTesting: Bool = false
    @State private var syncInterval: SyncInterval = .tenMinutes
    @Environment(\.dismiss) private var dismiss
    var onSyncNow: (() async -> Void)?
    var onIntervalChanged: ((SyncInterval) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WebDAV Sync")
                .font(.title2.bold())

            Form {
                Section("Server") {
                    TextField("Server URL", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .help("e.g. https://dav.jianguoyun.com/dav/")

                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)

                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Status") {
                    HStack {
                        Image(systemName: syncStatus.systemImage)
                            .foregroundStyle(statusColor)
                        Text(syncStatus.statusDescription)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Sync Now") {
                            saveCredentials()
                            Task {
                                await onSyncNow?()
                            }
                        }
                        .disabled(!canSync)
                    }

                    if let error = syncStatus.lastError, syncStatus.state == .error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Picker("Auto-sync interval", selection: $syncInterval) {
                        ForEach(SyncInterval.allCases) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }
                    .onChange(of: syncInterval) { newValue in
                        onIntervalChanged?(newValue)
                    }
                }
            }
            .formStyle(.grouped)

            if let result = testResult {
                HStack {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.success ? .green : .red)
                    Text(result.message)
                        .font(.caption)
                }
                .padding(.horizontal)
            }

            HStack {
                Button("Test Connection") {
                    testConnection()
                }
                .disabled(serverURL.isEmpty || username.isEmpty || password.isEmpty || isTesting)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button("Save") {
                    saveCredentials()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(serverURL.isEmpty || username.isEmpty || password.isEmpty)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 420, height: 400)
        .onAppear {
            let creds = WebDAVCredentials.load()
            serverURL = creds.serverURL
            username = creds.username
            password = creds.password
            syncInterval = SyncInterval.load()
        }
    }

    private var statusColor: Color {
        switch syncStatus.state {
        case .idle:
            return syncStatus.isConfigured ? .green : .secondary
        case .syncing:
            return .blue
        case .error:
            return .red
        }
    }

    private var canSync: Bool {
        if serverURL.isEmpty || username.isEmpty || password.isEmpty { return false }
        if case .syncing = syncStatus.state { return false }
        return true
    }

    private func saveCredentials() {
        var creds = WebDAVCredentials(serverURL: serverURL, username: username, password: password)
        // Normalize URL
        if !serverURL.hasSuffix("/") {
            creds.serverURL += "/"
        }
        creds.save()
        syncStatus.isConfigured = creds.isConfigured
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        let creds = WebDAVCredentials(serverURL: serverURL, username: username, password: password)
        Task {
            do {
                let client = try WebDAVClient(credentials: creds)
                try await client.testConnection()
                testResult = TestResult(success: true, message: "Connection successful!")
            } catch {
                testResult = TestResult(success: false, message: error.localizedDescription)
            }
            isTesting = false
        }
    }
}

private struct TestResult {
    let success: Bool
    let message: String
}
