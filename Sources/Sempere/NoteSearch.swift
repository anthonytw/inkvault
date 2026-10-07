import Foundation

/// The recognised text of one page, as search sees it.
public struct PageText: Hashable, Sendable, Codable {
    public var pageId: UUID
    /// 1-based position of the page in the note.
    public var number: Int
    public var text: String

    public init(pageId: UUID, number: Int, text: String) {
        self.pageId = pageId; self.number = number; self.text = text
    }

    /// The pages of a note (in display order) that have searchable text: the
    /// recognised handwriting, then the text of each text box and the page
    /// text of each PDF page in drawing order (format.md §8.2.4, §8.2.6),
    /// joined by newlines.
    public static func texts(of pages: [Page]) -> [PageText] {
        pages.enumerated().compactMap { i, p in
            var parts: [String] = []
            if let text = p.recognition?.text, !text.isEmpty { parts.append(text) }
            for item in p.items.sorted(by: Item.drawsBefore) {
                switch item.kind {
                case .text: if let text = item.text?.string, !text.isEmpty { parts.append(text) }
                case .pdfPage: if let text = item.pageText?.text, !text.isEmpty { parts.append(text) }
                default: break
                }
            }
            guard !parts.isEmpty else { return nil }
            return PageText(pageId: p.id, number: i + 1, text: parts.joined(separator: "\n"))
        }
    }
}

/// One note found by `NoteSearch`.
public struct NoteSearchHit: Hashable, Sendable, Identifiable {
    /// What a query word matched in a note.
    public enum Field: Int, Hashable, Sendable, Comparable, CaseIterable {
        case title, tag, notebook, text
        public static func < (a: Field, b: Field) -> Bool { a.rawValue < b.rawValue }
    }

    /// A piece of page text around the first match.
    public struct Snippet: Hashable, Sendable {
        public var text: String
        /// Where the query words are in `text`.
        public var matches: [Range<String.Index>]
    }

    public var id: UUID { note }
    public var note: UUID
    /// Where the query matched, in `Field` order.
    public var fields: [Field]
    /// The page the match is on: the one with most of the query's words
    /// (the first of them on a tie). Nil when only title, tags or notebook matched.
    public var page: PageText?
    public var snippet: Snippet?
    /// How many pages have at least one query word.
    public var matchedPages: Int
    public var score: Int
}

/// Search over note titles, notebooks, tags and recognised handwriting
/// (`NoteSummary.pageTexts`).
///
/// A query is words separated by whitespace; a note matches when every word
/// is found somewhere in it (case, accents and width ignored, substrings
/// count). A word starting with `#` only matches tags. Cost: O(Σ text length
/// × words), no index, which is a few milliseconds per megabyte of
/// recognised text.
public enum NoteSearch {
    /// Caps keep a pathological query or page from costing more than the text itself.
    public static let maxWords = 12
    public static let snippetBefore = 50
    public static let snippetAfter = 90

    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    struct Word: Hashable {
        var text: String
        var tagOnly: Bool
    }

    static func words(_ query: String) -> [Word] {
        var seen = Set<Word>()
        var out: [Word] = []
        for raw in query.split(whereSeparator: \.isWhitespace) {
            var w = String(raw)
            let tagOnly = w.hasPrefix("#")
            if tagOnly { w.removeFirst() }
            guard !w.isEmpty else { continue }
            let word = Word(text: w, tagOnly: tagOnly)
            if seen.insert(word).inserted { out.append(word) }
            if out.count == maxWords { break }
        }
        return out
    }

