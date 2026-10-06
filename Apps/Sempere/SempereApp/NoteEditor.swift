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
    private(set) var readOnlyReason: String?
    /// True while the note is shown from the drawing cache and its revisions
    /// are still being read (`open(..., cache:)`): pages have no strokes yet
    /// and nothing can be edited.
    private(set) var isPreparing = false
    /// True when the editor opened from the drawing cache (`open(..., cache:)`).
    private(set) var openedFromCache = false
    /// Bumped when the canvas must reload the shown page's drawing although
    /// the page stayed the same (the read note differed from the cache).
    private(set) var canvasGeneration = 0
    /// The last autosave failure; cleared by the next successful save.
    private(set) var saveError: String?
    /// Deltas written by this editor (for tests and the UI).
    private(set) var deltasWritten = 0

    var isReadOnly: Bool { readOnlyReason != nil || isPreparing }
    var currentPage: Page? { pages.indices.contains(pageIndex) ? pages[pageIndex] : nil }

    @ObservationIgnored private var ledgers: [UUID: StrokeLedger] = [:]
    /// The drawing each page's canvas showed last, one-to-one with its
    /// ledger's entries: shown again as it is (no conversion) while the
    /// ledger exists.
    @ObservationIgnored private var canvasDrawings: [UUID: PKDrawing] = [:]
    /// Pages whose drawing is being prepared off the main actor.
    @ObservationIgnored private var preparing: [UUID: Task<PreparedDrawing?, Never>] = [:]
    /// Pages whose strokes changed since the note was read.
    @ObservationIgnored private(set) var dirtyPages: Set<UUID> = []
    /// Where page drawings are cached between opens (nil: no cache).
    @ObservationIgnored private(set) var drawingCache: DrawingCache?
    /// The note version the editor was read from (`DrawingCache.Key`); nil
    /// when it cannot be cached (unreadable revisions).
    @ObservationIgnored private(set) var cacheKey: DrawingCache.Key?
    /// Revisions this editor wrote, by file name.
    @ObservationIgnored private var writtenNames: [String] = []
    /// The read that completes an editor opened from the cache.
    @ObservationIgnored private var fullLoad: Task<Void, Never>?
    /// `note.firstRender`: from the open until the canvas shows ink (`didShowInk`).
    @ObservationIgnored var openInterval: Perf.Interval?
    @ObservationIgnored private var committedPageSize: PageSize
    /// Page additions and paper changes not yet written (written before any stroke ops).
    @ObservationIgnored private var pendingPageOps: [Op] = []
    @ObservationIgnored private var writer: NoteWriter?
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

    /// An editor showing a note from the drawing cache's `layout` while
    /// its revisions are read (`isPreparing`).
    private init(noteID: UUID, layout: DrawingCache.Layout, debounce: Duration) {
        self.noteID = noteID
        self.pages = layout.state.pages
        self.meta = layout.state.meta
        self.pageSize = layout.state.meta.pageSize
        self.committedPageSize = layout.state.meta.pageSize
        self.writer = nil
        self.readOnlyReason = nil
        self.debounce = debounce
        self.isPreparing = true
        self.openedFromCache = true
    }

    /// What reading a note yields, off the main actor.
    private struct Loaded: Sendable {
        var state: NoteState
        var failures: Int
        var nextSeq: Int
        var readings: [HLC]
        /// Every revision file name read or failed, sorted.
        var names: [String]
    }

    /// Loads and reconstructs a note off the main actor. A note with
    /// unreadable revisions, or in Recently Deleted, opens read-only.
    /// `coordinated` (a vault in iCloud Drive): the note is read, and its
    /// deltas written, under `NSFileCoordinator` (`CloudVault`). `verify`
    /// runs inside that read before and after the note is loaded and throws
    /// to refuse a note whose files are not all local (`CloudVault.requireLocal`).
    ///
    /// With a `cache` and the note's `listedNames` (its revision file names
    /// as just listed), a note whose layout is cached opens at once from the
    /// cache (`isPreparing`) and is read in the background; its pages'
    /// drawings come from the cache too (`prepareDrawing`) and are checked
    /// against what is read before anything can be drawn.
    static func open(vault: Vault, noteID: UUID, clock: DeviceClock,
                     debounce: Duration = NoteEditor.defaultDebounce,
                     coordinated: Bool = false,
                     verify: (@Sendable () throws -> Void)? = nil,
                     cache: DrawingCache? = nil, listedNames: [String]? = nil,
                     beforeFinishing: (@Sendable () async -> Void)? = nil) async throws -> NoteEditor {
        if let cache, let listedNames, !listedNames.isEmpty {
            let key = DrawingCache.Key(note: noteID, revisions: listedNames)
            let layout = await Task.detached(priority: .userInitiated) {
                Perf.measure(.noteCache, "layout \(Perf.short(noteID))") { cache.layout(key) }
            }.value
            if let layout {
                let editor = NoteEditor(noteID: noteID, layout: layout, debounce: debounce)
                editor.drawingCache = cache
                editor.cacheKey = key
                editor.fullLoad = Task { [weak editor] in
                    do {
                        let loaded = try await read(vault: vault, noteID: noteID, device: clock.device,
                                                    coordinated: coordinated, verify: verify)
                        await clock.observe(loaded.readings)
                        await beforeFinishing?()
                        await editor?.finishLoading(loaded, vault: vault, clock: clock, coordinated: coordinated)
                    } catch {
                        editor?.failLoading(error)
                    }
                }
                return editor
            }
        }
        let loaded = try await read(vault: vault, noteID: noteID, device: clock.device, coordinated: coordinated,
                                    verify: verify)
        await clock.observe(loaded.readings)
        let reason = readOnlyReason(loaded)
        let writer = reason == nil ? NoteWriter(vault: vault, noteID: noteID, clock: clock, nextSeq: loaded.nextSeq,
                                                coordinated: coordinated) : nil
        let editor = NoteEditor(noteID: noteID, state: loaded.state, writer: writer, readOnlyReason: reason,
                                debounce: debounce)
        if let cache, loaded.failures == 0 {
            let key = DrawingCache.Key(note: noteID, revisions: loaded.names)
            editor.drawingCache = cache
            editor.cacheKey = key
            let layout = DrawingCache.Layout(loaded.state)
            Task.detached(priority: .utility) { cache.store(layout, for: key) }
        }
        return editor
    }

    private static func read(vault: Vault, noteID: UUID, device: DeviceID, coordinated: Bool,
                             verify: (@Sendable () throws -> Void)?) async throws -> Loaded {
        try await Task.detached(priority: .userInitiated) {
            let loaded = try Perf.measure(.noteRead, "\(Perf.short(noteID))") {
                try CloudVault.coordinatedRead(coordinated ? vault.url : nil) {
                    try verify?()
                    let loaded = try vault.loadNote(noteID)
                    try verify?()
                    return loaded
                }
            }
            let state = try Perf.measure(.noteReconstruct, "\(Perf.short(noteID)) revisions=\(loaded.revisions.count)") {
                try NoteReducer.reconstruct(loaded.revisions)
            }
            let names = (loaded.revisions.map(\.name.filename) + loaded.failures.keys.map(\.filename)).sorted()
            return Loaded(state: state, failures: loaded.failures.count,
                          nextSeq: Vault.nextSeq(from: loaded.revisions, device: device),
                          readings: loaded.revisions.map(\.hlc), names: names)
        }.value
    }

    private static func readOnlyReason(_ loaded: Loaded) -> String? {
        if loaded.failures > 0 {
            return "\(loaded.failures) revision(s) of this note could not be read, so it opens read-only."
        } else if loaded.state.deleted {
            return "This note is in Recently Deleted."
        }
        return nil
    }

    /// The background read of an editor opened from the cache finished:
    /// the real pages replace the layout's, every cached drawing shown so far
    /// is checked against them (kept, with its ledger, when it matches;
    /// reloaded from the strokes when not), and the note becomes editable.
    private func finishLoading(_ loaded: Loaded, vault: Vault, clock: DeviceClock, coordinated: Bool) async {
        guard isPreparing else { return }
        let sameVersion = loaded.failures == 0 && cacheKey?.revisions == loaded.names
        let shownPages = canvasDrawings.mapValues(DrawingBox.init)
        let pagesByID = Dictionary(loaded.state.pages.map { ($0.id, $0.strokes) }, uniquingKeysWith: { a, _ in a })
        // Checking and fingerprinting 15 000 strokes is a few milliseconds: off the main actor anyway.
        let checked: [UUID: PreparedDrawing] = sameVersion ? await Task.detached(priority: .userInitiated) {
            var ok: [UUID: PreparedDrawing] = [:]
            for (id, box) in shownPages {
                guard let strokes = pagesByID[id], DrawingPreparation.matches(box.drawing, strokes) else { continue }
                ok[id] = PreparedDrawing(drawing: box.drawing)
            }
            return ok
        }.value : [:]
        guard isPreparing else { return }
        let shown = currentPage?.id
        pages = loaded.state.pages
        meta = loaded.state.meta
        pageSize = loaded.state.meta.pageSize
        committedPageSize = loaded.state.meta.pageSize
        pageIndex = shown.flatMap { id in pages.firstIndex { $0.id == id } } ?? min(pageIndex, max(pages.count - 1, 0))
        readOnlyReason = Self.readOnlyReason(loaded)
        writer = readOnlyReason == nil ? NoteWriter(vault: vault, noteID: noteID, clock: clock, nextSeq: loaded.nextSeq,
                                                    coordinated: coordinated) : nil
        cacheKey = loaded.failures == 0 ? DrawingCache.Key(note: noteID, revisions: loaded.names) : nil
        canvasDrawings = [:]
        ledgers = [:]
        for page in pages {
            guard let ready = checked[page.id], let ledger = StrokeLedger(stored: page.strokes, infos: ready.infos) else { continue }
            ledgers[page.id] = ledger
            canvasDrawings[page.id] = ready.drawing
        }
        if let shown, shownPages[shown] != nil, checked[shown] == nil {
            // The cached drawing on screen was not this note's: show the real one.
            Perf.event(.noteCache, "mismatch \(Perf.short(noteID))")
            canvasGeneration &+= 1
        }
        isPreparing = false
    }

    /// The background read of an editor opened from the cache failed: the
    /// cached ink stays on screen, read-only, with the reason.
    private func failLoading(_ error: any Error) {
        guard isPreparing else { return }
        readOnlyReason = "This note could not be read: \(error)"
        isPreparing = false
    }

    /// Waits until a note opened from the cache has been read (at once otherwise).
    func loaded() async {
        await fullLoad?.value
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
    /// each. Re-keys the page's ledger to match. Converts on the calling
    /// (main) actor; the canvas uses `readyDrawing` / `prepareDrawing`.
    func drawing(for pageID: UUID) -> PKDrawing {
        if isPreparing { return canvasDrawings[pageID] ?? PKDrawing() }   // no ledger before the strokes are read
        var l = ledger(pageID)
        l.rebase(info: CanvasStrokeInfo.init(stored:))
        ledgers[pageID] = l
        let drawing = l.drawing
        canvasDrawings[pageID] = drawing
        return drawing
    }

    /// The drawing the page's canvas can show right away, without converting
    /// anything: what it showed last (or what the cache gave while the note
    /// is being read). Nil when it must be prepared (`prepareDrawing`).
    func readyDrawing(for pageID: UUID) -> PKDrawing? {
        guard let drawing = canvasDrawings[pageID], isPreparing || ledgers[pageID] != nil else { return nil }
        return drawing
    }

    /// Prepares the page's drawing off the main actor: from the drawing
    /// cache when it holds this version of the page (checked against the
    /// strokes), else by converting the strokes, those reaching into
    /// `visible` (page points) first, handed to `partial` as soon as they are
    /// converted. A converted page is stored in the cache. The page's ledger
    /// is set up from the result, so nothing is converted again on the main
    /// actor. Nil when the page went away or changed meanwhile.
    func prepareDrawing(for pageID: UUID, visible: CGRect? = nil,
                        partial: (@MainActor @Sendable (PKDrawing) -> Void)? = nil) async -> PKDrawing? {
        if let ready = readyDrawing(for: pageID) { return ready }
        if let task = preparing[pageID] { return await task.value?.drawing }
        if isPreparing {
            // Opened from the cache and still being read: this page from the cache if it is there.
            if let cache = drawingCache, let key = cacheKey {
                let noteID = self.noteID
                let cached = await Task.detached(priority: .userInitiated) { () -> DrawingBox? in
                    let interval = Perf.begin(.noteCache)
                    let data = cache.drawing(key, page: pageID)
                    let drawing = data.flatMap { try? PKDrawing(data: $0) }
                    Perf.end(interval, "\(drawing == nil ? "miss" : "hit") page \(Perf.short(noteID)) bytes=\(data?.count ?? 0)")
                    // Fingerprinted once the strokes are read (`finishLoading`), not now.
                    return drawing.map(DrawingBox.init)
                }.value
                if isPreparing, let cached {
                    canvasDrawings[pageID] = cached.drawing
                    return cached.drawing
                }
            }
            await fullLoad?.value
            if let ready = readyDrawing(for: pageID) { return ready }
        }
        guard !isPreparing, pages.contains(where: { $0.id == pageID }) else { return nil }
        let strokes = ledgers[pageID]?.live ?? pages.first { $0.id == pageID }?.strokes ?? []
        let ids = strokes.map(\.id)
        let cache = dirtyPages.contains(pageID) ? nil : drawingCache
        let key = cacheKey
        let noteID = self.noteID
        let task = Task.detached(priority: .userInitiated) { () -> PreparedDrawing? in
            if let cache, let key {
                let interval = Perf.begin(.noteCache)
                let hit = cache.drawing(key, page: pageID).flatMap { DrawingPreparation.fromCache($0, strokes: strokes) }
                Perf.end(interval, "\(hit == nil ? "miss" : "hit") page \(Perf.short(noteID)) strokes=\(strokes.count)")
                if let hit { return hit }
            }
            let prepared = Perf.measure(.noteConvert, "\(Perf.short(noteID)) strokes=\(strokes.count)") {
                DrawingPreparation.convert(strokes, visible: visible, visibleFirst: partial.map { show in
                    { drawing in
                        let box = DrawingBox(drawing)
                        Task { @MainActor in show(box.drawing) }
                    }
                })
            }
            if let cache, let key {
                // Stored after the page is shown, not before.
                let box = DrawingBox(prepared.drawing)
                Task.detached(priority: .utility) {
                    Perf.measure(.cacheWrite, "page \(Perf.short(noteID))") {
                        cache.store(drawing: box.drawing.dataRepresentation(), for: key, page: pageID)
                    }
                }
            }
            return prepared
        }
        preparing[pageID] = task
        let prepared = await task.value
        preparing[pageID] = nil
        guard let prepared, !isPreparing,
              (ledgers[pageID]?.live ?? pages.first { $0.id == pageID }?.strokes ?? []).map(\.id) == ids else { return nil }
        if var l = ledgers[pageID] {
            guard l.rebase(infos: prepared.infos) else { return nil }
            ledgers[pageID] = l
        } else {
            guard let l = StrokeLedger(stored: strokes, infos: prepared.infos) else { return nil }
            ledgers[pageID] = l
        }
        canvasDrawings[pageID] = prepared.drawing
        return prepared.drawing
    }

    /// The canvas shows ink for the first time since the note was opened:
    /// ends the `note.firstRender` interval.
    func didShowInk(partial: Bool) {
        guard let interval = openInterval else { return }
        openInterval = nil
        Perf.end(interval, "\(Perf.short(noteID)) \(partial ? "visible strokes" : "page") cached=\(isPreparing)")
    }

    /// Live strokes of a page (saved or not). Empty while the note is being
    /// read (`isPreparing`).
    func liveStrokes(of pageID: UUID) -> [Stroke] { isPreparing ? [] : ledger(pageID).live }

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
        if !change.isEmpty { dirtyPages.insert(pageID) }
        if let inkMaxY { growPage(toFit: inkMaxY) }
        if !change.isEmpty || pageSize != committedPageSize { scheduleSave() }
        return change
    }

    /// Convenience for the canvas: a whole PencilKit drawing.
    @discardableResult
    func drawingDidChange(pageID: UUID, drawing: PKDrawing, tool: PKTool?) -> StrokeLedger.Change {
        guard !isReadOnly else { return .init() }
        let bounds = drawing.bounds
        let change = drawingDidChange(pageID: pageID, items: StrokeLedger.items(for: drawing, tool: tool),
                                      inkMaxY: bounds.isNull ? nil : Double(bounds.maxY))
        canvasDrawings[pageID] = drawing   // the ledger's entries now fingerprint exactly these strokes
        return change
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

    /// Saves what is pending, stops autosaving, and stores the pages'
    /// drawings in the drawing cache for the next open (`storeForNextOpen`).
    func close() async {
        fullLoad?.cancel()
        await flush()
        storeForNextOpen()
    }

    /// Stores this version of the note (as read, plus the deltas this editor
    /// wrote) in the drawing cache: its layout, the drawings of pages shown
    /// unchanged as they are, and those of changed pages converted from
    /// their live strokes, in the background. Nothing when the note could
    /// not be cached, a save failed or something is still unsaved; the
    /// version it replaces is dropped from the cache.
    func storeForNextOpen() {
        guard let cache = drawingCache, let base = cacheKey, !isPreparing, readOnlyReason == nil, saveError == nil,
              pendingPageOps.isEmpty, pageSize == committedPageSize,
              !pages.contains(where: { page in ledgers[page.id].map { !$0.pendingOps(page: page.id, live: $0.live).isEmpty } ?? false })
        else { return }
        let key = DrawingCache.Key(note: noteID, revisions: base.revisions + writtenNames)
        guard key != base else { return }   // nothing written: the cache already has this version
        var state = NoteState(deleted: false, meta: meta, pages: pages)
        state.meta.pageSize = pageSize
        var clean: [UUID: DrawingBox] = [:]
        var changed: [UUID: [Stroke]] = [:]
        for i in state.pages.indices {
            let id = state.pages[i].id
            if let l = ledgers[id] { state.pages[i].strokes = l.live }
            if dirtyPages.contains(id) {
                changed[id] = state.pages[i].strokes
            } else if let drawing = canvasDrawings[id], ledgers[id] != nil {
                clean[id] = DrawingBox(drawing)
            }
        }
        let layout = DrawingCache.Layout(state)
        let old = base, pageIDs = state.pages.map(\.id), noteID = self.noteID
        Task.detached(priority: .utility) {
            Perf.measure(.cacheWrite, "close \(Perf.short(noteID)) changed=\(changed.count) clean=\(clean.count)") {
                cache.store(layout, for: key)
                for (id, box) in clean { cache.store(drawing: box.drawing.dataRepresentation(), for: key, page: id) }
                for (id, strokes) in changed {
                    cache.store(drawing: DrawingPreparation.convert(strokes).drawing.dataRepresentation(), for: key, page: id)
                }
                cache.remove(old, pages: pageIDs)
            }
        }
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
            let name = try await writer.write(ops)
            writtenNames.append(name.filename)
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
