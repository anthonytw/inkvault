import Foundation
import Sempere
import Observation
import PencilKit

/// One open note being edited: its reconstructed state, a `StrokeLedger`
/// per page, and autosave. Every drawing change updates the ledger at once;
/// after `debounce` without changes (and on `flush()`: page switch,
/// background, close) the net change is written as ONE delta.
@MainActor
@Observable
final class NoteEditor {
    let noteID: UUID
    /// Pages in display order, as loaded plus pages added here.
    private(set) var pages: [Page]
    private(set) var meta: NoteMeta
    /// Live page size; an infinite page grows here and is saved with the next delta.
    private(set) var pageSize: PageSize
    /// Paper being previewed by the paper picker (not saved); nil when none.
    private(set) var previewPaper: Paper?
    /// Index into `pages` of the page on the canvas.
    private(set) var pageIndex = 0
    /// Why the note cannot be edited, if it cannot.
    let readOnlyReason: String?
    /// The last autosave failure; cleared by the next successful save.
    private(set) var saveError: String?
    /// Deltas written by this editor (for tests and the UI).
    private(set) var deltasWritten = 0

    var isReadOnly: Bool { readOnlyReason != nil }
    var currentPage: Page? { pages.indices.contains(pageIndex) ? pages[pageIndex] : nil }

    /// The canvas showing this note, for menu commands (`CanvasCommandTarget`).
    @ObservationIgnored weak var canvasTarget: (any CanvasCommandTarget)?
    @ObservationIgnored private var ledgers: [UUID: StrokeLedger] = [:]
    @ObservationIgnored private var committedPageSize: PageSize
    /// Page additions and paper changes not yet written (written before any stroke ops).
    @ObservationIgnored private var pendingPageOps: [Op] = []
    @ObservationIgnored private let writer: NoteWriter?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var chain: Task<Void, Never>?
    /// Set by `close()` once its last save is done: a closed editor takes no
    /// more changes and writes nothing. A window or view may still show it for
    /// a moment, and it holds the vault as it was opened (with the old secret
    /// after a key change), so nothing it holds may reach the vault.
    @ObservationIgnored private(set) var isShutDown = false

    // Handwriting recognition (`PageRecognizing`).
    /// Reads pages after strokes change and on open; nil turns recognition off.
    @ObservationIgnored var recognizer: (any PageRecognizing)? {
        didSet { if recognizer != nil { scheduleRecognition() } }
    }
    /// Called with the note id after a page's recognition was written.
    @ObservationIgnored var onRecognized: (@MainActor (UUID) -> Void)?
    /// Pages whose strokes this editor changed and whose recognition is not
    /// redone yet: it replaces recognition that cannot be checked (an import).
    @ObservationIgnored private var touchedPages: Set<UUID> = []
    @ObservationIgnored private var recognitionDelay: Duration
    @ObservationIgnored private var recognitionTimer: Task<Void, Never>?
    @ObservationIgnored private var recognitionBusy = false
    @ObservationIgnored private var recognitionAgain = false
    @ObservationIgnored private var recognitionWrite: Task<Void, any Error>?
    @ObservationIgnored private var isClosed = false
    /// Recognitions written by this editor (for tests and the UI).
    private(set) var recognitionsWritten = 0
    /// The last recognition failure; cleared by the next success.
    private(set) var recognitionError: String?

    /// Ink closer than this to the bottom of an infinite page grows it.
    static let growMargin = 200.0
    /// How far below the ink an infinite page grows to.
    static let growStep = 400.0
    /// Default pause before an autosave.
    static let defaultDebounce = Duration.milliseconds(1500)
    /// Default pause after the last stroke change before pages are recognised.
    static let defaultRecognitionDelay = Duration.seconds(4)

