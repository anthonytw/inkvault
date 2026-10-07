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

/// A note the app's "Recognize All Notes" changed: what the results list
/// shows ("Recognized 12 notes", each with its title and pages read).
public struct RecognizedNote: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    /// Pages the note has.
    public var pages: Int
    /// Pages whose recognition the run wrote.
    public var pagesRecognized: Int

    public init(id: UUID, title: String, pages: Int, pagesRecognized: Int) {
        self.id = id; self.title = title; self.pages = pages; self.pagesRecognized = pagesRecognized
    }
}
