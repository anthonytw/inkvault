import InkVault
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
        List(model.visibleNotes, id: \.id, selection: $model.selectedNoteID) { note in
            NoteRow(note: note, placeholder: model.placeholderNoteIDs.contains(note.id),
                    downloading: model.pendingNoteIDs.contains(note.id))
                .contextMenu { actions(for: note) }
                .swipeActions(edge: .trailing) {
                    if note.deleted {
                        Button("Restore", systemImage: "arrow.uturn.backward") { run { try await model.restoreNote(note.id) } }
                            .tint(.green)
                    } else {
                        Button("Delete", systemImage: "trash", role: .destructive) { run { try await model.deleteNote(note.id) } }
                    }
                }
        }
        .navigationTitle(title)
        .searchable(text: $model.searchText, prompt: "Search titles")
        .toolbar {
            ToolbarItem {
                Menu("Sort", systemImage: "arrow.up.arrow.down") {
                    Picker("Sort By", selection: $model.sortOrder) {
                        ForEach(NoteSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            }
            ToolbarItem {
                Button("New Note", systemImage: "square.and.pencil") { creating = true }
                    .disabled(model.phase != .unlocked)
            }
        }
        .overlay {
            if model.phase == .unlocked && model.visibleNotes.isEmpty {
                if model.searchText.isEmpty {
                    ContentUnavailableView("No Notes", systemImage: "note.text")
                } else {
                    ContentUnavailableView.search(text: model.searchText)
                }
            } else if model.isBusy {
                ProgressView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.pendingNoteIDs.isEmpty {
                let n = model.pendingNoteIDs.count
                Label(model.cloudFailure.map { "iCloud: \($0)" }
                      ?? "Downloading \(n) note\(n == 1 ? "" : "s") from iCloud…",
                      systemImage: "icloud.and.arrow.down")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(.bar)
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
            Label {
                Text("Downloading from iCloud…").foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary)
            }
            .font(.headline)
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
                    Image(systemName: "icloud.and.arrow.down").font(.caption).foregroundStyle(.secondary)
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
                    ForEach(note.tags.prefix(4), id: \.self) { TagChip(tag: $0) }
                    if note.tags.count > 4 { Text("+\(note.tags.count - 4)").font(.caption2).foregroundStyle(.secondary) }
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}