    init(noteID: UUID, state: NoteState, writer: NoteWriter?, readOnlyReason: String?,
         debounce: Duration = NoteEditor.defaultDebounce, recognizer: (any PageRecognizing)? = nil,
         recognitionDelay: Duration = NoteEditor.defaultRecognitionDelay) {
        self.noteID = noteID
        self.pages = state.pages
        self.meta = state.meta
        self.pageSize = state.meta.pageSize
        self.committedPageSize = state.meta.pageSize
        self.writer = writer
        self.readOnlyReason = writer == nil ? (readOnlyReason ?? "This note is read-only.") : readOnlyReason
        self.debounce = debounce
        self.recognizer = recognizer
        self.recognitionDelay = recognitionDelay
    }

    /// Loads and reconstructs a note off the main actor. A note with
    /// unreadable revisions, or in Recently Deleted, opens read-only.
    /// `coordinated` (a vault in iCloud Drive): the note is read, and its
    /// deltas written, under `NSFileCoordinator` (`CloudVault`). `verify`
    /// runs inside that read before and after the note is loaded and throws
    /// to refuse a note whose files are not all local (`CloudVault.requireLocal`).
    static func open(vault: Vault, noteID: UUID, clock: DeviceClock,
                     debounce: Duration = NoteEditor.defaultDebounce,
                     recognizer: (any PageRecognizing)? = nil,
                     recognitionDelay: Duration = NoteEditor.defaultRecognitionDelay,
                     coordinated: Bool = false,
                     verify: (@Sendable () throws -> Void)? = nil) async throws -> NoteEditor {
        let device = clock.device
        let (state, failures, nextSeq, readings) = try await Task.detached(priority: .userInitiated) {
            let loaded = try CloudVault.coordinatedRead(coordinated ? vault.url : nil) {
                try verify?()
                let loaded = try vault.loadNote(noteID)
                try verify?()
                return loaded
            }
            let state = try NoteReducer.reconstruct(loaded.revisions)
            return (state, loaded.failures.count, Vault.nextSeq(from: loaded.revisions, device: device),
                    loaded.revisions.map(\.hlc))
        }.value
        await clock.observe(readings)
        var reason: String?
        if failures > 0 {
            reason = "\(failures) revision(s) of this note could not be read, so it opens read-only."
        } else if state.deleted {
            reason = "This note is in Recently Deleted."
        }
        let writer = reason == nil ? NoteWriter(vault: vault, noteID: noteID, clock: clock, nextSeq: nextSeq,
                                                coordinated: coordinated) : nil
        let editor = NoteEditor(noteID: noteID, state: state, writer: writer, readOnlyReason: reason,
                                debounce: debounce, recognizer: recognizer, recognitionDelay: recognitionDelay)
        editor.scheduleRecognition()   // pages that were never read, or changed elsewhere
        return editor
    }

    // MARK: - Pages

    /// The ledger of a page, created from its stored strokes on first use.
    private func ledger(_ pageID: UUID) -> StrokeLedger {
        if let l = ledgers[pageID] { return l }
        let stored = pages.first { $0.id == pageID }?.strokes ?? []
        let l = StrokeLedger(stored: stored, info: CanvasStrokeInfo.init(stored:))
        ledgers[pageID] = l
        return l
    }

    /// The drawing to show for a page: its live strokes, one canvas stroke
    /// each. Re-keys the page's ledger to match.
    func drawing(for pageID: UUID) -> PKDrawing {
        var l = ledger(pageID)
        l.rebase(info: CanvasStrokeInfo.init(stored:))
        ledgers[pageID] = l
        return l.drawing
    }

    /// Live strokes of a page (saved or not).
    func liveStrokes(of pageID: UUID) -> [Stroke] { ledger(pageID).live }

