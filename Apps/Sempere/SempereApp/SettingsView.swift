import Sempere
import SempereSpeech
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
    @AppStorage(TranscriptionPreference.key) private var transcribe = TranscriptionPreference.defaultValue
    @State private var recording = RecordingPreference.format()
    /// Which speech engines can transcribe on this device (task E5's availability matrix).
    @State private var engines: [SpeechTranscription.EngineStatus] = []
    @State private var preview: PreviewBox?
    @State private var working = false
    @State private var outcome: String?

    var body: some View {
        NavigationStack {
            Form {
                RecordingSettingsSection(format: $recording)
                Section {
                    Toggle("Transcribe Recordings on This Device", isOn: $transcribe)
                    ForEach(engines, id: \.engine) { e in
                        LabeledContent(e.engine) {
                            Text((e.available ? "Available" : "Unavailable") + (e.language.map { " · \($0)" } ?? ""))
                        }
                        .help(e.detail)
                    }
                } header: {
                    Text("Transcription")
                } footer: {
                    Text(transcribe
                         ? "New recordings are transcribed on this device when you stop recording, in the note's language or else this device's. Audio never leaves the device: a language without an on-device model is not transcribed."
                         : "Recordings are transcribed only when you choose Transcribe for one. Transcription runs on this device only.")
                }
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
                        Task { await makePreview() }
                    } label: {
                        HStack {
                            Text("Thin Now…")
                            if working { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(days <= 0 || working || model.phase != .unlocked)
                } footer: {
                    Text("Shows what would be removed before anything is.")
                }
            }
            .onChange(of: recording) { _, f in RecordingPreference.save(f) }
            .task { engines = await SpeechTranscription.availability() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $preview) { box in
                ThinningPreviewView(report: box.report, days: days) {
                    preview = nil
                    Task { await thin() }
                } cancel: {
                    preview = nil
                }
            }
            .alert("Thin Now", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })) {
                Button("OK") {}
            } message: {
                Text(outcome ?? "")
            }
        }
    }

    private func makePreview() async {
        working = true
        defer { working = false }
        do {
            preview = PreviewBox(report: try await model.thinVault(days: days, dryRun: true))
        } catch is CancellationError {
        } catch {
            outcome = "Could not check the vault: \(error)"
        }
    }

    private func thin() async {
        working = true
        defer { working = false }
        do {
            let done = try await model.thinVault(days: days, dryRun: false)
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
    let days: Int
    let thin: () -> Void
    let cancel: () -> Void

    /// "Removes 120 old autosaves (1.2 MB) from 4 notes and adds 6 snapshots (3.4 MB) …".
    static func sentence(_ r: ThinningReport, done: Bool) -> String {
        guard !r.isEmpty else { return "Nothing to remove: no autosave is old enough to be thinned." }
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
            .navigationTitle("Thin Autosaves Older Than \(ThinningPreference.label(days))")
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

/// Recording format (docs/attachments.md §9, §15): codec, quality, sample
/// rate and channels, with the resulting size per hour.
struct RecordingSettingsSection: View {
    @Binding var format: RecordingFormat

    var body: some View {
        Section {
            Picker("Format", selection: Binding(get: { format.codec }, set: { codec in
                format = RecordingFormat(codec: codec, bitRate: codec.defaultBitRate, sampleRate: format.sampleRate,
                                         channels: format.channels).normalized()
            })) {
                ForEach(RecordingFormat.Codec.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if !format.codec.bitRates.isEmpty {
                Picker("Quality", selection: Binding(get: { format.bitRate ?? 0 }, set: { format.bitRate = $0 })) {
                    ForEach(format.codec.bitRates, id: \.self) { Text("\($0 / 1000) kbit/s").tag($0) }
                }
            }
            Picker("Sample Rate", selection: Binding(get: { format.sampleRate }, set: { format = RecordingFormat(
                codec: format.codec, bitRate: format.bitRate, sampleRate: $0, channels: format.channels).normalized() })) {
                ForEach(RecordingFormat.sampleRates, id: \.self) { Text(String(format: "%g kHz", Double($0) / 1000)).tag($0) }
            }
            Picker("Channels", selection: $format.channels) {
                Text("Mono").tag(1)
                Text("Stereo").tag(2)
            }
        } header: {
            Text("Recording")
        } footer: {
            Text("\(format.sizePerHourText). AAC-LC plays everywhere; HE-AAC is smaller at low bit rates; Apple Lossless keeps every detail and is much larger. Stereo needs a stereo microphone. This setting is for this device only.")
        }
    }
}
