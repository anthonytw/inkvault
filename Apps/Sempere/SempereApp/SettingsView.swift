import Sempere
import SwiftUI

/// The app's settings: photos (the privacy setting of docs/attachments.md
/// §7, on by default) and version history: how old autosaves must be before
/// they are thinned (format.md §5.8.4), and "Thin Now" with a preview of
/// what it removes. (The full Settings panel is
/// task E6; this is the minimal entry until then.)
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ThinningPreference.key) private var days = ThinningPreference.defaultDays
    @AppStorage(PhotoPrivacy.key) private var photoPrivacy = PhotoPrivacy.defaultValue
    @State private var preview: PreviewBox?
    @State private var working = false
    @State private var outcome: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Remove Location and Camera Data", isOn: $photoPrivacy)
                } header: {
                    Text("Photos")
                } footer: {
                    Text(photoPrivacy
                         ? "Photos you add are stored without location and camera data, and HEIC photos are converted to JPEG. Exports never include location data. This setting is for this device only."
                         : "Photos are stored as picked, with their location and camera data, and HEIC photos stay HEIC. Exports still leave location data out.")
                }
                Section {
                    Picker("Thin Autosaves Older Than", selection: $days) {
                        ForEach(ThinningPreference.choices, id: \.self) { Text(ThinningPreference.label($0)).tag($0) }
                    }
                } header: {
                    Text("Version History")
                } footer: {
                    Text(days > 0
                         ? "Once a day, autosaves older than \(ThinningPreference.label(days)) are removed from this vault on every device. Saved versions and the last autosave of each editing session are always kept, and stay restorable. This setting is for this device only."
                         : "Autosaves are never removed by this device. Another device with thinning on still thins the vault.")
                }
                Section {
                    Button {
                        Task { await makePreview(.olderThan(days: days)) }
                    } label: {
                        Text(days > 0 ? "\(ThinningRule.olderThan(days: days).title)…" : "Thin Now…")
                    }
                    .disabled(days <= 0 || working || model.phase != .unlocked)
                    Button(role: .destructive) {
                        Task { await makePreview(.allButCheckpoints) }
                    } label: {
                        Text("\(ThinningRule.allButCheckpoints.title)…")
                    }
                    .disabled(working || model.phase != .unlocked)
                    if let progress = model.thinningProgress {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: progress.fractionCompleted)
                            Text(progress.headline).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Thin Now")
                } footer: {
                    Text("The first applies the setting above; the second ignores it and removes every autosave except "
                         + "the newest save of each editing session. Both keep every saved and imported version, and "
                         + "show what they would remove before anything is.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $preview) { box in
                ThinningPreviewView(report: box.report) {
                    preview = nil
                    Task { await thin(box.report.rule) }
                } cancel: {
                    preview = nil
                }
            }
            .alert("Thinning", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })) {
                Button("OK") {}
            } message: {
                Text(outcome ?? "")
            }
        }
    }

    private func makePreview(_ rule: ThinningRule) async {
        working = true
        defer { working = false }
        do {
            preview = PreviewBox(report: try await model.thinVault(rule: rule, dryRun: true))
        } catch is CancellationError {
        } catch {
            outcome = "Could not check the vault: \(error)"
        }
    }

    private func thin(_ rule: ThinningRule) async {
        working = true
        defer { working = false }
        do {
            let done = try await model.thinVault(rule: rule, dryRun: false)
            outcome = ThinningPreviewView.sentence(done, done: true)
        } catch is CancellationError {
        } catch {
            outcome = "Could not thin the vault: \(error)"
        }
    }

    private struct PreviewBox: Identifiable {
        let report: ThinningReport
        let id = UUID()
    }
}

/// What "Thin Now" will remove, note by note, with the button that does it.
struct ThinningPreviewView: View {
    let report: ThinningReport
    let thin: () -> Void
    let cancel: () -> Void

    /// "Removes 120 old autosaves (1.2 MB) from 4 notes and adds 6 snapshots (3.4 MB) …".
    static func sentence(_ r: ThinningReport, done: Bool) -> String {
        guard !r.isEmpty else {
            if case .allButCheckpoints = r.rule { return "Nothing to remove: every note keeps only checkpoints and the newest save of each editing session." }
            return "Nothing to remove: no autosave is old enough to be thinned."
        }
        let bytes = ByteCountFormatter()
        let files = "\(r.deletions) old autosave\(r.deletions == 1 ? "" : "s") (\(bytes.string(fromByteCount: Int64(r.bytesDeleted))))"
        let notes = "\(r.notes.count) note\(r.notes.count == 1 ? "" : "s")"
        var s = done ? "Removed \(files) from \(notes)." : "Removes \(files) from \(notes)."
        if r.snapshots > 0 {
            s += " To keep saved versions and the last autosave of each session restorable, "
                + "\(r.snapshots) snapshot\(r.snapshots == 1 ? "" : "s") (\(bytes.string(fromByteCount: Int64(r.bytesAdded)))) "
                + (done ? "were" : "will be") + " added."
        }
        if !r.skipped.isEmpty {
            s += " \(r.skipped.count) note\(r.skipped.count == 1 ? " was" : "s were") left as they are (open, not downloaded or unreadable)."
        }
        return s
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(Self.sentence(report, done: false))
                } footer: {
                    Text(report.rule.explanation)
                }
                if !report.notes.isEmpty {
                    Section("Notes") {
                        ForEach(report.notes) { n in
                            HStack {
                                Text(NoteTitle.display(n.title)).lineLimit(1)
                                Spacer()
                                Text("\(n.deletions) autosave\(n.deletions == 1 ? "" : "s")")
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            }
            .navigationTitle(report.rule.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Thin", role: .destructive, action: thin).disabled(report.isEmpty)
                }
            }
        }
    }
}