    /// Ink changes per page, so page thumbnails can follow them.
    private(set) var inkRevisions: [UUID: Int] = [:]
    /// Identifies this editor in cache keys (`inkRevisions` restart at 0 in
    /// every editor, so they alone cannot key a cache that outlives it).
    @ObservationIgnored let sessionID = UUID()
    /// Bumped when the shown page's strokes changed without a change of page
    /// (a layout switch keeps page 1's id): the canvas reloads its drawing, or
    /// its stale drawing would be diffed against the new page (ink removed or
    /// duplicated by the next stroke).
    private(set) var canvasGeneration = 0

    /// The strokes a page thumbnail shows: live once the page has been on
    /// the canvas, else as loaded (no ledger is made just for a thumbnail).
    func thumbnailStrokes(of page: Page) -> [Stroke] {
        ledgers[page.id]?.live ?? page.strokes
    }

    /// Shows the page `id` (a search hit); no-op when the note has no such page.
    func showPage(id: UUID) {
        if let i = pages.firstIndex(where: { $0.id == id }) { selectPage(i) }
    }

    /// Shows another page; pending changes are saved first.
    func selectPage(_ index: Int) {
        guard pages.indices.contains(index), index != pageIndex else { return }
        pageIndex = index
        Task { await flush() }
    }

    /// The paper to draw under `page`: the picker's preview while one is
    /// open, else the page's own paper, else the note's.
    func displayedPaper(of page: Page) -> Paper {
        previewPaper ?? page.paper ?? meta.paper
    }

    /// Shows `paper` under the canvas without saving it; nil ends the preview.
    func showPaperPreview(_ paper: Paper?) {
        previewPaper = paper?.validated()
    }

    /// Sets the paper of the current page, or of the whole note (every page),
    /// at once on screen; saved with the next delta (`NoteOps.setPaper`).
    func setPaper(_ paper: Paper, allPages: Bool) {
        previewPaper = nil
        guard !isReadOnly, !isShutDown, let page = currentPage else { return }
        let ops = NoteOps.setPaper(paper, scope: allPages ? .allPages : .page(page.id), note: meta, pages: pages)
        guard !ops.isEmpty else { return }
        for op in ops {
            switch op {
            case .setMeta(.paper(let p)): meta.paper = p
            case .setPagePaper(let id, let p):
                if let i = pages.firstIndex(where: { $0.id == id }) { pages[i].paper = p }
            default: break
            }
        }
        pendingPageOps += ops
        scheduleSave()
    }

    /// Appends a blank page and shows it; saved with the next delta.
    func addPage() {
        insertPage(at: pages.count)
    }

    /// Adds a blank page right after the one on the canvas and shows it.
    func addPageAfterCurrent() {
        insertPage(at: pages.isEmpty ? 0 : pageIndex + 1)
    }

    /// Adds a blank page at `index` of `pages` and shows it; saved with the
    /// next delta (with the first ink drawn on it, if that comes first).
    func insertPage(at index: Int) {
        guard !isReadOnly, !isShutDown else { return }
        let edit = NoteOps.addPage(at: index, in: pages)
        guard case .addPage(let page)? = edit.ops.first else { return }
        apply(edit, show: page.id)
        scheduleSave()
    }

    // MARK: - Page gestures (format.md §5.4.3): each is saved at once, one delta

    /// Whether the note is one infinite page rather than fixed-size pages.
    var isPageless: Bool { pageSize.infinite }

    /// A page deleted here, kept for undo with its live strokes and position.
    struct DeletedPage: Equatable {
        var page: Page
        var index: Int
    }

    /// Pages deleted while the note is open, newest last (`undoDeletePage`).
    private(set) var deletedPages: [DeletedPage] = []

    /// Moves the page at `from` so it ends up at `to` (indices into `pages`).
    func movePage(from: Int, to: Int) {
        guard !isReadOnly, !isShutDown, pages.indices.contains(from),
              let edit = NoteOps.movePage(pages[from].id, to: to, in: pages) else { return }
        apply(edit, show: currentPage?.id)
        saveNow()
    }