    /// The notes of `notes` matching `query`, best first (score, then newest, then title).
    /// An empty query matches nothing.
    public static func search(_ query: String, in notes: [NoteSummary]) -> [NoteSearchHit] {
        let words = words(query)
        guard !words.isEmpty else { return [] }
        let hits = notes.compactMap { hit(words, in: $0) }
        // Not `uniqueKeysWithValues`: a list holding one id twice must not trap.
        let modified = Dictionary(notes.map { ($0.id, $0.modified ?? .distantPast) }, uniquingKeysWith: { a, _ in a })
        let titles = Dictionary(notes.map { ($0.id, $0.title.lowercased()) }, uniquingKeysWith: { a, _ in a })
        return hits.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let (a, b) = (modified[$0.id] ?? .distantPast, modified[$1.id] ?? .distantPast)
            if a != b { return a > b }
            return (titles[$0.id] ?? "", $0.id.uuidString) < (titles[$1.id] ?? "", $1.id.uuidString)
        }
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: options) != nil
    }

    private static func equal(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: options) == .orderedSame
    }

    private static func hit(_ words: [Word], in note: NoteSummary) -> NoteSearchHit? {
        var fields = Set<NoteSearchHit.Field>()
        var score = 0
        var pageWords: [Int: Set<Int>] = [:]   // page index → indices of words found there
        for (wi, word) in words.enumerated() {
            var best = 0
            if !word.tagOnly {
                if contains(note.title, word.text) {
                    fields.insert(.title)
                    best = max(best, equal(note.title, word.text) ? 150 : 100)
                }
                if let nb = NotebookPath.canonical(note.notebook), contains(nb, word.text) {
                    fields.insert(.notebook)
                    best = max(best, NotebookPath.components(nb).contains { equal($0, word.text) } ? 50 : 30)
                }
            }
            for tag in note.tags where contains(tag, word.text) {
                fields.insert(.tag)
                best = max(best, equal(tag, word.text) ? 80 : 40)
            }
            if !word.tagOnly {
                for (pi, page) in note.pageTexts.enumerated() where contains(page.text, word.text) {
                    fields.insert(.text)
                    pageWords[pi, default: []].insert(wi)
                    best = max(best, 10)
                }
            }
            if best == 0 { return nil }   // every word must be found
            score += best
        }
        var page: PageText?
        var snippet: NoteSearchHit.Snippet?
        if let bestIndex = pageWords.max(by: { ($0.value.count, -$0.key) < ($1.value.count, -$1.key) })?.key {
            let best = note.pageTexts[bestIndex]
            page = best
            snippet = Self.snippet(best.text, words: words.map(\.text))
            score += 5 * (pageWords[bestIndex]?.count ?? 0) + min(pageWords.count, 5)
        }
        return NoteSearchHit(note: note.id, fields: fields.sorted(), page: page, snippet: snippet,
                             matchedPages: pageWords.count, score: score)
    }

    /// A line-flattened excerpt of `text` around its first match of any of `words`.
    static func snippet(_ text: String, words: [String]) -> NoteSearchHit.Snippet? {
        let flat = String(text.map { $0.isNewline ? " " : $0 })
        var first: Range<String.Index>?
        for w in words {
            if let r = flat.range(of: w, options: options), first.map({ r.lowerBound < $0.lowerBound }) ?? true { first = r }
        }
        guard let first else { return nil }
        let lower = flat.index(first.lowerBound, offsetBy: -snippetBefore, limitedBy: flat.startIndex) ?? flat.startIndex
        let upper = flat.index(first.upperBound, offsetBy: snippetAfter, limitedBy: flat.endIndex) ?? flat.endIndex
        let prefix = lower > flat.startIndex ? "…" : "", suffix = upper < flat.endIndex ? "…" : ""
        let body = String(flat[lower..<upper])
        let shown = prefix + body + suffix
        var matches: [Range<String.Index>] = []
        for w in words {
            var from = shown.startIndex
            while from < shown.endIndex, let r = shown.range(of: w, options: options, range: from..<shown.endIndex) {
                matches.append(r)
                from = r.upperBound
            }
        }
        return .init(text: shown, matches: matches.sorted { $0.lowerBound < $1.lowerBound })
    }
}
