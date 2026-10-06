import Foundation
import Sempere

/// Where a search looks.
enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    /// Every note (Recently Deleted only while it is the sidebar selection).
    case everywhere = "All Notes"
    /// The notes the sidebar selection shows.
    case list = "This List"

    var id: String { rawValue }
}

/// A page to show once its note is open.
struct PageJump: Equatable, Sendable {
    var note: UUID
    var page: UUID
}

/// "Recognise All Notes" while it runs.
struct RecognitionProgress: Equatable, Sendable {
    var done = 0
    var total: Int
    /// Notes that could not be read or written.
    var failed = 0
}

extension AppModel {
    // MARK: - Search

    /// The notes a search looks through.
    var searchCandidates: [NoteSummary] {
        switch searchScope {
        case .list: return notesInSelection
        case .everywhere:
            if case .deleted? = sidebarSelection { return notes.filter(\.deleted) }
            return notes.filter { !$0.deleted }
        }
    }

    /// True while the note list shows search results rather than the list.
    var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The summary of a hit's note.
    func note(for hit: NoteSearchHit) -> NoteSummary? {
        notes.first { $0.id == hit.note }
    }

    /// Re-runs the search after `searchDebounce`, off the main actor; an
    /// older search still running is dropped. Called whenever the query, the
    /// scope, the selection or the notes change.
    func updateSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchTask = nil
            isSearching = false
            if !searchResults.isEmpty { searchResults = [] }
            return
        }
        isSearching = true
        let candidates = searchCandidates
        let gen = generation
        let delay = searchDebounce
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            let hits = await Task.detached(priority: .userInitiated) { NoteSearch.search(query, in: candidates) }.value
            guard !Task.isCancelled, let self, gen == self.generation else { return }
            self.searchResults = hits
            self.isSearching = false
        }
    }

    /// Opens the note of `hit` on the page that matched.
    func openSearchHit(_ hit: NoteSearchHit) {
        pendingJump = hit.page.map { PageJump(note: hit.note, page: $0.pageId) }
        selectedNoteID = hit.note
        applyPendingJump()
    }

    /// Shows the pending page when its note is the one on the canvas; drops
    /// a jump that belongs to another note.
    func applyPendingJump() {
        guard let jump = pendingJump, let editor else { return }
        guard editor.noteID == jump.note else {
            if selectedNoteID != jump.note { pendingJump = nil }
            return
        }
        pendingJump = nil
        editor.showPage(id: jump.page)
    }

    // MARK: - Recognition

    /// Turns handwriting recognition on or off (remembered), for the open
    /// note and every note opened from now on.
    func setHandwritingRecognition(_ on: Bool) {
        RecognitionPreference.enabled = on
        recognizer = on ? VisionPageRecognizer() : nil
        if !on { cancelRecognizingNotes() }
    }

    /// Notes with pages never read (or changed since), that "Recognise All"
    /// would read. The open note and notes still downloading are left to the editor and the sync.
    var notesNeedingRecognition: [NoteSummary] {
        notes.filter {
            !$0.deleted && $0.problem == nil && $0.pagesNeedingRecognition > 0 && $0.id != editor?.noteID
                && !pendingNoteIDs.contains($0.id) && !placeholderNoteIDs.contains($0.id)
        }
    }

    /// Reads the handwriting of every note in `notesNeedingRecognition`, one
    /// note at a time, one delta per note.
    func startRecognizingNotes() {
        guard recognitionTask == nil, phase == .unlocked, let recognizer else { return }
        let ids = notesNeedingRecognition.map(\.id)
        guard !ids.isEmpty else { return }
        let gen = generation
        recognitionProgress = RecognitionProgress(total: ids.count)
        recognitionTask = Task { [weak self] in
            await self?.recognizeNotes(ids, with: recognizer, generation: gen)
            guard let self, gen == self.generation else { return }
            self.recognitionTask = nil
            self.recognitionProgress = nil
        }
    }

    func cancelRecognizingNotes() {
        recognitionTask?.cancel()
    }

    func recognizeNotes(_ ids: [UUID], with recognizer: any PageRecognizing, generation gen: Int) async {
        for id in ids {
            guard !Task.isCancelled, gen == generation else { return }
            do {
                try await recognizeNote(id, with: recognizer)
            } catch is CancellationError {
                return
            } catch {
                recognitionProgress?.failed += 1
            }
            recognitionProgress?.done += 1
        }
    }

    /// Reads the pages of note `id` that need it and writes their text in one
    /// delta. Each page is written only if its strokes are still the ones
    /// that were read when the delta is made (another device may have edited the note).
    func recognizeNote(_ id: UUID, with recognizer: any PageRecognizing) async throws {
        let gen = generation
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        try await downloadNote(id)
        try ensureCurrent(gen)
        let coordinate = coordinationURL
        let state: NoteState? = try await offMain {
            try CloudVault.coordinatedRead(coordinate) { () throws -> NoteState? in
                let loaded = try vault.loadNote(id)
                guard loaded.failures.isEmpty, !loaded.revisions.isEmpty else { return nil }   // read-only
                let state = try NoteReducer.reconstruct(loaded.revisions)
                return state.deleted ? nil : state
            }
        }
        try ensureCurrent(gen)
        guard let state else { return }
        var jobs: [RecognitionJob] = []
        for page in state.pages where RecognitionPolicy.needsRecognition(page) {
            let digest = RecognitionBasis.digest(of: page)
            var result: Recognition?
            if !page.strokes.isEmpty {
                var r = try await recognizer.recognize(strokes: page.strokes)
                r.basis = digest
                result = r
            }
            try Task.checkCancellation()
            try ensureCurrent(gen)
            jobs.append(RecognitionJob(page: page.id, digest: digest, recognition: result))
        }
        guard !jobs.isEmpty else { return }
        let planned = jobs
        try await commit(id) { current in
            guard let current else { return [] }
            return planned.compactMap { job -> Op? in
                guard let page = current.pages.first(where: { $0.id == job.page }),
                      RecognitionBasis.digest(of: page) == job.digest else { return nil }
                return .setPageRecognition(pageId: job.page, recognition: job.recognition)
            }
        }
    }
}

/// One page's recognition, valid for the strokes whose digest it carries.
struct RecognitionJob: Sendable {
    var page: UUID
    var digest: String
    var recognition: Recognition?
}
