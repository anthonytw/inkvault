import Sempere
import SwiftUI

/// What a notebook combo box offers (pure, tested).
enum NotebookChoices {
    /// How many suggestions show under the field while typing.
    static let shown = 8

    /// The existing notebooks matching `text`, best first (`NotebookPath.suggestions`).
    static func rows(matching text: String, among notebooks: [String], excluding: String? = nil,
                     limit: Int = shown) -> [String] {
        NotebookPath.suggestions(matching: text, among: notebooks, excluding: excluding, limit: limit)
    }

    /// True when `text` names a notebook that no note has yet (a new one is created by using it).
    static func isNew(_ text: String, among notebooks: [String]) -> Bool {
        guard let typed = NotebookPath.canonical(text) else { return false }
        return !notebooks.contains { NotebookPath.canonical($0) == typed }
    }

    /// A path as shown in a row: `School › Math`.
    static func display(_ path: String) -> String {
        NotebookPath.components(path).joined(separator: " › ")
    }
}

/// A combo box for a notebook path: type a new `/`-separated path, or pick an
/// existing notebook from the list that opens under the field and narrows as
/// you type (the chevron opens it without typing). Plain SwiftUI views in the
/// form's own flow rather than a popover or `Menu`, so it behaves the same on
/// an iPad, an iPhone (software keyboard) and a Mac.
struct NotebookField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    /// Existing notebooks (`AppModel.notebooks`).
    let notebooks: [String]
    /// Never offered (the note's own notebook, when moving).
    var excluding: String?
    @FocusState private var focused: Bool
    @State private var expanded = false

    private var rows: [String] {
        NotebookChoices.rows(matching: text, among: notebooks, excluding: excluding)
    }

    private var isOpen: Bool { (focused || expanded) && !rows.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(title, text: $text)
                    .focused($focused)
                    .autocorrectionDisabled()
                    #if !os(macOS)
                    .textInputAutocapitalization(.words)
                    #endif
                    .accessibilityIdentifier("notebookField")
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: isOpen ? "chevron.up.circle" : "chevron.down.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isOpen ? "Hide Notebooks" : "Show Notebooks")
                .disabled(notebooks.isEmpty)
            }
            if isOpen {
                ForEach(rows, id: \.self) { path in
                    Button {
                        text = path
                        expanded = false
                        focused = false
                    } label: {
                        Label(NotebookChoices.display(path), systemImage: "book.closed")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
            if NotebookChoices.isNew(text, among: notebooks) {
                Text("New notebook “\(NotebookChoices.display(NotebookPath.canonical(text) ?? ""))”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Moves one note to a notebook: the combo box, "No Notebook" and Move.
struct MoveNoteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let note: NoteSummary
    @State private var notebook: String

    init(note: NoteSummary) {
        self.note = note
        _notebook = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NotebookField(title: "Notebook (School/Math for levels)", text: $notebook,
                                  notebooks: model.notebooks, excluding: note.notebook)
                } header: {
                    Text(NoteTitle.display(note.title))
                } footer: {
                    if let current = NotebookPath.canonical(note.notebook) {
                        Text("Now in \(NotebookChoices.display(current)).")
                    }
                }
                if note.notebook != nil {
                    Button("No Notebook", role: .destructive) { move(to: nil) }
                }
            }
            .navigationTitle("Move to Notebook")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") { move(to: notebook) }
                        .disabled(NotebookPath.canonical(notebook) == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func move(to target: String?) {
        let id = note.id
        dismiss()
        Task { await model.report { try await model.moveNote(id, toNotebook: target) } }
    }
}
