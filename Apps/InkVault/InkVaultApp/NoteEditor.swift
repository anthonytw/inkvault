import Foundation
import InkVault
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

    @ObservationIgnored private var ledgers: [UUID: StrokeLedger] = [:]
    @ObservationIgnored private var committedPageSize: PageSize
    /// Page additions and paper changes not yet written (written before any stroke ops).
    @ObservationIgnored private var pendingPageOps: [Op] = []
    @ObservationIgnored private let writer: NoteWriter?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var chain: Task<Void, Never>?

    /// Ink closer than this to the bottom of an infinite page grows it.
    static let growMargin = 200.0
    /// How far below the ink an infinite page grows to.
    static let growStep = 400.0
    /// Default pause before an autosave.
    static let defaultDebounce = Duration.milliseconds(1500)

    init(noteID: UUID, state: NoteState, writer: NoteWriter?, readOnlyReason: String?,
         debounce: Duration = NoteEditor.defaultDebounce) {
        self.noteID = noteID
        self.pages = state.pages
        self.meta = state.meta
        self.pageSize = state.meta.pageSize
        self.committedPageSize = state.meta.pageSize
        self.writer = writer
        self.readOnlyReason = writer == nil ? (readOnlyReason ?? "This note is read-only.") : readOnlyReason
        self.debounce = debounce
    }

    /// Loads and reconstructs a note off the main actor. A note with
    /// unreadable revisions, or in Recently Deleted, opens read-only.
    /// `coordinated` (a vault in iCloud Drive): the note is read, and its
    /// deltas written, under `NSFileCoordinator` (`CloudVault`). `verify`
    /// runs inside that read before and after the note is loaded and throws
    /// to refuse a note whose files are not all local (`CloudVault.requireLocal`).
    static func open(vault: Vault, noteID: UUID, clock: DeviceClock,
                     debounce: Duration = NoteEditor.defaultDebounce,
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
        return NoteEditor(noteID: noteID, state: state, writer: writer, readOnlyReason: reason, debounce: debounce)
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
        guard !isReadOnly, let page = currentPage else { return }
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
        guard !isReadOnly else { return }
        let page = Page(order: PageOrder.between(pages.last?.order, nil))
        pages.append(page)
        pendingPageOps.append(.addPage(page))
        pageIndex = pages.count - 1
        scheduleSave()
    }

    // MARK: - Changes from the canvas

    /// The canvas's drawing for `pageID` changed (stroke drawn, erased,
    /// moved, undone, redone). Updates ids now; saves after the pause.
    @discardableResult
    func drawingDidChange(pageID: UUID, items: [StrokeLedger.Item], inkMaxY: Double?) -> StrokeLedger.Change {
        guard !isReadOnly else { return .init() }
        var l = ledger(pageID)
        let change = l.update(items)
        ledgers[pageID] = l
        if let inkMaxY { growPage(toFit: inkMaxY) }
        if !change.isEmpty || pageSize != committedPageSize { scheduleSave() }
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

    /// Saves what is pending and stops autosaving.
    func close() async {
        await flush()
    }

    private func writePending() async {
        guard let writer else { return }
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
