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
    /// A section to scroll to when the panel opens (`QuickCaptureSettingsSection.anchor`).
    var scrollTo: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
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
                .task {
                    guard let scrollTo else { return }
                    // After the first layout, or the Form has no rows to scroll to yet.
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation { proxy.scrollTo(scrollTo, anchor: .top) }
                }
            }
            .voiceNoteBanner()
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
    @State private var notebook = NewNoteSettings.voiceNotebook()
    @State private var paper = PaperPreference.load()
    @State private var choosingPaper = false

    var body: some View {
        Section {
            Picker("Title", selection: $format) {
                ForEach(NewNoteSettings.TitleFormat.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: format) { NewNoteSettings.setTitleFormat(format) }
            Button { choosingPaper = true } label: {
                HStack {
                    Text("Paper").foregroundStyle(.primary)
                    Spacer()
                    Text(paper.kind.localizedTitle).foregroundStyle(.secondary)
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
        let t = NewNoteSettings.title(format)
        return t.isEmpty ? String(localized: "“Untitled”", comment: "Settings ▸ New Notes footer: how a note with no title is shown, in quotes") : "“\(t)”"
    }

    private func commitNotebook() {
        NewNoteSettings.setVoiceNotebook(notebook)
        notebook = NewNoteSettings.voiceNotebook()
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
                    Button(LocalizedStringKey(downloading ? "Downloading…" : "Download Language Model")) { Task { await download() } }
                        .disabled(downloading)
                }
            }
        } header: {
            Text("Transcription")
        } footer: {
            if let failure {
                Text(failure)
            } else {
                Text("Off by default. Transcripts are made on this device and stored encrypted in the note; no audio or text is sent anywhere.")
            }
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
        do { try await download(locale) } catch {
            failure = String(localized: "The language model could not be downloaded: \(String(describing: error))",
                             comment: "Settings ▸ Transcription; the error text follows (English)")
        }
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
            if photoPrivacy {
                Text("Photos you add are stored without location and camera data, and HEIC photos are converted to JPEG. Exports never include location data.")
            } else {
                Text("Photos are stored as picked, with their location and camera data, and HEIC photos stay HEIC. Exports still leave location data out.")
            }
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
                if days > 0 {
                    Text("Once a day, autosaves older than \(ThinningPreference.label(days)) are removed from this vault on every device. Saved versions and the last autosave of each editing session are always kept, and stay restorable. This setting is for this device only.")
                } else {
                    Text("Autosaves are never removed by this device. Another device with thinning on still thins the vault.")
                }
            }
            Section {
                Button {
                    Task { await makePreview(.olderThan(days: days)) }
                } label: {
                    if days > 0 {
                        Text(ThinningRule.olderThan(days: days).localizedButtonTitle)
                    } else {
                        Text("Thin Now…")
                    }
                }
                .disabled(days <= 0 || working || model.phase != .unlocked)
                Button(role: .destructive) {
                    Task { await makePreview(.allButCheckpoints) }
                } label: {
                    Text(ThinningRule.allButCheckpoints.localizedButtonTitle)
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
                Text("The first applies the setting above; the second ignores it and removes every autosave except the newest save of each editing session. Both keep every saved and imported version, and show what they would remove before anything is.")
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
            outcome = String(localized: "Could not check the vault: \(String(describing: error))",
                             comment: "Settings alert; the error text follows (English)")
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
            outcome = String(localized: "Could not thin the vault: \(String(describing: error))",
                             comment: "Settings alert; the error text follows (English)")
        }
    }

    private struct PreviewBox: Identifiable {
        let report: ThinningReport
        let id = UUID()
    }
}

// MARK: - Device keys

private struct DeviceKeySettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var onAdd = RewrapSettings.onAdd()
    @State private var onRemove = RewrapSettings.onRemoveOrUpgrade()
    @State private var confirming = false
    @State private var savingKey = false
    @State private var creatingKey = false

    var body: some View {
        Section {
            Button("Save Key…", systemImage: "key") { savingKey = true }
                .disabled(model.phase != .unlocked || model.heldIdentity == nil)
            Button("New Key…", systemImage: "key.badge.plus") { creatingKey = true }
                .disabled(model.phase != .unlocked)
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
            Text("Save Key exports this device's key, after Face ID, to Files or a password manager, with its paper recovery kit. New Key makes a key for another device and encrypts the vault to it. Devices here are the keys this vault is encrypted to (this iPad, that Mac, the paper backup), not people: to share a note, export it. “Rewrite headers only” is fast but leaves old copies of an attachment openable with a key that was removed. “Re-encrypt everything” takes longer in a vault with many attachments.")
        }
        .sheet(isPresented: $savingKey) { SaveKeyView() }
        .sheet(isPresented: $creatingKey) { NewKeyView() }
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

    var body: some View {
        Section {
            if model.phase == .unlocked {
                // Re-derived whenever the index changes.
                let _ = model.attachmentIndexVersion
                let report = model.attachmentStorage()
                NavigationLink {
                    UnusedAttachmentsView()
                } label: {
                    LabeledContent("Unused Attachments", value: StorageText.items(report.unused.count, bytes: report.unusedBytes))
                }
                LabeledContent("Held by History", value: StorageText.items(report.held.count, bytes: report.heldBytes))
                if model.attachmentIndexPending > 0 {
                    HStack {
                        Text("Checking \(model.attachmentIndexPending) notes…", comment: "Settings ▸ Storage: the attachment index is being updated")
                        Spacer()
                        ProgressView()
                    }
                } else if model.notesWithoutAttachmentIndex > 0 {
                    let n = model.notesWithoutAttachmentIndex
                    Button("Check \(n) More Notes") { Task { await model.indexAttachments() } }
                }
            } else {
                Text("Unlock a vault to see its unused attachments.").foregroundStyle(.secondary)
            }
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
            Text(Self.footer)
        }
        .task {
            sizes = await model.cacheSizes()
            await model.loadAttachmentIndex()
        }
    }

    static let footer = String(localized: "Unused attachments are files no version of their note uses; they can be deleted 30 days after this device first found them unused. Held by history: files only older versions show, freed when those versions are thinned. Caches speed up opening notes and can be rebuilt from the vault.", comment: "Settings ▸ Storage footer")
}

/// Settings → Storage → Unused Attachments: by note, each with a preview,
/// what it was, since when it is unused and when it may be deleted, a link
/// to the note's history, and Delete (only once the 30 days have passed);
/// then the attachments only history still uses.
struct UnusedAttachmentsView: View {
    @Environment(AppModel.self) private var model
    @State private var deleting = false
    @State private var confirmAll = false
    @State private var message: String?
    @State private var history: HistoryLink?

    /// A note's history to show, at a restore point if one is given.
    struct HistoryLink: Identifiable {
        var note: UUID
        var revision: String?
        var id: String { note.uuidString + (revision ?? "") }
    }

    var body: some View {
        let _ = model.attachmentIndexVersion
        let report = model.attachmentStorage()
        let now = model.attachmentNow()
        let eligible = report.eligible(at: now)
        List {
            Section {
                Button(role: .destructive) {
                    confirmAll = true
                } label: {
                    HStack {
                        Text("Delete All Eligible (\(StorageText.items(eligible.count, bytes: report.eligibleBytes(at: now))))")
                        if deleting { Spacer(); ProgressView() }
                    }
                }
                .disabled(eligible.isEmpty || deleting)
            } footer: {
                Text(message ?? String(localized: "An attachment can be deleted 30 days after this device first found it unused. Deleting reads its note again first and keeps anything a version still uses."))
            }
            if report.unused.isEmpty {
                Text("No unused attachments.").foregroundStyle(.secondary)
            }
            ForEach(UnusedAttachmentGroups.group(report.unused, title: model.noteTitle)) { group in
                Section {
                    ForEach(group.items) { item in
                        UnusedAttachmentRow(item: item, now: now, deleting: deleting) {
                            Task { await delete([item]) }
                        } showHistory: {
                            history = HistoryLink(note: item.note, revision: item.lastUse?.revision)
                        }
                    }
                } header: {
                    HStack {
                        Text(NoteTitle.display(group.title)).lineLimit(1)
                        Spacer()
                        Button("History") { history = HistoryLink(note: group.note, revision: nil) }
                            .font(.caption).textCase(nil)
                    }
                }
            }
            if !report.held.isEmpty {
                Section {
                    ForEach(report.held) { item in
                        Button {
                            history = HistoryLink(note: item.note, revision: item.lastUse?.revision)
                        } label: {
                            HStack {
                                AttachmentThumbnail(note: item.note, fileName: item.fileName, kind: item.kind)
                                VStack(alignment: .leading) {
                                    Text(NoteTitle.display(model.noteTitle(item.note))).lineLimit(1)
                                    Text(StorageText.describe(kind: item.kind, lastUse: item.lastUse) + " · " + StorageText.versions(item.revisions.count))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(StorageText.bytes(item.bytes)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Held by History (\(StorageText.items(report.held.count, bytes: report.heldBytes)))")
                } footer: {
                    Text("Only older versions of these notes show these attachments. They are freed when those versions are thinned (Settings → Version History).")
                }
            }
            if !report.unchecked.isEmpty {
                Section {
                } footer: {
                    Text("\(report.unchecked.count) notes were not checked: a version could not be read, or is not downloaded yet.")
                }
            }
        }
        .navigationTitle("Unused Attachments")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete \(StorageText.items(eligible.count, bytes: report.eligibleBytes(at: now)))?",
                            isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete(eligible) } }
        } message: {
            Text("These attachments have been unused for at least 30 days. This cannot be undone.")
        }
        .sheet(item: $history) { link in
            HistoryView(noteID: link.note, revealing: link.revision)
        }
        .task { await model.loadAttachmentIndex() }
    }

    private func delete(_ items: [AttachmentStorageReport.Unused]) async {
        deleting = true
        defer { deleting = false }
        do {
            let r = try await model.deleteUnusedAttachments(items)
            var text = String(localized: "Deleted \(StorageText.items(r.deleted, bytes: r.bytes)).")
            if !r.problems.isEmpty { text += " " + r.problems.joined(separator: " ") }
            message = text
        } catch is CancellationError {
        } catch {
            message = String(localized: "Could not delete: \(String(describing: error))", comment: "the error text follows (English)")
        }
    }
}

/// One unused attachment: preview, what it was, the window, Delete.
private struct UnusedAttachmentRow: View {
    let item: AttachmentStorageReport.Unused
    let now: Date
    let deleting: Bool
    let delete: () -> Void
    let showHistory: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            AttachmentThumbnail(note: item.note, fileName: item.fileName, kind: item.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(StorageText.describe(kind: item.kind, lastUse: item.lastUse))
                Text(StorageText.window(item, now: now)).font(.caption).foregroundStyle(.secondary)
                if let used = item.lastUse {
                    Button(used.wall.map { String(localized: "Last used \(StorageText.day($0))") } ?? String(localized: "Last used in an earlier version"),
                           action: showHistory)
                        .font(.caption).buttonStyle(.borderless)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(StorageText.bytes(item.bytes)).foregroundStyle(.secondary).monospacedDigit()
                Button("Delete", role: .destructive, action: delete)
                    .buttonStyle(.borderless)
                    .disabled(deleting || !item.isEligible(at: now))
            }
        }
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
            if case .allButCheckpoints = r.rule {
                return String(localized: "Nothing to remove: every note keeps only checkpoints and the newest save of each editing session.")
            }
            return String(localized: "Nothing to remove: no autosave is old enough to be thinned.")
        }
        let bytes = ByteCountFormatter()
        // Two counts in one sentence: each is its own (plural) noun phrase.
        let deletedSize = bytes.string(fromByteCount: Int64(r.bytesDeleted))
        let files = String(localized: "\(r.deletions) old autosaves (\(deletedSize))",
                           comment: "Thinning summary: noun phrase, number of autosaves removed and their size; used in “Removes %@ from %@.”")
        let notes = String(localized: "\(r.notes.count) notes",
                           comment: "Thinning summary: noun phrase, number of notes; used in “Removes %@ from %@.”")
        var s = done
            ? String(localized: "Removed \(files) from \(notes).", comment: "Thinning done: “Removed 120 old autosaves (1.2 MB) from 4 notes.”")
            : String(localized: "Removes \(files) from \(notes).", comment: "Thinning preview: “Removes 120 old autosaves (1.2 MB) from 4 notes.”")
        if r.snapshots > 0 {
            let addedSize = bytes.string(fromByteCount: Int64(r.bytesAdded))
            s += " " + (done
                ? String(localized: "To keep saved versions and the last autosave of each session restorable, \(r.snapshots) snapshots (\(addedSize)) were added.")
                : String(localized: "To keep saved versions and the last autosave of each session restorable, \(r.snapshots) snapshots (\(addedSize)) will be added."))
        }
        if !r.skipped.isEmpty {
            s += " " + String(localized: "\(r.skipped.count) notes were left as they are (open, not downloaded or unreadable).")
        }
        return s
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(Self.sentence(report, done: false))
                } footer: {
                    Text(report.rule.localizedExplanation)
                }
                if !report.notes.isEmpty {
                    Section("Notes") {
                        ForEach(report.notes) { n in
                            HStack {
                                Text(NoteTitle.display(n.title)).lineLimit(1)
                                Spacer()
                                Text("\(n.deletions) autosaves", comment: "Thinning preview: autosaves removed from one note")
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            }
            .navigationTitle(report.rule.localizedTitle)
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

/// The thinning rules' wording in the interface language (`ThinningRule.title`
/// and `explanation` are the library's English, also printed by the CLI).
extension ThinningRule {
    /// "Thin versions older than 30 days" / "Thin everything except checkpoints".
    var localizedTitle: String {
        switch self {
        case .olderThan(let days):
            let age = ThinningPreference.label(days)
            return String(localized: "Thin versions older than \(age)", comment: "Thinning rule; the value is “30 days”, “1 year”…")
        case .allButCheckpoints:
            return String(localized: "Thin everything except checkpoints", comment: "Thinning rule")
        }
    }

    /// `localizedTitle` as a button that opens a preview ("…").
    var localizedButtonTitle: String {
        switch self {
        case .olderThan(let days):
            let age = ThinningPreference.label(days)
            return String(localized: "Thin versions older than \(age)…", comment: "Button; the value is “30 days”, “1 year”…")
        case .allButCheckpoints:
            return String(localized: "Thin everything except checkpoints…", comment: "Button")
        }
    }

    /// The rule and what it keeps, in one sentence.
    var localizedExplanation: String {
        switch self {
        case .olderThan(let days):
            let age = ThinningPreference.label(days)
            return String(localized: "Removes autosaves older than \(age). Keeps every checkpoint (saved and imported versions), the newest save of each editing session, the note's newest version and everything from the last \(age).",
                          comment: "Thinning rule explanation; both values are the same age, “30 days”, “1 year”…")
        case .allButCheckpoints:
            return String(localized: "Removes every autosave, however recent, except the newest save of each editing session. Keeps every checkpoint (saved and imported versions) and the note's newest version.")
        }
    }
}