    /// Whether a page can be deleted: a note keeps at least one page.
    var canDeletePage: Bool { !isReadOnly && !isShutDown && pages.count > 1 }

    /// Deletes a page (`removePage`; its strokes go with it). Undo with
    /// `undoDeletePage`. The last page is never deleted.
    func deletePage(_ id: UUID) {
        guard canDeletePage, let index = pages.firstIndex(where: { $0.id == id }),
              let edit = NoteOps.deletePage(id, in: pages) else { return }
        let gone = livePages()[index]
        let shown = currentPage?.id == id ? nil : currentPage?.id
        apply(edit, show: shown)
        if shown == nil { pageIndex = min(index, max(pages.count - 1, 0)) }
        deletedPages.append(DeletedPage(page: gone, index: index))
        saveNow()
    }

    /// Re-creates the page deleted last, where it was (a new id with
    /// `parent`, its strokes under new ids: format.md §5.2), and shows it.
    func undoDeletePage() {
        guard !isReadOnly, !isShutDown, let last = deletedPages.popLast() else { return }
        let edit = NoteOps.restorePage(last.page, at: last.index, in: pages)
        guard case .addPage(let page)? = edit.ops.first else { return }
        apply(edit, show: page.id)
        saveNow()
    }

    /// Duplicates a page (its ink and paper) right after it and shows the copy.
    func duplicatePage(_ id: UUID) {
        guard !isReadOnly, !isShutDown, let edit = NoteOps.duplicatePage(id, in: livePages()),
              case .addPage(let page)? = edit.ops.first else { return }
        apply(edit, show: page.id)
        saveNow()
    }

    /// Switches the note between paged and pageless (format.md §5.4.3): ink
    /// not yet saved is saved first, then the switch is one delta. No ink is
    /// deleted or moved on its sheet; the canvas shows the page that holds
    /// what was on screen (the first after a join).
    func setLayout(pageless: Bool) async {
        guard !isReadOnly, !isShutDown, pageless != isPageless else { return }
        // Ink drawn while a save is being written is pending again afterwards:
        // save until nothing is, so the switch never takes unsaved ink as saved
        // (a few rounds at most: if ink keeps arriving, the switch is not made).
        var rounds = 0
        repeat {
            await flush()
            guard saveError == nil else { return }   // never switch over ink that could not be saved
            rounds += 1
        } while hasPendingChanges && rounds < 4
        guard !hasPendingChanges, !isShutDown, pageless != isPageless else { return }
        let shown = currentPage?.id
        let edit = pageless
            ? NoteOps.makePageless(pages: livePages(), pageSize: pageSize)
            : NoteOps.makePaged(pages: livePages(), pageSize: pageSize)
        guard !edit.ops.isEmpty else { return }
        ledgers = [:]   // stroke ids changed: rebuilt from the new pages
        deletedPages = []
        pages = edit.pages
        pageIndex = pages.firstIndex { $0.id == shown } ?? 0
        pageSize = edit.pageSize
        committedPageSize = edit.pageSize   // the switch's own setMeta carries it
        pendingPageOps += edit.ops
        canvasGeneration &+= 1
        for page in pages { inkRevisions[page.id, default: 0] &+= 1 }
        await flush()
    }

    /// Whether anything is waiting to be written (page ops, ink, page size).
    var hasPendingChanges: Bool {
        !pendingPageOps.isEmpty || pageSize != committedPageSize
            || pages.contains { page in ledgers[page.id].map { !$0.pendingOps(page: page.id, live: $0.live).isEmpty } ?? false }
    }

    /// `pages` with each page's live strokes (saved or not).
    private func livePages() -> [Page] {
        pages.map { page in
            var p = page
            if let l = ledgers[page.id] { p.strokes = l.live }
            return p
        }
    }

