import ArgumentParser
import Foundation
import Sempere
import SempereRender

/// Reads the handwriting of notes and stores the text with word boxes as page
/// recognition (`format.md` §5.5), as the app's "Recognise All Notes" does:
/// the same `Vault.recognizeNote`, one delta per note.
struct RecognizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recognize",
        abstract: "Read the handwriting of notes (Apple platforms) and store the text for search.",
        discussion: """
            Reads every page whose recognition is missing or out of date (new or edited ink; an
            imported Notability text is kept) with Apple's Vision framework on an image of the page's
            ink, and writes the text and word boxes as page recognition, one delta per note. Names
            the notes it changed, with the number of pages read. Without NOTE it covers every note
            except deleted ones. A page edited by another device while it was read is left for the
            next run.

            Vision exists only on macOS: elsewhere the command stops with an error, except with
            --dry-run, which lists what a run would read and works everywhere. Exit 1 when a note
            could not be read or written (the others are still done).
            """
    )

    @Argument(help: ArgumentHelp("Notes to read: id, id prefix or exact title. Default: all notes that need it.",
                                 valueName: "note"))
    var notes: [String] = []

    @Flag(name: .long, help: "List the notes (and pages) that need reading; change nothing.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    struct Failure: Encodable { var note: String; var title: String; var error: String }

    struct Report: Encodable {
        /// Notes changed (with `--dry-run`: the notes that would be).
        var recognized: [RecognizedNote]
        var failed: [Failure]
        var dryRun: Bool
        /// The recogniser, e.g. `vision-26.0`; nil for a dry run.
        var engine: String?
    }

    func run() throws {
        let recognizer = dryRun ? nil : try Recognizer.make()
        let vault = try access.openVault(.required)
        var ids = try notes.isEmpty ? vault.noteIDs() : try notes.map { try vault.resolveNote($0) }
        ids = Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
        var targets: [NoteSummary] = []
        for s in try vault.summaries(of: ids) where !s.deleted && s.pagesNeedingRecognition > 0 {
            if s.problem != nil {
                // Named on the command line it is an error; in a sweep it is skipped with a warning.
                if !notes.isEmpty { throw CLIError.failure("note \(s.id.uuidString.lowercased()) has unreadable revisions") }
                printStderr("warning: skipping note \(s.id.uuidString.lowercased()): \(s.problem ?? "")")
                continue
            }
            targets.append(s)
        }
        var report = Report(recognized: [], failed: [], dryRun: dryRun, engine: recognizer?.engine)
        for s in targets {
            guard let recognizer else {
                report.recognized.append(RecognizedNote(id: s.id, title: s.title, pages: s.pages,
                                                        pagesRecognized: s.pagesNeedingRecognition))
                continue
            }
            do {
                if let done = try vault.recognizeNote(s.id, deviceState: DeviceState.defaultURL(), app: appName,
                                                      recognize: recognizer.recognize) {
                    report.recognized.append(done)
                    if output.verbose { printStderr("recognized \(done.title) (\(done.pagesRecognized) of \(done.pages) pages)") }
                }
            } catch {
                report.failed.append(Failure(note: s.id.uuidString.lowercased(), title: s.title,
                                             error: CLIError.from(error).message))
            }
        }
        report.recognized.sort { ($0.title.lowercased(), $0.id.uuidString) < ($1.title.lowercased(), $1.id.uuidString) }
        if output.json {
            try output.emitJSON(report)
        } else {
            let verb = dryRun ? "Would read" : "Recognized"
            output.info("\(verb) \(report.recognized.count) note\(report.recognized.count == 1 ? "" : "s").")
            if !report.recognized.isEmpty {
                var rows = output.quiet ? [] : [["NOTE", "TITLE", "PAGES READ"]]
                for n in report.recognized {
                    rows.append([String(n.id.uuidString.lowercased().prefix(8)), n.title.isEmpty ? "(untitled)" : n.title,
                                 "\(n.pagesRecognized) of \(n.pages)"])
                }
                print(Format.table(rows))
            }
            for f in report.failed { printStderr("error: \(f.title.isEmpty ? f.note : f.title): \(f.error)") }
        }
        if !report.failed.isEmpty { throw CLIError.failure("\(report.failed.count) note(s) could not be read") }
    }
}

/// Reads one page's ink.
struct Recognizer {
    var engine: String
    var recognize: (Page) throws -> Recognition

    /// The recogniser of this platform; throws where there is none.
    static func make() throws -> Recognizer {
        #if DEBUG
        // Tests stand in for Vision with a fixed text (never in release builds).
        if let text = Env.vars["SEMPERE_FAKE_RECOGNIZER"] {
            return Recognizer(engine: "fake-1") { page in
                Recognition(engine: "fake-1", text: text,
                            words: RecognitionLayout.distribute(text: text, in: .init(x: 10, y: 10, w: 200, h: 20)))
            }
        }
        #endif
        #if canImport(Vision)
        return Recognizer(engine: VisionRecognition.engine) { page in
            // A page that cannot be drawn throws (RenderError): an empty result would be stored
            // as current and never read again. A page with nothing to read (only markers) is
            // current with empty text, as in the app.
            guard let image = try RecognitionImage.render(strokes: page.strokes) else {
                return Recognition(engine: VisionRecognition.engine, text: "")
            }
            let lines = try VisionRecognition.lines(inPNG: image.png, region: image.region)
            return RecognitionLayout.assemble(engine: VisionRecognition.engine, lines: lines, basis: nil)
        }
        #else
        throw CLIError.failure("handwriting recognition needs Apple's Vision framework and runs on macOS only "
                               + "(use --dry-run to list what would be read)")
        #endif
    }
}
