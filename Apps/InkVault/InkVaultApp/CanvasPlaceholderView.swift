import InkVault
import SwiftUI

/// Stand-in for the PencilKit canvas (task 3c): shows what the note holds.
struct CanvasPlaceholderView: View {
    let note: NoteSummary?

    var body: some View {
        if let note {
            ContentUnavailableView {
                Label(note.title.isEmpty ? "Untitled" : note.title, systemImage: "pencil.and.scribble")
            } description: {
                Text("\(note.pages) page(s), \(note.strokes) stroke(s). The canvas is not built yet.")
                if let problem = note.problem {
                    Text(problem).foregroundStyle(.orange)
                }
            }
            .navigationTitle(note.title.isEmpty ? "Untitled" : note.title)
        } else {
            ContentUnavailableView("No Note Selected", systemImage: "square.and.pencil")
        }
    }
}
