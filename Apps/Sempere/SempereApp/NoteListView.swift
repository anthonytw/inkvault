import Sempere
import SwiftUI

/// The notes matching the sidebar selection, with title search, sorting and
/// per-note actions.
struct NoteListView: View {
    @Environment(AppModel.self) private var model
    @State private var creating = false
    @State private var prompt: Prompt?
    @State private var promptText = ""

    /// A text prompt for one note.
    private struct Prompt: Identifiable {
        enum Kind { case tag, notebook, rename }
        let kind: Kind
        let note: UUID
        var id: String { "\(kind)-\(note)" }
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isSearchActive {
                SearchResultsList()
            } else {
                notesList
            }
        }
        .environment(\.editMode, Binding<EditMode>(get: { model.isSelectingNotes ? .active : .inactive },
                                         set: { setSelecting($0.isEditing) }))
        .navigationTitle(title)
        .searchable(text: $model.searchText, prompt: "Search notes and handwriting")
        .searchScopes($model.searchScope) {
            ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
        }
        .toolbar {
            if model.isSelectingNotes {
                ToolbarItem { ExportMenu(ids: model.exportTargetIDs) }
            }
            ToolbarItem {
                Button(model.isSelectingNotes ? "Done" : "Select") { setSelecting(!model.isSelectingNotes) }
                    .disabled(model.phase != .unlocked)
            }
            ToolbarItem {
                Menu("Sort", systemImage: "arrow.up.arrow.down") {
                    Picker("Sort By", selection: $model.sortOrder) {
                        ForEach(NoteSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            }
            ToolbarItem {
                Menu("Handwriting", systemImage: "text.viewfinder") {
                    Toggle("Recognize Handwriting", isOn: Binding(get: { model.recognizer != nil },
                                                                  set: { model.setHandwritingRecognition($0) }))
                    let waiting = model.notesNeedingRecognition.count
                    Button("Recognize \(waiting) Note\(waiting == 1 ? "" : "s") Now", systemImage: "wand.and.stars") {
                        model.startRecognizingNotes()
                    }
                    .disabled(waiting == 0 || model.recognizer == nil || model.recognitionProgress != nil)
                    Text("Handwriting is read on this device; the text is saved, encrypted, in the vault so every device can search it.")
                }
            }
            ToolbarItem {
                Button("New Note", systemImage: "square.and.pencil") { creating = true }
                    .disabled(model.phase != .unlocked)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let progress = model.recognitionProgress {
                    RecognitionBar(progress: progress) { model.cancelRecognizingNotes() }
                }
                VaultStatusBar(loading: model.loading, sync: model.cloudSync) { model.startCloudSync() }
            }
        }
        .refreshable {
            await model.report { try await model.reload() }
        }
        .sheet(isPresented: $creating) {
            NewNoteView(notebook: currentNotebook)
        }
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField(promptField, text: $promptText)
            Button("OK") {
                if let p = prompt {
                    let text = promptText
                    switch p.kind {
                    case .tag: run { try await model.addTag(text, to: p.note) }
                    case .notebook: run { try await model.moveNote(p.note, toNotebook: text) }
                    case .rename: run { try await model.renameNote(p.note, to: text) }
                    }
                }
                prompt = nil
            }
            Button("Cancel", role: .cancel) { prompt = nil }
        }
    }

    private var notesList: some View {
        List(model.visibleNotes, id: \.id, selection: listSelection) { note in
            NoteRow(note: note, placeholder: model.placeholderNoteIDs.contains(note.id),
                    downloading: model.pendingNoteIDs.contains(note.id))
                // A placeholder's summary is empty: nothing to act on until it arrives
                // (the model downloads a note before any edit anyway).
                .contextMenu { if !model.placeholderNoteIDs.contains(note.id) { actions(for: note) } }
                .swipeActions(edge: .trailing) {
                    if model.placeholderNoteIDs.contains(note.id) {
                        EmptyView()
                    } else if note.deleted {
                        Button("Restore", systemImage: "arrow.uturn.backward") { run { try await model.restoreNote(note.id) } }
                            .tint(.green)
                    } else {
                        Button("Delete", systemImage: "trash", role: .destructive) { run { try await model.deleteNote(note.id) } }
                    }
                }
        }
        .overlay {
            if let reason = model.emptyListReason {
                EmptyListView(reason: reason) { run { try await model.reload() } }
            }
        }
    }

    /// The list's selection: the open note, or the ticked notes while selecting. A
    /// command-click or shift-click on a keyboard selects several and starts selecting.
    private var listSelection: Binding<Set<UUID>> {
        Binding(
            get: { model.isSelectingNotes ? model.multiSelection : Set(model.selectedNoteID.map { [$0] } ?? []) },
            set: { picked in
                if model.isSelectingNotes || picked.count > 1 {
                    model.isSelectingNotes = true
                    model.multiSelection = picked
                } else {
                    model.selectedNoteID = picked.first
                }
            })
    }

    private func setSelecting(_ on: Bool) {
        guard on != model.isSelectingNotes else { return }
        model.isSelectingNotes = on
        // Start from the open note; leaving keeps it open and drops the ticks.
        model.multiSelection = on ? Set(model.selectedNoteID.map { [$0] } ?? []) : []
    }

    /// The notes a context-menu export acts on: the ticked ones when `note` is among them.
    private func exportIDs(for note: NoteSummary) -> [UUID] {
        model.isSelectingNotes && model.multiSelection.contains(note.id) ? model.exportTargetIDs : [note.id]
    }

    private var title: String {
        switch model.sidebarSelection ?? .allNotes {
        case .allNotes: return "Notes"
        case .notebook(let n): return NotebookPath.components(n).last ?? n
        case .tag(let t): return "#\(t)"
        case .deleted: return "Recently Deleted"
        }
    }

    private var currentNotebook: String? {
        if case .notebook(let n)? = model.sidebarSelection { return n }
        return nil
    }

    private var promptTitle: String {
        switch prompt?.kind {
        case .tag: return "Add Tag"
        case .rename: return "Rename Note"
        default: return "Move to Notebook"
        }
    }

    private var promptField: String {
        switch prompt?.kind {
        case .tag: return "Tag"
        case .rename: return "Title"
        default: return "Notebook (School/Math for levels)"
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task { await model.report(action) }
    }

    @ViewBuilder
    private func actions(for note: NoteSummary) -> some View {
        if note.deleted {
            Button("Restore", systemImage: "arrow.uturn.backward") { run { try await model.restoreNote(note.id) } }
            ExportMenu(ids: exportIDs(for: note))
        } else {
            Button("Rename…", systemImage: "pencil") {
                promptText = note.title; prompt = Prompt(kind: .rename, note: note.id)
            }
            Button("Add Tag…", systemImage: "tag") { promptText = ""; prompt = Prompt(kind: .tag, note: note.id) }
            if !note.tags.isEmpty {
                Menu("Remove Tag", systemImage: "tag.slash") {
                    ForEach(note.tags, id: \.self) { tag in
                        Button(tag) { run { try await model.removeTag(tag, from: note.id) } }
                    }
                }
            }
            Menu("Move to Notebook", systemImage: "book.closed") {
                ForEach(model.notebooks.filter { $0 != NotebookPath.canonical(note.notebook) }, id: \.self) { name in
                    Button(NotebookPath.components(name).joined(separator: " › ")) { run { try await model.moveNote(note.id, toNotebook: name) } }
                }
                Button("New Notebook…") { promptText = ""; prompt = Prompt(kind: .notebook, note: note.id) }
                if note.notebook != nil {
                    Button("No Notebook", role: .destructive) { run { try await model.moveNote(note.id, toNotebook: nil) } }
                }
            }
            ExportMenu(ids: exportIDs(for: note))
            Button("Delete", systemImage: "trash", role: .destructive) { run { try await model.deleteNote(note.id) } }
        }
    }
}

private struct NoteRow: View {
    let note: NoteSummary
    /// Not downloaded from iCloud yet: nothing is known about it but its id.
    var placeholder = false
    /// Files are (still) downloading; the summary may be out of date.
    var downloading = false

    var body: some View {
        if placeholder {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Downloading from iCloud…").foregroundStyle(.secondary)
            }
            .font(.headline)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Note downloading from iCloud")
        } else {
            summary
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.headline)
                if downloading {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Updating from iCloud")
                }
            }
            HStack(spacing: 6) {
                if let modified = note.modified {
                    Text(modified, format: .dateTime.year().month().day())
                }
                Text("\(note.pages) page\(note.pages == 1 ? "" : "s")")
                if let notebook = NotebookPath.canonical(note.notebook) {
                    Label(NotebookPath.components(notebook).joined(separator: " › "), systemImage: "book.closed").labelStyle(.titleAndIcon)
                }
                if note.problem != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Some revisions could not be read")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !note.tags.isEmpty {
                HStack(spacing: 4) {
                    // One chip per tag key: older notes may store two spellings.
                    let tags = NoteOps.normalizedTags(note.tags)
                    ForEach(tags.prefix(4), id: \.self) { TagChip(tag: $0) }
                    if tags.count > 4 { Text("+\(tags.count - 4)").font(.caption2).foregroundStyle(.secondary) }
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Why the list is empty: notes loading (with "Opening vault: N of M"),
/// downloading from iCloud, a failure with a retry, no search match, or
/// genuinely nothing there.
struct EmptyListView: View {
    let reason: EmptyListReason
    let retry: () -> Void

    var body: some View {
        switch reason {
        case .loading(let loading):
            VStack(spacing: 12) {
                ProgressView()
                Text(loading?.headline ?? "Opening vault…").font(.headline).monospacedDigit()
                Text("Notes appear here as they are read.").font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .downloading(let sync):
            VStack(spacing: 12) {
                ProgressView(value: sync.fractionCompleted).frame(maxWidth: 240)
                Text(sync.headline).font(.headline).monospacedDigit()
                Text("Notes appear here as iCloud Drive delivers them.").font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            ContentUnavailableView {
                Label("Notes Could Not Be Listed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", action: retry)
            }
        case .noMatches(let query):
            ContentUnavailableView.search(text: query)
        case .emptySelection:
            ContentUnavailableView("No Notes Here", systemImage: "note.text",
                                   description: Text("Nothing in this notebook, tag or list."))
        case .emptyVault:
            ContentUnavailableView("No Notes", systemImage: "note.text",
                                   description: Text("This vault has no notes yet. Create one with the New Note button."))
        }
    }
}

/// Below the note list: reading notes ("Opening vault: 120 of 640 notes",
/// or "Updating notes" over a list already shown) and iCloud downloads, in
/// one place. Hidden when there is nothing to report.
struct VaultStatusBar: View {
    let loading: NoteLoading?
    let sync: CloudSyncStatus?
    let retry: () -> Void

    var body: some View {
        let showSync = sync.map { $0.isDownloading || $0.problem != nil } ?? false
        if loading != nil || showSync {
            VStack(alignment: .leading, spacing: 10) {
                if let loading {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(loading.headline).font(.footnote.weight(.semibold)).monospacedDigit()
                        ProgressView(value: loading.fractionCompleted)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let sync, showSync {
                    CloudSyncBar(status: sync, retry: retry)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}

/// The iCloud part of `VaultStatusBar`: "Downloading from iCloud: 37 of 128
/// notes" over a bar, files below; or why it stopped, with a retry. Hidden
/// once everything is local.
struct CloudSyncBar: View {
    let status: CloudSyncStatus
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if status.isDownloading {
                Text(status.headline).font(.footnote.weight(.semibold)).monospacedDigit()
                ProgressView(value: status.fractionCompleted)
                Text(status.detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let problem = status.problem {
                HStack(alignment: .firstTextBaseline) {
                    Label(problem, systemImage: "exclamationmark.icloud")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Retry", action: retry).font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Notes matching the search, each with the page and the words that matched;
/// a tap opens the note on that page.
private struct SearchResultsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.searchResults) { hit in
                if let note = model.note(for: hit) {
                    Button { model.openSearchHit(hit) } label: { SearchRow(hit: hit, note: note) }
                        .buttonStyle(.plain)
                        .listRowBackground(model.selectedNoteID == note.id ? SwiftUI.Color.accentColor.opacity(0.15) : nil)
                }
            }
        }
        .overlay {
            if model.isSearching && model.searchResults.isEmpty {
                ProgressView()
            } else if !model.isSearching && model.searchResults.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
    }
}

private struct SearchRow: View {
    let hit: NoteSearchHit
    let note: NoteSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(NoteTitle.display(note.title)).font(.headline)
                if let page = hit.page, note.pages > 1 {
                    Text("Page \(page.number)").font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if hit.matchedPages > 1 {
                    Text("+\(hit.matchedPages - 1) more").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let snippet = hit.snippet {
                Text(Self.highlighted(snippet)).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 6) {
                if let notebook = NotebookPath.canonical(note.notebook) {
                    Label(NotebookPath.components(notebook).joined(separator: " › "), systemImage: "book.closed")
                }
                if hit.fields.contains(.tag) {
                    Label(NoteOps.normalizedTags(note.tags).joined(separator: ", "), systemImage: "tag")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    static func highlighted(_ snippet: NoteSearchHit.Snippet) -> AttributedString {
        var text = AttributedString(snippet.text)
        for range in snippet.matches {
            if let r = Range(range, in: text) {
                text[r].font = .callout.bold()
                text[r].foregroundColor = .primary
            }
        }
        return text
    }
}

/// "Recognizing handwriting: 12 of 80 notes" with a cancel button.
struct RecognitionBar: View {
    let progress: RecognitionProgress
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Reading handwriting: \(progress.done) of \(progress.total) notes")
                    .font(.footnote.weight(.semibold)).monospacedDigit()
                Spacer()
                Button("Stop", action: cancel).font(.footnote)
            }
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            if progress.failed > 0 {
                Text("\(progress.failed) could not be read").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
