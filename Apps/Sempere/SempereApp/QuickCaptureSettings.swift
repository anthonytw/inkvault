import Sempere
import SwiftUI

/// Settings ▸ Quick Voice Notes (docs/quick-capture.md): turn it on for the
/// open vault, the notebook voice notes land in, and on-device transcription.
struct QuickCaptureSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var stored: StoredCaptureProfile?
    @State private var notebook = CaptureProfile.defaultNotebook
    @State private var problem: String?

    var body: some View {
        Section {
            Toggle("Quick Voice Notes", isOn: Binding(get: { model.quickCaptureIsForOpenVault }, set: { on in
                do {
                    if on { try model.enableQuickCapture(notebook: notebook) } else { try model.disableQuickCapture() }
                    problem = nil
                } catch {
                    problem = "\(error)"
                }
                reload()
            }))
            .disabled(model.phase != .unlocked)
            if let stored, model.quickCaptureIsForOpenVault {
                TextField("Notebook", text: $notebook)
                    .onSubmit { update { $0.profile.notebook = NoteOps.normalizedNotebook(notebook) ?? CaptureProfile.defaultNotebook } }
                Toggle("Transcribe Voice Notes", isOn: Binding(get: { stored.transcribe }, set: { on in
                    update { $0.transcribe = on }
                }))
            } else if let stored {
                LabeledContent("Voice notes go to", value: stored.vaultName)
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
        } header: {
            Text("Quick Voice Notes")
        } footer: {
            Text("Record from the Lock Screen, Control Center, the Action button, a widget or Siri (“Record a Sempere voice note”), without unlocking the vault or using Face ID. Each voice note is encrypted on this device to your vault's keys as soon as it stops, and becomes a note in the notebook above, titled with the date and time, the next time the vault is unlocked. Transcription runs on this device only. This device keeps the vault's public keys and a capture key that can add voice notes but cannot read any note.")
        }
        .onAppear { reload() }
    }

    private func reload() {
        stored = model.quickCaptureProfile
        if let s = stored { notebook = s.profile.notebook }
    }

    private func update(_ change: (inout StoredCaptureProfile) -> Void) {
        guard var s = model.quickCaptureProfile else { return }
        change(&s)
        do { try model.quickCapture.store.save(s) } catch { problem = "\(error)" }
        reload()
    }
}
