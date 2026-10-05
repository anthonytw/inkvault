import SwiftUI

/// Asks for a key to the open vault: a stored key file's passphrase, or a
/// pasted `AGE-SECRET-KEY-PQ-1…` or `AGE-SECRET-KEY-1…` identity. (Key management proper is task 3d.)
struct UnlockView: View {
    @Environment(AppModel.self) private var model
    @State private var passphrase = ""
    @State private var identityText = ""
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Passphrase of a stored key") {
                    SecureField("Passphrase", text: $passphrase)
                        .onSubmit { unlock { try await model.unlock(passphrase: passphrase) } }
                    Button("Unlock") { unlock { try await model.unlock(passphrase: passphrase) } }
                        .disabled(passphrase.isEmpty)
                }
                Section("Or paste a secret key") {
                    TextField("AGE-SECRET-KEY-PQ-1… or AGE-SECRET-KEY-1…", text: $identityText, axis: .vertical)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Unlock with Key") { unlock { try await model.unlock(identityText: identityText) } }
                        .disabled(identityText.isEmpty)
                }
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
            .navigationTitle("Unlock \(model.vaultName ?? "Vault")")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close Vault") { model.close() }
                }
            }
            .disabled(model.isBusy)
        }
    }

    private func unlock(_ action: @escaping () async throws -> Void) {
        failure = nil
        Task {
            do { try await action() } catch { failure = "\(error)" }
        }
    }
}
