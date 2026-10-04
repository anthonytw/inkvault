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
        enum Kind { case tag, notebook }
        let kind: Kind
        let note: UUID
        var id: String { "\(kind)-\(note)" }
    }

    var body: some View {
        @Bindable var model = model
        List(model.visibleNotes, id: \.id, selection: $model.selectedNoteID) { note in
            NoteRow(note: note)
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
        .refreshable {
            await model.report { try await model.reload() }
        }
        .sheet(isPresented: $creating) {
            NewNoteView(notebook: currentNotebook)
        }
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField(prompt?.kind == .tag ? "Tag" : "Notebook (School/Math for levels)", text: $promptText)
            Button("OK") {
                if let p = prompt {
                    let text = promptText
                    switch p.kind {
                    case .tag: run { try await model.addTag(text, to: p.note) }
                    case .notebook: run { try await model.moveNote(p.note, toNotebook: text) }
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
        prompt?.kind == .tag ? "Add Tag" : "Move to Notebook"
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task { await model.report(action) }
    }

    @ViewBuilder
    private func actions(for note: NoteSummary) -> some View {
        if note.deleted {
            Button("Restore", systemImage: "arrow.uturn.backward") { run { try await model.restoreNote(note.id) } }
        } else {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title.isEmpty ? "Untitled" : note.title)
                .font(.headline)
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
        }
    }
}
