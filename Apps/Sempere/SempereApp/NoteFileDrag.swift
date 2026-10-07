import Foundation
import UniformTypeIdentifiers

/// A note dragged out of the app to the Finder (or any app that takes files)
/// as a PDF (Mac, docs/mac.md "Drag a note out as PDF").
///
/// On a Mac the drop becomes a file promise, and the system may ask for the
/// file while the main thread waits for it. So the main-actor part (saving
/// the note's pending ink, the iCloud download: `AppModel.prepareExport`)
/// starts when the drag begins, and the file request only waits for it and
/// renders off the main actor: it never needs the main thread itself.
enum NoteFileDrag {
    /// Starts preparing `noteID` for export (the drag began).
    @MainActor
    static func prepare(_ noteID: UUID, model: AppModel) -> Task<PreparedExport, any Error> {
        Task { try await model.prepareExport(noteID: noteID) }
    }

    /// The name the dropped file gets, without its extension (the system adds `.pdf`).
    static func suggestedName(title: String) -> String {
        let name = ExportFileName.pdf(title: title)
        return String(name.dropLast(".pdf".count))
    }

    /// Registers the note's PDF on `provider`: rendered when a drop asks for
    /// it, from `prepare`, on a background task.
    static func register(on provider: NSItemProvider, title: String, prepare: Task<PreparedExport, any Error>) {
        provider.suggestedName = suggestedName(title: title)
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [],
                                            visibility: .all) { completion in
            load(prepare) { completion($0, false, $1) }
        }
    }

    /// What a drop's request for the file runs: waits for `prepare`, renders
    /// and writes the PDF on a background task and hands its URL (or the
    /// error) to `completion`, on that task. Never needs the main thread.
    @discardableResult
    static func load(_ prepare: Task<PreparedExport, any Error>,
                     completion: @escaping @Sendable (URL?, (any Error)?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task.detached(priority: .userInitiated) {
            do {
                let prepared = try await prepare.value
                try Task.checkCancellation()
                completion(try prepared.write(), nil)
            } catch {
                completion(nil, error)
            }
            progress.completedUnitCount = 1
        }
        progress.cancellationHandler = { prepare.cancel() }
        return progress
    }
}
