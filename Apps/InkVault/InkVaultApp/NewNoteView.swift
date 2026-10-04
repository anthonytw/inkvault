import InkVault
import SwiftUI

/// Title, paper and notebook for a new note.
struct NewNoteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var paper = PaperKind.ruled
    @State private var notebook: String
    @State private var failure: String?

    init(notebook: String?) {
        _notebook = State(initialValue: notebook ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                Picker("Paper", selection: $paper) {
                    ForEach(PaperKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                TextField("Notebook (optional)", text: $notebook)
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle("New Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            do {
                                try await model.createNote(title: title, paper: Paper(kind: paper), notebook: notebook)
                                dismiss()
                            } catch { failure = "\(error)" }
                        }
                    }
                    .disabled(model.isEditing)
                }
            }
        }
    }
}
