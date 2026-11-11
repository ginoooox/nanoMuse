import SwiftUI

struct NanoMuseProviderHeadersEditor: View {
    let instanceId: String
    let baseURL: String
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [NanoMuseProviderHeaderRules.Header] = []
    @State private var errorKey: String?

    var body: some View {
        Form {
            Section {
                ForEach($rows) { $row in
                    VStack(alignment: .leading) {
                        TextField(AppLocalized("Header Name"), text: $row.name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                        SecureField(AppLocalized("Header Value"), text: $row.value)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .privacySensitive()
                    }
                }
                .onDelete { rows.remove(atOffsets: $0) }
                Button(AppLocalized("Add Header")) {
                    rows.append(.init())
                }
            } footer: {
                Text(AppLocalized("Headers are stored in this device's Keychain and sent to this endpoint for chat and model discovery. They are excluded from exports and sync. Changing the endpoint host requires entering them again. Swipe a row to delete it."))
            }
            Section {
                Text(AppLocalized("Use the API key field for authentication. Custom User-Agent takes priority over a User-Agent entered here. Host, authentication and transport headers cannot be overridden."))
                    .foregroundStyle(.secondary)
            }
            if let errorKey {
                Text(AppLocalized(errorKey)).foregroundStyle(.red)
            }
        }
        .navigationTitle(AppLocalized("Custom Headers"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalized("Save")) { save() }
            }
        }
        .onAppear {
            rows = NanoMuseProviderHeaders.load(instanceId: instanceId, baseURL: baseURL)
        }
    }

    private func save() {
        do {
            try NanoMuseProviderHeaders.save(rows, instanceId: instanceId, baseURL: baseURL)
            dismiss()
        } catch is NanoMuseProviderHeaderRules.Failure {
            errorKey = "Use unique HTTP header names and nonempty values without line breaks. Host, authentication and transport headers are reserved."
        } catch {
            errorKey = "Could not save headers to the Keychain. Try again."
        }
    }
}
