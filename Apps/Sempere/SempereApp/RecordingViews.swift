import Sempere
import SwiftUI

/// "1:02:03" / "4:05".
enum RecordingClock {
    static func text(_ seconds: Double) -> String { Transcript.clock(seconds) }
}

/// The bar above the canvas while a recording is made or played
/// (docs/attachments.md §9): record controls (elapsed time, pause or resume,
/// stop; an interruption is shown and resumes by itself when the system says
/// so) and the player (play or pause, scrubber, "Tap Ink to Play", the
/// transcript).
struct RecordingBar: View {
    let editor: NoteEditor
    @Environment(AppModel.self) private var model
    @Binding var showingTranscript: Recording?

    var body: some View {
        VStack(spacing: 0) {
            if let session = editor.recordingSession, session.isActive {
                recorder(session)
            }
            if let player = editor.player, let recording = player.recording {
                playerRow(player, recording)
            }
            if let error = editor.recordingError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    Spacer()
                    Button("Dismiss") { editor.recordingError = nil }
                }
                .padding(.horizontal).padding(.vertical, 6)
                .background(.bar)
            }
        }
    }

    private func recorder(_ session: RecordingSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: session.state == .recording ? "record.circle.fill" : "pause.circle.fill")
                .foregroundStyle(session.state == .recording ? .red : .secondary)
                .symbolEffect(.pulse, isActive: session.state == .recording)
            Text(RecordingClock.text(session.elapsed)).monospacedDigit()
            switch session.state {
            case .interrupted:
                Text("Paused: another app is using the audio").font(.callout).foregroundStyle(.secondary)
            case .paused:
                Text("Paused").font(.callout).foregroundStyle(.secondary)
            default:
                Text("Recording").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if session.state == .recording {
                Button("Pause", systemImage: "pause.fill") { session.pauseByUser() }
                    .help("Pause the recording")
            } else {
                Button("Resume", systemImage: "record.circle") { session.resumeByUser() }
                    .help("Resume the recording")
            }
            Button("Stop", systemImage: "stop.fill") { Task { await editor.stopRecording() } }
                .buttonStyle(.borderedProminent).tint(.red)
                .help("Stop and save the recording")
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal).padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recordingBar")
    }

    private func playerRow(_ player: RecordingPlayer, _ recording: Recording) -> some View {
        HStack(spacing: 12) {
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                player.toggle()
            }
            .help("Play or pause the recording")
            Text(RecordingClock.text(player.position)).monospacedDigit().font(.callout)
            Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }),
                   in: 0...max(player.duration, 0.1))
            Text(RecordingClock.text(player.duration)).monospacedDigit().font(.callout).foregroundStyle(.secondary)
            Toggle("Tap Ink to Play", systemImage: "hand.tap", isOn: Binding(get: { editor.listeningToInk },
                                                                         set: { editor.listeningToInk = $0 }))
                .toggleStyle(.button)
                .help("Tap something you wrote during the recording to hear that moment")
            if recording.transcript != nil {
                Button("Transcript", systemImage: "text.quote") { showingTranscript = recording }
                    .help("Show the recording's transcript")
            }
            Button("Close Player", systemImage: "xmark") {
                editor.listeningToInk = false
                player.stop()
                editor.player = nil
            }
            .help("Close the player")
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal).padding(.vertical, 6)
        .background(.bar)
        .accessibilityIdentifier("playerBar")
    }
}

/// The note's recordings in a menu (toolbar): record, and per recording
/// play, transcribe, show the transcript, rename and delete.
struct RecordingsMenu: View {
    let editor: NoteEditor
    @Environment(AppModel.self) private var model
    @Binding var showingTranscript: Recording?
    @Binding var renaming: Recording?

