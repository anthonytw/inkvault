import Foundation
import Sempere

/// Recordings of the open note (docs/attachments.md §9, §13; format.md
/// §8.3): recording into the note, saving (the audio blob first, then one
/// delta adding the recording), renaming and removing, and the ink sync of
/// playback: strokes written while recording carry `rec` (stamped in
/// `StrokeLedger.items(for:tool:stamp:)`), a tap on one plays from there,
/// and playback highlights what was written around the current moment.
extension NoteEditor {
    /// What stamps strokes drawn now with the running recording (nil when none runs).
    var recordingStamp: (@Sendable (Date) -> RecordingLink?)? {
        guard let s = recordingSession, s.isActive else { return nil }
        return s.stamp
    }

    /// The note as the recording features see it (no strokes).
    var recordingState: NoteState {
        NoteState(meta: meta, pages: [], recordings: recordings)
    }

    /// The recording with `id`, if the note has it.
    func recording(_ id: UUID) -> Recording? { recordings.first { $0.id == id } }

    // MARK: - Recording

    /// Starts recording into this note in `format` (the settings' by
    /// default). The caller asked for the microphone first.
    func startRecording(format: RecordingFormat = RecordingPreference.format(), root: URL = RecordingSession.root,
                        backend: AudioCaptureBackend? = nil, center: NotificationCenter = .default) throws {
        guard canEditItems else { throw RecordingError.notEditable }
        guard recordingSession?.isActive != true else { return }
        guard recordings.count < NoteOps.Limits.recordingsPerNote else {
            throw RecordingError.cannotRecord("\(AttachmentOpsError.tooManyRecordings)")
        }
        let s = RecordingSession(noteID: noteID, format: format, root: root, backend: backend, center: center)
        do { try s.start() } catch {
            s.discardFiles()
            throw error
        }
        recordingError = nil
        recordingSession = s
    }

    /// Stops the recording and saves it into the note. Returns the recording
    /// as added (nil when nothing was saved; the reason is in `recordingError`).
    @discardableResult
    func stopRecording() async -> Recording? {
        guard let s = recordingSession, s.isActive else { return nil }
        s.stop()
        let task = Task { await self.save(s) }
        recordingSaves.append(Task { _ = await task.value })
        return await task.value
    }

    /// Stops and saves a recording in progress, and waits for saves still
    /// running (`close`).
    func finishRecording() async {
        await stopRecording()
        let saves = recordingSaves
        recordingSaves = []
        for t in saves { await t.value }
    }

    /// The session's audio as one file, stored as a blob, then the recording
    /// added in one delta. The session's files are handed to
    /// `onRecordingSaved` (transcription), else deleted; on failure they stay
    /// for `RecordingRecovery`.
    private func save(_ s: RecordingSession) async -> Recording? {
        let out = s.folder.appendingPathComponent("recording.m4a")
        RecordingSession.busy.insert(s.id)
        do {
            try await RecordingAssembly.merge(await RecordingAssembly.readable(s.segments), into: out)
            let recording = try await addRecording(file: out, started: s.timeline.started ?? Date(), id: s.id)
            if recordingSession === s { recordingSession = nil }
            if let handOff = onRecordingSaved {
                handOff(recording, out, s.folder)   // deletes the folder and clears `busy` when done
            } else {
                s.discardFiles()
                RecordingSession.busy.remove(s.id)
            }
            return recording
        } catch {
            recordingError = "Could not save the recording: \(error)"
            if recordingSession === s { recordingSession = nil }
            RecordingSession.busy.remove(s.id)   // the files stay for `RecordingRecovery`
            return nil
        }
    }