    /// Takes `edit`'s pages, drops ledgers of pages that are gone and queues
    /// its ops; shows `show` (else the same page, else the nearest).
    private func apply(_ edit: PageEdit, show: UUID?) {
        let keep = Set(edit.pages.map(\.id))
        ledgers = ledgers.filter { keep.contains($0.key) }
        pages = edit.pages
        if let show, let i = pages.firstIndex(where: { $0.id == show }) {
            pageIndex = i
        } else {
            pageIndex = min(pageIndex, max(pages.count - 1, 0))
        }
        pendingPageOps += edit.ops
    }

    /// Writes what is pending now rather than after the pause.
    private func saveNow() {
        Task { await flush() }
    }

    // MARK: - Changes from the canvas

    /// The canvas's drawing for `pageID` changed (stroke drawn, erased,
    /// moved, undone, redone). Updates ids now; saves after the pause.
    @discardableResult
    func drawingDidChange(pageID: UUID, items: [StrokeLedger.Item], inkMaxY: Double?) -> StrokeLedger.Change {
        guard !isReadOnly, !isShutDown else { return .init() }
        var l = ledger(pageID)
        let change = l.update(items)
        ledgers[pageID] = l
        if !change.isEmpty { inkRevisions[pageID, default: 0] &+= 1 }
        if let inkMaxY { growPage(toFit: inkMaxY) }
        if !change.isEmpty || pageSize != committedPageSize { scheduleSave() }
        if !change.isEmpty {
            touchedPages.insert(pageID)
            scheduleRecognition()
        }
        return change
    }

    /// Convenience for the canvas: a whole PencilKit drawing.
    @discardableResult
    func drawingDidChange(pageID: UUID, drawing: PKDrawing, tool: PKTool?) -> StrokeLedger.Change {
        let bounds = drawing.bounds
        return drawingDidChange(pageID: pageID, items: StrokeLedger.items(for: drawing, tool: tool),
                                inkMaxY: bounds.isNull ? nil : Double(bounds.maxY))
    }

    /// Grows an infinite page so ink stays at least `growMargin` above its
    /// bottom. Finite pages never change size; pages never shrink.
    func growPage(toFit inkMaxY: Double) {
        guard pageSize.infinite, inkMaxY.isFinite, inkMaxY > pageSize.height - Self.growMargin else { return }
        pageSize.height = (inkMaxY + Self.growStep).rounded(.up)
    }

    // MARK: - Saving

    private func scheduleSave() {
        timer?.cancel()
        let debounce = self.debounce
        timer = Task { [weak self] in
            do { try await Task.sleep(for: debounce) } catch { return }
            await self?.flush()
        }
    }

    /// Writes everything pending as one delta now (no-op when nothing is).
    /// Saves are serialized; a failure is kept in `saveError` and the
    /// changes stay pending for the next save.
    func flush() async {
        timer?.cancel()
        timer = nil
        let previous = chain
        let task = Task { [weak self] in
            await previous?.value
            await self?.writePending()
        }
        chain = task
        await task.value
    }

    /// Saves what is pending and stops autosaving; afterwards the editor takes
    /// no more changes and writes nothing (`isShutDown`).
    func close() async {
        isClosed = true
        recognitionTimer?.cancel()
        // A recognition write already started finishes; none starts after this.
        _ = await recognitionWrite?.result
        await flush()
        isShutDown = true
    }

    private func writePending() async {
        guard let writer, !isShutDown else { return }
        let pageOps = pendingPageOps
        var ops = pageOps
        // Ledgers commit before the write (see `StrokeLedger.beginSave`) and
        // roll back if it fails.
        var saves: [(UUID, StrokeLedger.Save)] = []
        for page in pages {
            guard var l = ledgers[page.id], let save = l.beginSave(page: page.id) else { continue }
            ledgers[page.id] = l
            ops += save.ops
            saves.append((page.id, save))
        }
        let size = pageSize
        if size != committedPageSize { ops.append(.setMeta(.pageSize(size))) }
        guard !ops.isEmpty else { return }
        do {
            try await writer.write(ops)
        } catch {
            for (id, save) in saves { ledgers[id]?.saveFailed(save) }
            saveError = "Could not save: \(error)"
            return
        }
        pendingPageOps.removeFirst(pageOps.count)
        committedPageSize = size
        deltasWritten += 1
        saveError = nil
    }
}