    var body: some View {
        Menu {
            if !editor.isReadOnly {
                if editor.recordingSession?.isActive == true {
                    Button("Stop Recording", systemImage: "stop.fill") { Task { await editor.stopRecording() } }
                } else {
                    Button("Record", systemImage: "mic") { Task { await startRecording() } }
                }
            }
            if !editor.recordings.isEmpty {
                Divider()
                ForEach(editor.recordings) { r in
                    Menu(Self.title(r)) {
                        Button("Play", systemImage: "play") { Task { await model.play(r, in: editor) } }
                        if r.transcript != nil {
                            Button("Show Transcript", systemImage: "text.quote") { showingTranscript = r }
                        }
                        if !editor.isReadOnly {
                            Button(r.transcript == nil ? "Transcribe" : "Transcribe Again", systemImage: "waveform.and.mic") {
                                Task { await model.transcribe(r, in: editor) }
                            }
                            .disabled(model.transcribing.contains(r.id))
                            Button("Rename…", systemImage: "pencil") { renaming = r }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await editor.removeRecording(r.id) }
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Recordings", systemImage: editor.recordingSession?.isActive == true ? "mic.fill" : "mic")
        } primaryAction: {
            if editor.recordingSession?.isActive == true {
                Task { await editor.stopRecording() }
            } else if !editor.isReadOnly {
                Task { await startRecording() }
            }
        }
        .help("Tap: record or stop. Press and hold: the note's recordings")
    }

    /// "Lecture 3 – 52:10", "Recording 4 Oct 16:20 – 3:02".
    static func title(_ r: Recording) -> String {
        let name = r.title.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Recording \(r.started.formatted(date: .abbreviated, time: .shortened))"
        let length = r.duration.map { " – " + RecordingClock.text($0) } ?? ""
        let transcribed = r.transcript == nil ? "" : " ✎"
        return name + length + transcribed
    }

    private func startRecording() async {
        guard await AVAudioCaptureBackend.requestMicrophone() else {
            editor.recordingError = RecordingError.microphoneDenied.description
            return
        }
        do { try editor.startRecording() } catch {
            editor.recordingError = (error as? RecordingError)?.description ?? "Could not record: \(error)"
        }
    }
}

/// Renames a recording.
struct RenameRecordingSheet: View {
    let editor: NoteEditor
    let recording: Recording
    @Environment(\.dismiss) private var dismiss
    @State private var title: String

    init(editor: NoteEditor, recording: Recording) {
        self.editor = editor
        self.recording = recording
        _title = State(initialValue: recording.title ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
            }
            .navigationTitle("Rename Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rename") {
                        let t = title
                        Task { await editor.renameRecording(recording.id, to: t) }
                        dismiss()
                    }
                }
            }
        }
    }
}

/// A recording's transcript (format.md §8.3.2): segments with their times;
/// while the recording plays, the current word is highlighted (read-back),
/// words the recogniser was unsure of are grey and underlined, and a tap on
/// a word (or a segment's time) plays from there.
struct TranscriptView: View {
    let editor: NoteEditor
    let recording: Recording
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var loaded: Transcript?
    @State private var failed = false

    /// Words under this confidence are marked as doubtful.
    static let doubtful = 0.5

    private var transcript: Transcript? {
        if let p = editor.player, p.recording?.id == recording.id, let t = p.transcript { return t }
        return loaded
    }

    /// The playing position in this recording, if it is the one playing.
    private var position: Double? {
        guard let p = editor.player, p.recording?.id == recording.id else { return nil }
        return p.position
    }

    var body: some View {
        NavigationStack {
            Group {
                if let transcript {
                    content(transcript)
                } else if failed {
                    ContentUnavailableView("No Transcript", systemImage: "text.quote",
                                           description: Text("The transcript could not be read."))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(RecordingsMenu.title(recording))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            if transcript == nil {
                loaded = await model.loadTranscript(recording, note: editor.noteID)
                failed = loaded == nil
            }
        }
    }

    private func content(_ t: Transcript) -> some View {
        let current = position.flatMap { t.position(at: $0) }
        return ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(Array(t.segments.enumerated()), id: \.offset) { i, segment in
                        VStack(alignment: .leading, spacing: 4) {
                            Button(RecordingClock.text(segment.start)) { seek(segment.start) }
                                .font(.caption.monospacedDigit())
                                .buttonStyle(.borderless)
                            if let words = segment.words, !words.isEmpty {
                                WordFlow(spacing: 4) {
                                    ForEach(Array(words.enumerated()), id: \.offset) { j, w in
                                        wordView(w, current: current?.segment == i && current?.word == j)
                                    }
                                }
                            } else {
                                Text(segment.text)
                                    .background(current?.segment == i ? Color.yellow.opacity(0.4) : .clear)
                                    .onTapGesture { seek(segment.start) }
                            }
                        }
                        .id(i)
                    }
                } footer: {
                    Text("\(t.language) · \(t.engine) · transcribed on device")
                }
            }
            .onChange(of: current?.segment) { _, seg in
                if let seg { withAnimation { proxy.scrollTo(seg, anchor: .center) } }
            }
        }
    }

    private func wordView(_ w: Transcript.Word, current: Bool) -> some View {
        let unsure = (w.c ?? 1) < Self.doubtful
        return Text(w.t)
            .foregroundStyle(unsure ? .secondary : .primary)
            .underline(unsure, pattern: .dot)
            .padding(.horizontal, 2)
            .background(current ? Color.yellow.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 3))
            .onTapGesture { seek(w.start) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(unsure ? "Uncertain word. Plays from here." : "Plays from here.")
    }

    private func seek(_ t: Double) {
        Task { await model.play(recording, in: editor, from: t) }
    }
}

/// Words laid out in lines, wrapping like text.
struct WordFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            maxX = max(maxX, x)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