    /// Adds the audio file `file` as a recording of this note: the blob
    /// first, then one delta (`addRecording`). Its informational fields come
    /// from the file's header (`AudioProbe`).
    @discardableResult
    func addRecording(file: URL, started: Date, id: UUID = UUID(), title: String? = nil) async throws -> Recording {
        guard canEditItems, let writer = attachmentWriter else { throw ItemError.notEditable }
        let info = try? await Task.detached(priority: .userInitiated) { try AudioProbe.probe(file: file) }.value
        if let prepare = prepareBlobWrite {
            let planned = try await Task.detached(priority: .userInitiated) {
                try BlobPlanning.ref(ofFile: file, type: "audio/mp4")
            }.value
            try await prepare(planned)
        }
        let ref = try await writer.addBlob(from: file, type: "audio/mp4")
        let recording = NoteOps.recording(blob: ref, started: started, info: info, title: title, id: id)
        let ops = try NoteOps.addRecording(recording, to: recordings)
        try await writeRecordingOps(ops)
        recordings.append(recording)
        recordings.sort(by: Recording.sortsBefore)
        return recording
    }

    /// Renames a recording (one `setRecording(title)`); an empty title clears it.
    func renameRecording(_ id: UUID, to title: String) async {
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (recordings[i].title ?? "") != t else { return }
        do {
            try await writeRecordingOps([.setRecording(recordingId: id, change: .title(t.isEmpty ? nil : t))])
            recordings[i].title = t.isEmpty ? nil : t
        } catch {
            recordingError = "Could not rename the recording: \(error)"
        }
    }

    /// Removes a recording (one `removeRecording`; its blob stays until
    /// collection, and history can restore it).
    func removeRecording(_ id: UUID) async {
        guard recordings.contains(where: { $0.id == id }) else { return }
        if player?.recording?.id == id { player?.stop() }
        do {
            try await writeRecordingOps([.removeRecording(recordingId: id)])
            recordings.removeAll { $0.id == id }
            playbackHighlight = [:]
        } catch {
            recordingError = "Could not delete the recording: \(error)"
        }
    }

    /// Takes a transcript written for this note elsewhere (the model's
    /// transcription job, through `NoteWriter.append`) into the open editor.
    func adoptTranscript(_ ref: BlobRef?, for id: UUID) {
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[i].transcript = ref
    }

    /// Writes `ops` as one delta now, after the ink still pending.
    private func writeRecordingOps(_ ops: [Op]) async throws {
        guard canEditItems else { throw ItemError.notEditable }
        await flush()
        guard let writer = attachmentWriter else { throw ItemError.notEditable }
        try await writeDirect(ops, with: writer)
    }

    // MARK: - Playback and ink

    /// Highlights the strokes written in the moments before `position` of
    /// `recording` (on every page), as playback goes on.
    func updatePlaybackHighlight(_ recording: Recording, at position: Double) {
        let state = recordingState
        var next: [UUID: Set<UUID>] = [:]
        for page in pages {
            let ids = RecordingSync.highlighted(liveStrokes(of: page.id), recording: recording.id, at: position, in: state)
            if !ids.isEmpty { next[page.id] = ids }
        }
        if next != playbackHighlight { playbackHighlight = next }
    }

    func clearPlaybackHighlight() {
        if !playbackHighlight.isEmpty { playbackHighlight = [:] }
    }

    /// The highlight boxes of playback on `pageID`.
    func playbackBoxes(onPage pageID: UUID) -> [HighlightBox] {
        guard let ids = playbackHighlight[pageID], !ids.isEmpty else { return [] }
        return liveStrokes(of: pageID).filter { ids.contains($0.id) }.compactMap(RecordingSync.box(of:))
            .map { HighlightBox(box: $0, isCurrent: false, style: .playback) }
    }

    /// Where a tap at page point (`x`, `y`) should play from: the recording
    /// and time of the earliest linked stroke under it, minus the lead-in.
    func seekTarget(pageID: UUID, x: Double, y: Double, tolerance: Double = 12) -> (recording: Recording, time: Double)? {
        let hits = RecordingSync.hit(x: x, y: y, in: liveStrokes(of: pageID), tolerance: tolerance)
        return RecordingSync.seekTarget(for: hits, in: recordingState)
    }

    /// A tap on the canvas in "Tap Ink to Play" mode.
    func inkTapped(pageID: UUID, x: Double, y: Double) {
        guard let target = seekTarget(pageID: pageID, x: x, y: y) else { return }
        onPlayRequest?(target.recording, target.time)
    }
}
