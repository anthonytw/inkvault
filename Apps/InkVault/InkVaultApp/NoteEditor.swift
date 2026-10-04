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
    /// Page additions not yet written (written before any stroke ops).
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
    static func open(vault: Vault, noteID: UUID, clock: DeviceClock,
                     debounce: Duration = NoteEditor.defaultDebounce) async throws -> NoteEditor {
        let device = clock.device
        let (state, failures, nextSeq, readings) = try await Task.detached(priority: .userInitiated) {
            let loaded = try vault.loadNote(noteID)
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
        let writer = reason == nil ? NoteWriter(vault: vault, noteID: noteID, clock: clock, nextSeq: nextSeq) : nil
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
