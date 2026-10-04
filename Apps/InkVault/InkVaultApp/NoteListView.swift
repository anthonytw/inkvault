import InkVault
import SwiftUI

/// The notes matching the sidebar selection.
struct NoteListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(model.visibleNotes, id: \.id, selection: $model.selectedNoteID) { note in
            NoteRow(note: note)
        }
        .navigationTitle("Notes")
        .overlay {
            if model.phase == .unlocked && model.visibleNotes.isEmpty {
                ContentUnavailableView("No Notes", systemImage: "note.text")
            } else if model.isBusy {
                ProgressView()
            }
        }
        .refreshable {
            await model.report { try await model.reload() }
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
