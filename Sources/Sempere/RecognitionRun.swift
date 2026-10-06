import Foundation

/// One page's recognition, valid for the strokes whose digest it carries.
public struct RecognitionJob: Hashable, Sendable {
    public var page: UUID
    /// `RecognitionBasis.digest` of the page's strokes when it was read.
    public var digest: String
    /// Nil clears the page's recognition (a page left without strokes).
    public var recognition: Recognition?

    public init(page: UUID, digest: String, recognition: Recognition?) {
        self.page = page; self.digest = digest; self.recognition = recognition
    }
}

/// A note a "recognise all" run changed: what the results list shows
/// ("Recognized 12 notes", each with its title and page count) and what
/// `sempere recognize --json` reports.
public struct RecognizedNote: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var title: String
    /// Pages the note has.
    public var pages: Int
    /// Pages whose recognition this run wrote.
    public var pagesRecognized: Int

    public init(id: UUID, title: String, pages: Int, pagesRecognized: Int) {
        self.id = id; self.title = title; self.pages = pages; self.pagesRecognized = pagesRecognized
    }

    enum CodingKeys: String, CodingKey { case id = "note", title, pages, pagesRecognized }
}

/// Reading the handwriting of whole notes (shared by the app's "Recognise
/// All Notes" and `sempere recognize`).
public enum RecognitionRun {
    /// The pages of `state` whose recognition is missing or out of date.
    public static func pagesNeeding(_ state: NoteState) -> [Page] {
        state.pages.filter { RecognitionPolicy.needsRecognition($0) }
    }

    /// The `setPageRecognition` ops that `jobs` still stand for in `current`:
    /// each page is written only if its strokes are still the ones that were
    /// read (another device may have edited the note meanwhile). A deleted or
    /// missing note gets none.
    public static func ops(for jobs: [RecognitionJob], in current: NoteState?) -> [Op] {
        guard let current, !current.deleted else { return [] }
        return jobs.compactMap { job -> Op? in
            guard let page = current.pages.first(where: { $0.id == job.page }),
                  RecognitionBasis.digest(of: page) == job.digest else { return nil }
            return .setPageRecognition(pageId: job.page, recognition: job.recognition)
        }
    }
}

extension Vault {
    /// Reads the pages of note `noteId` that need it with `recognize` (called
    /// once per page with strokes, in page order, outside any file access)
    /// and writes their text as one delta from this device (`apply`). Returns
    /// nil when the note is deleted or nothing needed reading or still
    /// matched when the delta was made.
    ///
    /// - Throws: what `recognize` throws, and the errors of `apply` (an
    ///   unreadable revision makes the note read-only: nothing is written).
    @discardableResult
    public func recognizeNote(_ noteId: UUID, deviceState: URL, app: String, wall: Date = Date(),
                              recognize: (Page) throws -> Recognition) throws -> RecognizedNote? {
        let state = try reconstruct(try loadNote(noteId))
        guard !state.deleted else { return nil }
        var jobs: [RecognitionJob] = []
        for page in RecognitionRun.pagesNeeding(state) {
            let digest = RecognitionBasis.digest(of: page)
            var result: Recognition?
            if !page.strokes.isEmpty {
                var r = try recognize(page)
                r.basis = digest
                result = r
            }
            jobs.append(RecognitionJob(page: page.id, digest: digest, recognition: result))
        }
        guard !jobs.isEmpty else { return nil }
        var written = 0
        var title = state.meta.title
        var pages = state.pages.count
        try apply(to: noteId, deviceState: deviceState, app: app, wall: wall) { current in
            let ops = RecognitionRun.ops(for: jobs, in: current)
            written = ops.count
            title = current.meta.title
            pages = current.pages.count
            return ops
        }
        guard written > 0 else { return nil }
        return RecognizedNote(id: noteId, title: title, pages: pages, pagesRecognized: written)
    }
}
