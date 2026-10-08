import Sempere
import SwiftUI

/// The Settings panel (docs/attachments.md §15): one screen, a sheet from the
/// sidebar's gear button on iPad and iPhone and a window (Settings…, ⌘,) on
/// the Mac. Every setting is per device (`UserDefaults`, see `DeviceSettings`)
/// and none is stored in the vault. Settings of a feature that is not in this
/// build yet (recording, transcription) are stored all the same and read by
/// that feature when it lands.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// False in the Mac window, which has its own close button.
    var showsDone = true

    var body: some View {
        NavigationStack {
            Form {
                GeneralSettings()
                NewNoteSettingsSection()
                RecordingSettingsSection()
                TranscriptionSettingsSection()
                QuickCaptureSettingsSection()
                PhotoSettingsSection()
                HistorySettingsSection()
                DeviceKeySettingsSection()
                StorageSettingsSection()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDone {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(KeepScreenOn.key) private var keepScreenOn = KeepScreenOn.defaultValue
    @AppStorage(RecognitionPreference.key) private var recognize = RecognitionPreference.defaultValue

    var body: some View {
        Section {
            Toggle("Keep Screen On", isOn: $keepScreenOn)
            Toggle("Recognize Handwriting", isOn: Binding(
                get: { recognize },
                set: { recognize = $0; model.setHandwritingRecognition($0) }))
        } header: {
            Text("General")
        } footer: {
            Text("Keep Screen On stops the screen from locking while a note is open. Handwriting recognition makes handwriting searchable; it runs on this device and nothing leaves it.")
        }
    }
}

// MARK: - New notes

private struct NewNoteSettingsSection: View {
    @State private var format = NewNoteSettings.titleFormat()
    /// The custom pattern as typed (stored only while it checks).
    @State private var pattern = NewNoteSettings.titlePattern()
    @State private var notebook = NewNoteSettings.voiceNotebook()
    @State private var paper = PaperPreference.load()
    @State private var choosingPaper = false

    var body: some View {
        Section {
            Picker("Title", selection: $format) {
                ForEach(NewNoteSettings.TitleFormat.allCases) { f in
                    // Each preset with what it gives today (a menu shows the second line as its subtitle).
                    if f == .custom || f == .blank {
                        Text(f.title).tag(f)
                    } else {
                        VStack(alignment: .leading) {
                            Text(f.title)
                            Text(NewNoteSettings.title(f)).foregroundStyle(.secondary)
                        }
                        .tag(f)
                    }
                }
            }
            .onChange(of: format) { NewNoteSettings.setTitleFormat(format) }
            if format == .custom {
                TitlePatternField(pattern: $pattern)
            }
            Button { choosingPaper = true } label: {
                HStack {
                    Text("Paper").foregroundStyle(.primary)
                    Spacer()
                    Text(paper.kind.title).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
            .sheet(isPresented: $choosingPaper) {
                PaperPickerView(paper: paper, purpose: .newNote) { chosen, _ in
                    paper = chosen
                    PaperPreference.save(chosen)
                }
            }
            LabeledContent("Voice Notes") {
                TextField(NewNoteSettings.defaultVoiceNotebook, text: $notebook)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .onSubmit(commitNotebook)
                    .onChange(of: notebook) { NewNoteSettings.setVoiceNotebook(notebook) }
            }
        } header: {
            Text("New Notes")
        } footer: {
            Text("A new note whose title you leave empty is named \(sample). Quick voice notes go to the notebook “\(NewNoteSettings.canonicalNotebook(notebook))”; use / for levels.")
        }
    }

    private var sample: String {
        let t = NewNoteSettings.title(format, pattern: NewNoteSettings.titlePattern())
        return t.isEmpty ? "“Untitled”" : "“\(t)”"
    }

    private func commitNotebook() {
        NewNoteSettings.setVoiceNotebook(notebook)
        notebook = NewNoteSettings.voiceNotebook()
    }
}

/// The custom title pattern: a monospaced field checked as it is typed
/// (`DefaultTitle.check`, the rules `notes new --title-format` applies), with
/// the title it gives now or the reason it cannot be used, and a menu of
/// fields to insert. Only a pattern that checks is stored.
struct TitlePatternField: View {
    @Binding var pattern: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Pattern", text: $pattern, prompt: Text(NewNoteSettings.defaultTitlePattern))
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: pattern) { NewNoteSettings.setTitlePattern(pattern) }
                    .accessibilityLabel("Title pattern")
                Menu("Insert", systemImage: "plus.circle") {
                    ForEach(TitlePatternField.fields, id: \.pattern) { field in
                        Button("\(field.name) (\(DefaultTitle.title(at: Date(), format: field.pattern)))") {
                            pattern += (pattern.isEmpty || pattern.hasSuffix(" ") ? "" : " ") + field.pattern
                        }
                    }
                }
                .labelStyle(.iconOnly)
            }
            switch TitlePatternField.status(of: pattern) {
            case .preview(let title):
                Label(title, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Preview: \(title)")
            case .problem(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Text("Letters are date fields (yyyy year, MM month, d day, EEEE weekday, HH:mm time); put other text in single quotes, e.g. 'Lecture' d MMM. strftime works too: %Y-%m-%d %H:%M.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// The fields the Insert menu offers.
    static let fields: [(name: String, pattern: String)] = [
        ("Year", "yyyy"), ("Month", "MMMM"), ("Month (number)", "MM"), ("Day", "d"), ("Weekday", "EEEE"),
        ("Time", "HH:mm"), ("Time (12-hour)", "h:mm a"), ("Text", "'Note'"),
    ]

    enum Status: Equatable {
        case preview(String)
        case problem(String)
    }

    /// What the field shows under `pattern` at `now`. Pure, tested.
    static func status(of pattern: String, now: Date = Date(), locale: Locale = .current,
                       timeZone: TimeZone = .current) -> Status {
        if pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .problem("Type a pattern, e.g. \(NewNoteSettings.defaultTitlePattern).") }
        if let problem = DefaultTitle.check(pattern, at: now, locale: locale, timeZone: timeZone) {
            return .problem(problem.description)
        }
        return .preview(DefaultTitle.title(at: now, format: pattern, locale: locale, timeZone: timeZone))
    }
}

// MARK: - Recording

private struct RecordingSettingsSection: View {
    @State private var settings = RecordingSettings.load()

    var body: some View {
        Section {
            Picker("Format", selection: $settings.codec) {
                ForEach(RecordingSettings.Codec.allCases) { Text($0.title).tag($0) }
            }
            if settings.codec.hasBitRate {
                Picker("Quality", selection: $settings.bitRate) {
                    ForEach(RecordingSettings.bitRates(for: settings.codec), id: \.self) {
                        Text(RecordingSettings.label(bitRate: $0)).tag($0)
                    }
                }
            }
            Picker("Sample Rate", selection: $settings.sampleRate) {
                ForEach(RecordingSettings.sampleRates, id: \.self) { Text(RecordingSettings.label(sampleRate: $0)).tag($0) }
            }
            Picker("Channels", selection: $settings.channels) {
                ForEach(RecordingSettings.Channels.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Size", value: settings.sizePerHourText())
        } header: {
            Text("Recording")
        } footer: {
            Text("Stereo is used only when the microphone has two channels. Apple Lossless is a size estimate for speech. Changes apply to new recordings; recordings already made keep their format.")
        }
        .onChange(of: settings) {
            // A codec change can make the bit rate invalid: show the corrected value.
            let fixed = settings.normalized()
            if fixed != settings { settings = fixed }
            settings.save()
        }
    }
}

// MARK: - Transcription

private struct TranscriptionSettingsSection: View {
    @State private var enabled = TranscriptionSettings.isEnabled()
    @State private var locale = TranscriptionSettings.localeIdentifier()
    @State private var status = TranscriptionSettings.ModelStatus.unavailable
    @State private var downloading = false
    @State private var failure: String?

    var body: some View {
        Section {
            Toggle("Transcribe Recordings on This Device", isOn: $enabled)
                .onChange(of: enabled) { TranscriptionSettings.setEnabled(enabled) }
            if enabled {
                Picker("Language", selection: $locale) {
                    Text("Same as Device").tag(String?.none)
                    ForEach(TranscriptionSettings.offeredLocales(), id: \.self) { id in
                        Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(String?.some(id))
                    }
                }
                .onChange(of: locale) { TranscriptionSettings.setLocaleIdentifier(locale) }
                LabeledContent("Language Model", value: status.text)
                if status == .notDownloaded, TranscriptionSettings.downloader != nil {
                    Button(downloading ? "Downloading…" : "Download Language Model") { Task { await download() } }
                        .disabled(downloading)
                }
            }
        } header: {
            Text("Transcription")
        } footer: {
            Text(failure ?? "Off by default. Transcripts are made on this device and stored encrypted in the note; no audio or text is sent anywhere.")
        }
        .task(id: "\(enabled)|\(locale ?? "")") { await refresh() }
    }

    private func refresh() async {
        guard enabled else { return }
        status = await TranscriptionSettings.statusProvider(locale)
    }

    private func download() async {
        guard let download = TranscriptionSettings.downloader else { return }
        downloading = true
        failure = nil
        defer { downloading = false }
        do { try await download(locale) } catch { failure = "The language model could not be downloaded: \(error)" }
        await refresh()
    }
}

// MARK: - Photos

private struct PhotoSettingsSection: View {
    @AppStorage(PhotoPrivacy.key) private var photoPrivacy = PhotoPrivacy.defaultValue

    var body: some View {
        Section {
            Toggle("Remove Location and Camera Data", isOn: $photoPrivacy)
        } header: {
            Text("Photos")
        } footer: {
            Text(photoPrivacy
                 ? "Photos you add are stored without location and camera data, and HEIC photos are converted to JPEG. Exports never include location data."
                 : "Photos are stored as picked, with their location and camera data, and HEIC photos stay HEIC. Exports still leave location data out.")
        }
    }
}

// MARK: - Version history

private struct HistorySettingsSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ThinningPreference.key) private var days = ThinningPreference.defaultDays
    @State private var preview: PreviewBox?
    @State private var working = false
    @State private var outcome: String?

    var body: some View {
        Group {
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
        .sheet(item: $preview) { box in
            ThinningPreviewView(report: box.report) {
                preview = nil
                Task { await thin(box.report.rule, now: box.report.now) }
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

    /// Runs `rule` as of `now`, the preview's time (nil: the current time).
    private func thin(_ rule: ThinningRule, now: Date?) async {
        working = true
        defer { working = false }
        do {
            let done = try await model.thinVault(rule: rule, dryRun: false, now: now ?? Date())
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

// MARK: - Device keys

private struct DeviceKeySettingsSection: View {
    @State private var onAdd = RewrapSettings.onAdd()
    @State private var onRemove = RewrapSettings.onRemoveOrUpgrade()
    @State private var confirming = false

    var body: some View {
        Section {
            Picker("When Adding a Device", selection: $onAdd) {
                ForEach(RewrapMethod.allCases, id: \.self) { Text(RewrapSettings.title($0)).tag($0) }
            }
            .onChange(of: onAdd) { RewrapSettings.setOnAdd(onAdd) }
            Picker("When Removing a Device or Upgrading to Post-Quantum Keys", selection: Binding(
                get: { onRemove },
                set: { chosen in
                    if RewrapSettings.needsConfirmation(forRemoval: chosen), chosen != onRemove {
                        confirming = true
                    } else {
                        onRemove = chosen
                        RewrapSettings.setOnRemoveOrUpgrade(chosen)
                    }
                })) {
                ForEach(RewrapMethod.allCases, id: \.self) { Text(RewrapSettings.title($0)).tag($0) }
            }
        } header: {
            Text("Device Keys")
        } footer: {
            Text("Devices here are the keys this vault is encrypted to (this iPad, that Mac, the paper backup), not people: to share a note, export it. “Rewrite headers only” is fast but leaves old copies of an attachment openable with a key that was removed. “Re-encrypt everything” takes longer in a vault with many attachments.")
        }
        .confirmationDialog("Rewrite headers only after a removal?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Rewrite Headers Only", role: .destructive) {
                onRemove = .headerOnly
                RewrapSettings.setOnRemoveOrUpgrade(.headerOnly)
            }
            Button("Keep Re-encrypting Everything", role: .cancel) {}
        } message: {
            Text("A removed device key, or a copy of the vault from before an upgrade, could still open attachments it could open before. Only choose this if you accept that.")
        }
    }
}

// MARK: - Storage

private struct StorageSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var sizes = CacheSizes()
    @State private var unused: UnusedAttachmentReport?
    @State private var scanning = false
    @State private var failure: String?

    var body: some View {
        Section {
            if let unused {
                NavigationLink {
                    UnusedAttachmentsView(report: unused)
                } label: {
                    LabeledContent("Unused Attachments", value: StorageText.items(unused.items.count, bytes: unused.totalBytes))
                }
            }
            Button {
                Task { await scan() }
            } label: {
                HStack {
                    Text(unused == nil ? "Check for Unused Attachments" : "Check Again")
                    if scanning { Spacer(); ProgressView() }
                }
            }
            .disabled(scanning || model.phase != .unlocked)
            LabeledContent("Drawing Cache", value: StorageText.bytes(sizes.drawings))
            LabeledContent("Attachment Cache", value: StorageText.bytes(sizes.attachments))
            Button("Clear Caches", role: .destructive) {
                Task {
                    await model.clearCaches()
                    sizes = await model.cacheSizes()
                }
            }
            .disabled(sizes.total == 0)
        } header: {
            Text("Storage")
        } footer: {
            Text(failure ?? footer)
        }
        .task { sizes = await model.cacheSizes() }
    }

    private var footer: String {
        var s = "Unused attachments are files no version of their note refers to. Checking only lists them; a collection (sempere blobs gc) deletes them, and only 30 days after it first found them unused. Caches speed up opening notes and can be rebuilt from the vault."
        if let n = unused?.skippedNotes, n > 0 {
            s += " \(n) note\(n == 1 ? " was" : "s were") not checked (unreadable, or not downloaded)."
        }
        return s
    }

    private func scan() async {
        scanning = true
        failure = nil
        defer { scanning = false }
        do { unused = try await model.scanUnusedAttachments() } catch is CancellationError {
        } catch { failure = "Could not check the vault: \(error)" }
    }
}

/// The unused attachments a scan found, by note.
struct UnusedAttachmentsView: View {
    let report: UnusedAttachmentReport

    var body: some View {
        List {
            if report.items.isEmpty {
                Text("Every attachment is in use.")
            }
            ForEach(report.items) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(NoteTitle.display(item.title)).lineLimit(1)
                        Text(item.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(StorageText.bytes(item.bytes)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .navigationTitle("Unused Attachments")
        .navigationBarTitleDisplayMode(.inline)
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
