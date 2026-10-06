import Foundation
import Sempere

/// Highlighting the words a search found (recognition boxes, format.md §5.5)
/// on the canvas, and stepping through them across the note's pages.
extension NoteEditor {
    /// The pages as the highlight sees them: recognition that no longer
    /// describes the strokes (edited here, or a basis that does not match)
    /// is left out, since its boxes would sit in the wrong places. While the
    /// note is still opening from the cache its pages have no strokes yet, so
    /// the basis cannot be checked.
    private var pagesForHighlight: [Page] {
        pages.map { page in
            var page = page
            let stale = dirtyPages.contains(page.id) || (!isPreparing && RecognitionPolicy.needsRecognition(page))
            if stale { page.recognition = nil }
            return page
        }
    }

    /// Starts highlighting the words of `query`, on the first match of `page`
    /// (the page the search result named) when it has one, and shows it.
    /// Shows nothing when no word has a box (a match in the title, a tag, or
    /// text without boxes).
    func highlightSearch(query: String, page: UUID?) {
        guard !isPreparing else {
            pendingSearch = (query, page)   // `applyPendingSearch` runs when the pages are read
            return
        }
        pendingSearch = nil
        searchCursor = SearchMatchCursor(query: query, pages: pagesForHighlight, preferredPage: page)
        if searchCursor != nil { revealCurrentMatch() }
    }

    /// Runs a highlight asked for while the note was opening.
    func applyPendingSearch() {
        guard let pending = pendingSearch else { return }
        highlightSearch(query: pending.query, page: pending.page)
    }

    /// Stops highlighting.
    func clearSearchHighlight() {
        pendingSearch = nil
        searchCursor = nil
    }

    /// Moves to the next (`delta` 1) or previous (-1) match, wrapping around
    /// the note, showing its page and scrolling to it. The list is rebuilt
    /// first, so a page edited or re-read since is not stepped through with
    /// stale boxes.
    func stepSearchMatch(_ delta: Int) {
        guard var cursor = searchCursor?.refreshed(pages: pagesForHighlight) else {
            searchCursor = nil
            return
        }
        cursor.step(delta)
        searchCursor = cursor
        revealCurrentMatch()
    }

    /// What the canvas draws on page `id`: the matching boxes, the current one flagged.
    func highlightBoxes(onPage id: UUID) -> [HighlightBox] {
        guard let cursor = searchCursor else { return [] }
        return cursor.matches(onPage: id).map { HighlightBox(box: $0.match.box, isCurrent: $0.index == cursor.index) }
    }

    private func revealCurrentMatch() {
        guard let cursor = searchCursor else { return }
        showPage(id: cursor.current.pageId)
        revealToken &+= 1
    }
}

/// One highlighted word: its box in page points.
struct HighlightBox: Equatable, Sendable {
    var box: Recognition.Box
    var isCurrent: Bool
}
