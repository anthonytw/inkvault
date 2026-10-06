import Sempere
import SwiftUI

/// Title, paper and notebook for a new note.
struct NewNoteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var paper = PaperPreference.load()
    @State private var choosingPaper = false
    @Environment(\.displayScale) private var displayScale
    @State private var notebook: String
    @State private var failure: String?

    init(notebook: String?) {
        _notebook = State(initialValue: notebook ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                Button { choosingPaper = true } label: {
                    HStack(spacing: 12) {
                        Image(uiImage: PaperImage.image(for: paper, size: CGSize(width: 44, height: 57), scale: displayScale))
                            .resizable()
                            .aspectRatio(612.0 / 792.0, contentMode: .fit)
                            .frame(height: 57)
                            .overlay(Rectangle().stroke(SwiftUI.Color.secondary.opacity(0.5), lineWidth: 1))
                        VStack(alignment: .leading) {
                            Text("Paper").foregroundStyle(.primary)
                            Text(paper.kind.title).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
                .sheet(isPresented: $choosingPaper) {
                    PaperPickerView(paper: paper, purpose: .newNote) { chosen, _ in paper = chosen }
                }
                TextField("Notebook (optional; School/Math for levels)", text: $notebook)
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle("New Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            do {
                                try await model.createNote(title: title, paper: paper, notebook: notebook)
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
