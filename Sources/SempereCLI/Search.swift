import ArgumentParser
import Foundation
import Sempere

struct SearchHit: Encodable {
    var noteId: String
    var title: String
    var notebook: String?
    /// 1-based; absent for a transcript hit.
    var page: Int?
    var pageId: String?
    var snippet: String
    var matches: Int
    /// `handwriting` (page recognition), `text` (a text box) or `transcript` (a recording's).
    var source: String
    /// The recogniser's name (`handwriting` and `transcript` hits; absent for a text box).
    var engine: String?
    /// The recognised words containing the term (`handwriting` hits only; empty otherwise).
    var words: [Word]
    /// The text box (`text` hits).
    var itemId: String?
    /// Its frame `[x, y, w, h]`.
    var box: [Double]?
    /// The recording and the segment's time in seconds (`transcript` hits).
    var recordingId: String?
    var recordingTitle: String?
    var start: Double?
    var end: Double?

    struct Word: Encodable { var text: String; var box: [Double] }

    /// Where the hit is, for the table: `p3`, `p3 text` or `rec 12:03`.
    var place: String {
        if let page { return "p\(page)" + (source == "text" ? " text" : "") }
        let t = Int(start ?? 0)
        return "rec \(String(format: "%d:%02d", t / 60, t % 60))" + (recordingTitle.map { " \($0)" } ?? "")
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
        abstract: "Search the recognised handwriting, typed text and (with --transcripts) transcripts of all notes.",
        discussion: """
            Case-insensitive substring search over each page's recognised text (from the Notability
            import or on-device recognition) and over the text of every text box. With --transcripts it
            also searches the transcript of each recording (this decrypts each transcript blob, so it is
            slower). Prints note title, where (p3, p3 text, rec 12:03) and a snippet; --json adds ids,
            the source of each hit and the boxes of the matching words. Deleted notes are skipped.
            """
    )

    @Argument(help: ArgumentHelp("Text to look for.", valueName: "term"))
    var term: String

    @Flag(name: .long, help: "Also search the transcripts of recordings (decrypts each transcript).")
    var transcripts = false

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
        var transcriptProblems = 0
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
            let noteId = id.uuidString.lowercased()
            for (index, page) in state.pages.enumerated() {
                let pageId = page.id.uuidString.lowercased()
                if let rec = page.recognition {
                    let found = RecognitionSearch.ranges(of: needle, in: rec.text)
                    if let first = found.first {
                        let words = rec.words.filter { w in
                            tokens.contains { w.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                        }
                        hits.append(SearchHit(noteId: noteId, title: title, notebook: state.meta.notebook, page: index + 1,
                                              pageId: pageId, snippet: RecognitionSearch.snippet(rec.text, around: first),
                                              matches: found.count, source: "handwriting", engine: rec.engine,
                                              words: words.map { .init(text: $0.text, box: [$0.box.x, $0.box.y, $0.box.w, $0.box.h]) }))
                    }
                }
                for item in page.items where item.kind == .text {
                    guard let text = item.text?.string else { continue }
                    let found = RecognitionSearch.ranges(of: needle, in: text)
                    guard let first = found.first else { continue }
                    hits.append(SearchHit(noteId: noteId, title: title, notebook: state.meta.notebook, page: index + 1,
                                          pageId: pageId, snippet: RecognitionSearch.snippet(text, around: first),
                                          matches: found.count, source: "text", engine: nil, words: [],
                                          itemId: item.id.uuidString.lowercased(),
                                          box: [item.frame.x, item.frame.y, item.frame.w, item.frame.h]))
                }
            }
            if transcripts {
                for recording in state.recordings {
                    guard let ref = recording.transcript else { continue }
                    let transcript: Transcript
                    do {
                        transcript = try Transcript.decode(try vault.readBlob(note: id, ref, maxBytes: Transcript.maxSize))
                        guard transcript.recording == recording.id else {
                            throw CLIError.failure("it names another recording")
                        }
                    } catch {
                        transcriptProblems += 1
                        printStderr("warning: cannot read the transcript of recording \(recording.id.uuidString.lowercased()) in note \(noteId): \(CLIError.from(error).message)")
                        continue
                    }
                    for segment in transcript.segments {
                        let found = RecognitionSearch.ranges(of: needle, in: segment.text)
                        guard let first = found.first else { continue }
                        hits.append(SearchHit(noteId: noteId, title: title, notebook: state.meta.notebook, page: nil, pageId: nil,
                                              snippet: RecognitionSearch.snippet(segment.text, around: first), matches: found.count,
                                              source: "transcript", engine: transcript.engine, words: [],
                                              recordingId: recording.id.uuidString.lowercased(), recordingTitle: recording.title,
                                              start: segment.start, end: segment.end))
                    }
                }
            }
        }
        hits.sort {
            ($0.title.lowercased(), $0.noteId, $0.page ?? Int.max, $0.start ?? 0, $0.source)
                < ($1.title.lowercased(), $1.noteId, $1.page ?? Int.max, $1.start ?? 0, $1.source)
        }
        if output.json {
            try output.emitJSON(hits)
        } else if hits.isEmpty {
            output.info("No matches.")
        } else {
            var rows = output.quiet ? [] : [["TITLE", "WHERE", "TEXT"]]
            for h in hits { rows.append([h.title.isEmpty ? "(untitled)" : h.title, h.place, h.snippet]) }
            print(Format.table(rows))
        }
        if unreadable > 0 { throw CLIError.failure("\(unreadable) note(s) could not be read") }
        if transcriptProblems > 0 { throw CLIError.failure("\(transcriptProblems) transcript(s) could not be read") }
    }
}