// MARK: - Handwriting recognition

extension NoteEditor {
    /// The page's strokes as of now: the ledger's once the page was shown or
    /// edited, else the stored ones (no ledger is built just to read ids).
    private func currentStrokes(of page: Page) -> [Stroke] {
        ledgers[page.id]?.live ?? page.strokes
    }

    /// Recognises the pages that need it after `recognitionDelay` without
    /// further stroke changes (and once when the note opens).
    func scheduleRecognition() {
        guard recognizer != nil, !isReadOnly, !isClosed else { return }
        recognitionTimer?.cancel()
        let delay = recognitionDelay
        recognitionTimer = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.recognizePending()
        }
    }

    /// Saves pending strokes, then reads every page whose recognition is
    /// missing or stale (`RecognitionPolicy`) and writes what it read as one
    /// delta of `setPageRecognition` ops (one per page) for the whole pass.
    /// Reading runs off the main actor; a page whose strokes changed
    /// meanwhile is dropped (the change schedules another pass). The pass
    /// stops, writing nothing, once the editor closes or recognition is
    /// switched off (`recognizer` set to nil).
    func recognizePending() async {
        guard recognizer != nil, !isReadOnly else { return }
        if recognitionBusy { recognitionAgain = true; return }
        recognitionBusy = true
        defer { recognitionBusy = false }
        repeat {
            recognitionAgain = false
            await recognizeOnce()
        } while recognitionAgain && !isClosed
    }

    /// Whether a pass may go on: the editor is open and recognition still on.
    private var recognitionWanted: Bool { !isClosed && recognizer != nil }

    private func recognizeOnce() async {
        guard let recognizer, let writer, !isClosed else { return }
        await flush()
        guard saveError == nil, recognitionWanted else { return }   // never recognise strokes that are not on disk
        var read: [(pageID: UUID, digest: String, recognition: Recognition?)] = []
        var failed = false
        for page in pages {
            guard recognitionWanted else { return }
            let strokes = currentStrokes(of: page)
            let digest = RecognitionBasis.digest(of: strokes.map(\.id))
            guard RecognitionPolicy.needsRecognition(page.recognition, strokeIDs: strokes.map(\.id),
                                                     touched: touchedPages.contains(page.id)) else { continue }
            var result: Recognition?
            if !strokes.isEmpty {
                do {
                    var r = try await recognizer.recognize(strokes: strokes)
                    r.basis = digest
                    result = r
                } catch {
                    recognitionError = "Could not read handwriting: \(error)"
                    failed = true
                    continue
                }
            }
            read.append((page.id, digest, result))
        }
        guard recognitionWanted else { return }
        // Only pages whose strokes are still the ones that were read.
        let current = read.filter { r in
            guard let page = pages.first(where: { $0.id == r.pageID }) else { return false }
            return RecognitionBasis.digest(of: currentStrokes(of: page).map(\.id)) == r.digest
        }
        guard !current.isEmpty else { return }
        let ops = current.map { Op.setPageRecognition(pageId: $0.pageID, recognition: $0.recognition) }
        let write = Task { _ = try await writer.write(ops) }
        recognitionWrite = write
        do {
            try await write.value
        } catch {
            recognitionError = "Could not save recognised text: \(error)"
            return
        }
        for r in current {
            if let index = pages.firstIndex(where: { $0.id == r.pageID }) { pages[index].recognition = r.recognition }
            touchedPages.remove(r.pageID)
        }
        recognitionsWritten += current.count
        if !failed { recognitionError = nil }
        onRecognized?(noteID)
    }
}
