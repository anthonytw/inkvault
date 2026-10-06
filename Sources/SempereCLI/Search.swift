import ArgumentParser
import Foundation
import Sempere

struct SearchHit: Encodable {
    var noteId: String
    var title: String
    var notebook: String?
    var page: Int
    var pageId: String
    var snippet: String
    var matches: Int
    var engine: String
    var words: [Word]
    /// With `--show-boxes`: every matching word on the page, numbered as the app steps through them.
    var locations: [Location]?

    struct Word: Encodable { var text: String; var box: [Double] }
    struct Location: Encodable {
        /// 1-based position among all matches in the note (pages in order), as in "3 of 12".
        var n: Int
        /// How many matches the note has.
        var of: Int
        var text: String
        /// `[x, y, w, h]` in page points.
        var box: [Double]
    }
}

enum RecognitionSearch {
    /// Occurrences of `term` in `text`, ignoring case.
    static func ranges(of term: String, in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex, let r = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive],
                                                       range: from..<text.endIndex) {
            out.append(r)
            from = r.upperBound > r.lowerBound ? r.upperBound : text.index(after: r.lowerBound)
        }
        return out
    }

    /// A one-line excerpt around `range`, with `…` where it was cut.
    static func snippet(_ text: String, around range: Range<String.Index>, context: Int = 30) -> String {
        let start = text.index(range.lowerBound, offsetBy: -context, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: context, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end].split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }
}

struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search the recognised handwriting text of all notes.",
        discussion: """
            Case-insensitive substring search over each page's recognised text (from the Notability
            import or on-device recognition). Prints note title, page number and a snippet; --json adds
            ids and the boxes of the matching words. --show-boxes lists every matching word with its
            box and its number among the note's matches (across pages: the app's "3 of 12"); with
            --json it adds `locations` to each hit. Deleted notes are skipped.
            """
    )

    @Argument(help: ArgumentHelp("Text to look for.", valueName: "term"))
    var term: String

    @Flag(name: .customLong("show-boxes"), help: "Report where each match is: its word, box and number in the note.")
    var showBoxes = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ValidationError("the search term is empty") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        var hits: [SearchHit] = []
        var unreadable = 0
        let ids = try vault.noteIDs()
        for (id, result) in zip(ids, vault.states(of: ids, detail: .withoutStrokePoints)) {
            let state: NoteState
            let title: String
            switch result {
            case .success(let s): state = s
            case .failure(let error):
                unreadable += 1
                printStderr("warning: cannot read note \(id.uuidString.lowercased()): \(CLIError.from(error).message)")
                continue
            }
            guard !state.deleted else { continue }
            title = state.meta.title
            let located = showBoxes ? SearchMatches.matches(words: tokens, in: state.pages) : []
            for (index, page) in state.pages.enumerated() {
                guard let rec = page.recognition else { continue }
                let found = RecognitionSearch.ranges(of: needle, in: rec.text)
                guard let first = found.first else { continue }
                let words = rec.words.filter { w in
                    tokens.contains { w.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                }
                let locations: [SearchHit.Location]? = showBoxes
                    ? located.enumerated().filter { $0.element.pageId == page.id }.map {
                        .init(n: $0.offset + 1, of: located.count, text: $0.element.text,
                              box: [$0.element.box.x, $0.element.box.y, $0.element.box.w, $0.element.box.h])
                    } : nil
                hits.append(SearchHit(noteId: id.uuidString.lowercased(), title: title, notebook: state.meta.notebook,
                                      page: index + 1, pageId: page.id.uuidString.lowercased(),
                                      snippet: RecognitionSearch.snippet(rec.text, around: first), matches: found.count,
                                      engine: rec.engine,
                                      words: words.map { .init(text: $0.text, box: [$0.box.x, $0.box.y, $0.box.w, $0.box.h]) },
                                      locations: locations))
            }
        }
        hits.sort { ($0.title.lowercased(), $0.noteId, $0.page) < ($1.title.lowercased(), $1.noteId, $1.page) }
        if output.json {
            try output.emitJSON(hits)
        } else if hits.isEmpty {
            output.info("No matches.")
        } else {
            var rows = output.quiet ? [] : [["TITLE", "PAGE", "TEXT"]]
            for h in hits { rows.append([h.title.isEmpty ? "(untitled)" : h.title, String(h.page), h.snippet]) }
            print(Format.table(rows))
            if showBoxes {
                for h in hits {
                    for l in h.locations ?? [] {
                        let box = l.box.map { String(format: "%.1f", $0) }.joined(separator: ", ")
                        print("  \(h.noteId.prefix(8)) p.\(h.page)  \(l.n) of \(l.of)  \(l.text)  [\(box)]")
                    }
                }
            }
        }
        if unreadable > 0 { throw CLIError.failure("\(unreadable) note(s) could not be read") }
    }
}
