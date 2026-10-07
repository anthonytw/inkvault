import SempereRender
import Sempere
import PencilKit
import SwiftUI
import UIKit

/// One page of a note on a `PKCanvasView`, with the system tool picker and
/// the paper underneath. Fits the page width; pinch zooms up to 4x.
struct PageCanvasView: UIViewRepresentable {
    let editor: NoteEditor
    let pageID: UUID
    let paper: Paper
    let pageSize: PageSize
    /// The tool palette's shown/compact state (`ToolPalette`).
    var paletteVisible = true
    var paletteCompact = false
    /// Reading on an iPhone: the canvas only pans and zooms, the palette is hidden
    /// (`PhoneReading`).
    var drawingSuspended = false
    /// `NoteEditor.canvasGeneration`: a change reloads the drawing even when
    /// the page id stays the same.
    var generation = 0
    /// Where the item layer reads attachments (`AppModel.attachmentCache`).
    var itemSource = ItemLayerSource()
    /// Copy and paste of items (`AppModel.itemClipboard`).
    var itemCommands = ItemCommands()
    /// Selection mode: items are selected, moved and resized; nothing draws.
    var selectingItems = false
    /// Called when selection mode ends from the canvas (a tool was picked).
    var onSelectingItemsEnded: () -> Void = {}
    /// Images and PDFs dropped on the page (`CanvasDrop`), with the page point they were dropped at.
    var onDrop: ((_ providers: [NSItemProvider], _ pageID: UUID, _ point: CGPoint) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PageCanvasHost {
        let host = PageCanvasHost()
        host.canvas.delegate = context.coordinator
        return host
    }

    func updateUIView(_ host: PageCanvasHost, context: Context) {
        let c = context.coordinator
        c.editor = editor
        c.host = host
        editor.canvasTarget = host
        if c.pageID != pageID || c.editorID != ObjectIdentifier(editor) || c.generation != generation {
            let samePage = c.pageID == pageID && c.editorID == ObjectIdentifier(editor)
            c.pageID = pageID
            c.editorID = ObjectIdentifier(editor)
            c.generation = generation
            c.load(editor: editor, pageID: pageID, host: host, keepScroll: samePage)
        }
        host.isReadOnly = editor.isReadOnly
        let index = editor.pages.firstIndex { $0.id == pageID }
        let isLast = index == editor.pages.count - 1
        let footer = PhoneReading.footer(infinite: pageSize.infinite, isLast: isLast, readOnly: editor.isReadOnly,
                                         drawingSuspended: drawingSuspended)
        host.footer = footer
        host.footerAction = { [weak editor] in
            guard let editor else { return }
            switch footer {
            case .addPage: editor.addPage()
            case .nextPage: if let index { editor.selectPage(index + 1) }
            case .none: break
            }
        }
        host.paletteCompact = paletteCompact
        host.paletteVisible = paletteVisible
        host.drawingSuspended = drawingSuspended
        host.apply(paper: paper, pageSize: pageSize)
        host.itemLayer.show(editor.items(on: pageID), note: editor.noteID, paper: paper, source: itemSource)
        host.itemSelection.reset(editor: editor, pageID: pageID, undoManager: host.canvas.undoManager)
        host.itemSelection.commands = itemCommands
        host.onItemSelectionEnded = onSelectingItemsEnded
        if let onDrop {
            host.dropHandler = { providers, point in onDrop(providers, pageID, point) }
        } else {
            host.dropHandler = nil
        }
        host.itemSelectionActive = selectingItems && !editor.isReadOnly && !drawingSuspended
        host.itemSelection.refresh()
    }

    static func dismantleUIView(_ host: PageCanvasHost, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        coordinator.host = nil
        Task { await coordinator.editor?.flush() }
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var editor: NoteEditor?
        weak var host: PageCanvasHost?
        var pageID: UUID?
        var editorID: ObjectIdentifier?
        var generation: Int?
        /// True while the canvas's drawing is being replaced: its changes are not the user's.
        var isLoading = false
        /// The page's drawing being prepared off the main actor.
        var loadTask: Task<Void, Never>?
        /// Bumped per load, so a late partial drawing never lands over a newer one.
        private var loadToken = 0

        /// Shows the page's ink: at once when the editor has its drawing
        /// ready, else prepared off the main actor (from the drawing cache, or
        /// converted with the strokes on screen first), with drawing disabled
        /// until the whole page is in.
        func load(editor: NoteEditor, pageID: UUID, host: PageCanvasHost, keepScroll: Bool) {
            loadTask?.cancel()
            loadToken &+= 1
            let token = loadToken
            isLoading = true
            host.cancelErasing()   // an erase in progress belongs to the old page
            if !keepScroll { host.scrollToTop() }
            if let ready = editor.readyDrawing(for: pageID) {
                show(ready, host: host, editor: editor, partial: false)
                return
            }
            host.canvas.drawing = PKDrawing()
            host.canvas.undoManager?.removeAllActions()   // the previous page's undo must not run on this one
            host.isPreparing = true
            let visible = host.visiblePageRect
            loadTask = Task { @MainActor [weak self, weak host, weak editor] in
                guard let editor else { return }
                let drawing = await editor.prepareDrawing(for: pageID, visible: visible) { [weak self, weak host] part in
                    guard let self, let host, self.loadToken == token, self.isLoading else { return }
                    host.canvas.drawing = part
                    host.inkDidChange()
                    editor.didShowInk(partial: true)
                }
                guard let self, let host, self.loadToken == token, !Task.isCancelled else { return }
                // Nil: the page changed while it was prepared; the editor's own conversion is current.
                self.show(drawing ?? editor.drawing(for: pageID), host: host, editor: editor, partial: false)
            }
        }

        private func show(_ drawing: PKDrawing, host: PageCanvasHost, editor: NoteEditor, partial: Bool) {
            isLoading = true
            host.canvas.drawing = drawing
            host.canvas.undoManager?.removeAllActions()   // undo must not cross pages or notes
            isLoading = false
            host.isPreparing = false
            host.inkDidChange()
            editor.didShowInk(partial: partial)
            #if DEBUG
            if DebugLaunch.isActive {
                NSLog("SempereDebug loaded strokes=%d bounds=%@", drawing.strokes.count, NSCoder.string(for: drawing.bounds))
            }
            #endif
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if let type = EraserPreference.eraserType(of: canvasView.tool) { EraserPreference.save(type) }
            guard !isLoading, let editor, let pageID else { return }
            editor.drawingDidChange(pageID: pageID, drawing: canvasView.drawing, tool: canvasView.tool)
            host?.inkDidChange()
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            host?.zoomChanged()
        }
    }
}

/// UIKit side of `PageCanvasView`.
final class PageCanvasHost: UIView, PKToolPickerObserver, UIPointerInteractionDelegate, UIDropInteractionDelegate {
    let canvas = PKCanvasView()
    private let paperView = PaperView()
    /// The page's placed items, between the paper and the ink.
    let itemLayer = ItemLayerView()
    /// Selecting, moving and resizing items (selection mode).
    let itemSelection = ItemSelectionController()
    /// Called when picking a tool ends selection mode.
    var onItemSelectionEnded: (() -> Void)?

    /// Selection mode: PencilKit's drawing and the object eraser are off,
    /// touches select and move items (`ItemSelectionController`).
    var itemSelectionActive = false {
        didSet {
            guard itemSelectionActive != oldValue else { return }
            itemSelection.setActive(itemSelectionActive)
            updateEraser()
        }
    }
    /// Starts with the last-used eraser mode, the object eraser by default.
    private(set) var toolPicker = ToolPalette.makePicker(compact: ToolPalette.isCompact())
    private var pageSize = PageSize.letter
    private var paper = Paper.blank
    private var fittedWidth: CGFloat = 0
    /// The sized object eraser that replaces PencilKit's (`ObjectEraser.swift`).
    private let objectEraser = ObjectEraserController()
    /// Bottom of the ink on the page (page points), nil without ink.
    private(set) var inkMaxY: Double?
    /// The Add Page / Next Page button below a finite page.
    let footerButton = UIButton(configuration: .bordered())
    /// The pointer's shape over the canvas (Mac, `pointerInteraction(_:styleFor:)`).
    private var cursorInteraction: UIPointerInteraction?
    /// Takes images and PDFs dropped on the page; nil: drops are refused.
    var dropHandler: ((_ providers: [NSItemProvider], _ point: CGPoint) -> Void)?

    /// What the button below a finite page does (`PageExtent`).
    var footer = PageExtent.Footer.none {
        didSet { if footer != oldValue { updateFooter() } }
    }
    var footerAction: (() -> Void)?

    /// The palette is shown (the toolbar button) unless the note is read-only.
    var paletteVisible = true {
        didSet { if paletteVisible != oldValue { updateToolPicker() } }
    }

    /// The palette is the short one: pen, marker, eraser, lasso.
    var paletteCompact = ToolPalette.isCompact() {
        didSet { if paletteCompact != oldValue { rebuildToolPicker() } }
    }

    /// Reading mode (iPhone): fingers scroll and zoom, nothing draws, no palette.
    var drawingSuspended = false {
        didSet {
            guard drawingSuspended != oldValue else { return }
            updateEraser()
            updateToolPicker()
        }
    }

    var isReadOnly = false {
        didSet {
            guard isReadOnly != oldValue else { return }
            updateEraser()
            updateToolPicker()
        }
    }

    /// The page's ink is still being prepared: nothing can be drawn, and a
    /// spinner shows over the canvas.
    var isPreparing = false {
        didSet {
            guard isPreparing != oldValue else { return }
            updateEraser()
            if isPreparing { spinner.startAnimating() } else { spinner.stopAnimating() }
        }
    }
    private let spinner = UIActivityIndicatorView(style: .medium)

    /// The part of the page on screen, in page points (nil before layout).
    var visiblePageRect: CGRect? {
        let z = canvas.zoomScale
        guard z > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        return CGRect(x: canvas.contentOffset.x / z, y: canvas.contentOffset.y / z,
                      width: bounds.width / z, height: bounds.height / z)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Ink colours are stored as drawn on light paper; never invert them.
        canvas.overrideUserInterfaceStyle = .light
        // A Mac has no Pencil: the mouse and trackpad always draw, whatever
        // the system's Pencil preference says (`.default` follows it).
        // An iPhone has no Pencil: a finger draws (once annotating is switched on).
        canvas.drawingPolicy = Platform.isMac || Platform.isPhone ? .anyInput : .default
        canvas.alwaysBounceVertical = true
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.insertSubview(paperView, at: 0)
        canvas.insertSubview(itemLayer, aboveSubview: paperView)
        footerButton.isHidden = true
        footerButton.addAction(UIAction { [weak self] _ in self?.footerAction?() }, for: .primaryActionTriggered)
        canvas.addSubview(footerButton)
        addSubview(canvas)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     spinner.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16)])
        toolPicker.addObserver(canvas)
        toolPicker.addObserver(self)
        toolPicker.colorUserInterfaceStyle = .light
        objectEraser.attach(to: self, canvas: canvas)
        itemSelection.attach(to: canvas, itemLayer: itemLayer)
        canvas.addInteraction(UIDropInteraction(delegate: self))
        if Platform.isMac {
            let pointer = UIPointerInteraction(delegate: self)
            addInteraction(pointer)
            cursorInteraction = pointer
        }
    }

    /// A circle the size of the ink tool's stroke at the current zoom, so the
    /// pointer shows where a mouse stroke lands. The object eraser draws its
    /// own cursor, and the lasso and the pixel eraser keep the system arrow.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard !isReadOnly else { return nil }
        if objectEraserSelected { return UIPointerStyle.hidden() }
        guard let tool = canvas.tool as? PKInkingTool else { return nil }
        let d = CGFloat(PointerCursor.diameter(toolWidth: Double(tool.width), zoom: Double(canvas.zoomScale)))
        return UIPointerStyle(shape: .path(UIBezierPath(ovalIn: CGRect(x: -d / 2, y: -d / 2, width: d, height: d))),
                              constrainedAxes: [])
    }

    // MARK: Drops (images and PDFs from other apps, the Finder or Files)

    /// Whether a drop session can be taken: something to add, from another
    /// app (a note dragged out of this app's list is not added to itself), on
    /// a note that can be edited.
    func canTakeDrop(_ session: UIDropSession) -> Bool {
        dropHandler != nil && !isReadOnly && !isPreparing && session.localDragSession == nil
            && session.hasItemsConforming(toTypeIdentifiers: CanvasDrop.typeIdentifiers)
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        canTakeDrop(session)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: canTakeDrop(session) ? .copy : .forbidden)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        let z = max(canvas.zoomScale, 0.01)
        let p = session.location(in: canvas)
        dropHandler?(session.items.map(\.itemProvider), CGPoint(x: p.x / z, y: p.y / z))
    }

    /// Remembers the eraser mode the user picks, for the next canvas, and
    /// hands the object eraser to `ObjectEraserController`.
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        if let eraser = toolPicker.selectedToolItem as? PKToolPickerEraserItem {
            EraserPreference.save(eraser.eraserTool.eraserType)
        }
        if itemSelectionActive { onItemSelectionEnded?() }   // picking a tool is picking drawing
        updateEraser()
        cursorInteraction?.invalidate()
    }

    /// Drops an object-eraser gesture in progress (the drawing is being replaced).
    func cancelErasing() {
        objectEraser.cancelGesture()
    }

    /// Whether the picker's selected tool is the object eraser.
    var objectEraserSelected: Bool {
        (toolPicker.selectedToolItem as? PKToolPickerEraserItem)?.eraserTool.eraserType == .vector
    }

    /// The app's sized object eraser stands in for PencilKit's `.vector` one;
    /// every other tool (pixel eraser included) is PencilKit's.
    private func updateEraser() {
        let editable = !isReadOnly && !isPreparing && !drawingSuspended && !itemSelectionActive
        let ours = editable && objectEraserSelected
        objectEraser.setActive(ours)
        canvas.drawingGestureRecognizer.isEnabled = editable && !ours
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateToolPicker()
    }

    private func updateToolPicker() {
        guard window != nil else { return }
        defer { updateEraser() }
        let show = !isReadOnly && !drawingSuspended && paletteVisible
        toolPicker.setVisible(show, forFirstResponder: canvas)
        if !isReadOnly && !drawingSuspended { canvas.becomeFirstResponder() }
    }

    /// Swaps in a picker of the other size, keeping the selected tool when the
    /// new picker has it.
    private func rebuildToolPicker() {
        let old = toolPicker
        old.setVisible(false, forFirstResponder: canvas)
        old.removeObserver(canvas)
        old.removeObserver(self)
        let new = ToolPalette.makePicker(compact: paletteCompact)
        if new.toolItems.contains(where: { $0.identifier == old.selectedToolItemIdentifier }) {
            new.selectedToolItemIdentifier = old.selectedToolItemIdentifier
        }
        new.colorUserInterfaceStyle = .light
        new.addObserver(canvas)
        new.addObserver(self)
        toolPicker = new
        updateToolPicker()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        fitWidth()
        #if DEBUG
        if debugLaunchPending, bounds.width > 0 {
            debugLaunchPending = false
            DebugLaunch.canvasDidLayOut(self)
        }
        #endif
    }

    #if DEBUG
    private var debugLaunchPending = DebugLaunch.isActive
    #endif

    func apply(paper: Paper, pageSize: PageSize) {
        self.paper = paper
        self.pageSize = Self.displayable(pageSize)
        if inkMaxY == nil { inkMaxY = Self.inkBottom(canvas.drawing) }
        fitWidth(force: true)
    }

    /// The drawing changed (loaded, drawn on, erased): the scrollable extent follows its ink.
    func inkDidChange() {
        inkMaxY = Self.inkBottom(canvas.drawing)
        zoomChanged()
    }

    private static func inkBottom(_ drawing: PKDrawing) -> Double? {
        let bounds = drawing.bounds
        return bounds.isNull || bounds.isEmpty ? nil : Double(bounds.maxY)
    }

    private func updateFooter() {
        var config = UIButton.Configuration.bordered()
        switch footer {
        case .none:
            footerButton.isHidden = true
        case .addPage:
            config.title = "Add Page"
            config.image = UIImage(systemName: "doc.badge.plus")
            footerButton.isHidden = false
        case .nextPage:
            config.title = "Next Page"
            config.image = UIImage(systemName: "chevron.down")
            footerButton.isHidden = false
        }
        config.imagePadding = 8
        config.buttonSize = .large
        footerButton.configuration = config
        footerButton.accessibilityIdentifier = "pageFooter"
        zoomChanged()
    }

    /// `size` with width and height clamped to 1 ... `RenderLimits.maxExtent`
    /// points (letter for non-finite values), so a corrupt page size cannot
    /// produce an absurd zoom scale or content size.
    static func displayable(_ size: PageSize) -> PageSize {
        func clamp(_ v: Double, _ fallback: Double) -> Double {
            v.isFinite ? min(max(v, 1), RenderLimits.maxExtent) : fallback
        }
        var s = size
        s.width = clamp(size.width, PageSize.letter.width)
        s.height = clamp(size.height, PageSize.letter.height)
        return s
    }

    func scrollToTop() {
        canvas.setContentOffset(.zero, animated: false)
    }

    /// Zoom range: page width fills the view at minimum, 4x at maximum.
    private func fitWidth(force: Bool = false) {
        guard bounds.width > 0, pageSize.width > 0 else { return }
        let fit = bounds.width / CGFloat(pageSize.width)
        if fit != fittedWidth || force {
            let wasFitted = fittedWidth == 0 || abs(canvas.zoomScale - fittedWidth) < 0.001
            fittedWidth = fit
            canvas.minimumZoomScale = fit
            canvas.maximumZoomScale = fit * 4
            if wasFitted || canvas.zoomScale < fit { canvas.zoomScale = fit }
        }
        zoomChanged()
    }

    /// Content size and paper follow the zoom (`PageExtent`): an infinite
    /// page scrolls a screen beyond its ink and its stored height; a finite
    /// page ends with room for the Add Page / Next Page button.
    func zoomChanged() {
        let z = canvas.zoomScale
        guard z > 0 else { return }
        cursorInteraction?.invalidate()
        let height = PageExtent.scrollHeight(pageSize: pageSize, inkMaxY: inkMaxY,
                                             viewportHeight: Double(bounds.height / z),
                                             footerHeight: footer == .none ? 0 : Double(PageExtent.footerScreenHeight / z))
        let paperHeight = pageSize.infinite ? height : pageSize.height
        let size = CGSize(width: CGFloat(pageSize.width), height: CGFloat(paperHeight))
        paperView.configure(paper: paper, size: size, sheetHeight: PaperRenderer.sheetHeight(for: pageSize))
        paperView.setZoom(z)
        canvas.contentSize = CGSize(width: size.width * z, height: CGFloat(height) * z)
        itemLayer.frame = CGRect(origin: .zero, size: canvas.contentSize)
        itemLayer.setZoom(z)
        itemSelection.refresh()
        if footer != .none {
            footerButton.sizeToFit()
            let b = footerButton.bounds.size
            footerButton.frame = CGRect(x: (canvas.contentSize.width - b.width) / 2,
                                        y: CGFloat(pageSize.height) * z + (PageExtent.footerScreenHeight - b.height) / 2,
                                        width: b.width, height: b.height)
        }
    }
}

/// How far a page scrolls.
enum PageExtent {
    /// The control below a finite page.
    enum Footer: Equatable { case none, addPage, nextPage }

    /// Screen points below a finite page for its footer button.
    static let footerScreenHeight: CGFloat = 120

    /// The scrollable height of a page in page points.
    ///
    /// - Infinite pages always scroll at least one screen (`viewportHeight`,
    ///   in page points at the current zoom) below both the ink and the
    ///   stored height, so there is always room to keep writing; the stored
    ///   height grows as the user writes (`NoteEditor.growPage`) and this
    ///   follows it.
    /// - Finite pages end at their height plus `footerHeight` (the Add Page /
    ///   Next Page button), and never less than a screen.
    ///
    /// Every term is clamped to `RenderLimits.maxExtent` (non-finite: 0), so
    /// a stroke or page size far out of range cannot produce an absurd
    /// content size.
    static func scrollHeight(pageSize: PageSize, inkMaxY: Double?, viewportHeight: Double, footerHeight: Double = 0) -> Double {
        func clamped(_ v: Double?) -> Double {
            guard let v, v.isFinite else { return 0 }
            return min(max(v, 0), RenderLimits.maxExtent)
        }
        let screen = clamped(viewportHeight)
        let page = clamped(pageSize.height)
        if pageSize.infinite {
            return max(page, clamped(inkMaxY)) + screen
        }
        return max(page + clamped(footerHeight), screen)
    }
}

// MARK: - Menu commands (Mac)

extension PageCanvasHost: CanvasCommandTarget {
    @discardableResult
    func select(tool choice: ToolChoice) -> Bool {
        guard !isReadOnly, let item = toolPicker.toolItems.first(where: { choice.matches($0) }) else { return false }
        toolPicker.selectedToolItemIdentifier = item.identifier
        updateEraser()
        cursorInteraction?.invalidate()
        return true
    }

    func zoom(in zoomingIn: Bool) {
        guard fittedWidth > 0 else { return }
        let target = ZoomSteps.step(from: Double(canvas.zoomScale), fit: Double(fittedWidth), zoomingIn: zoomingIn)
        canvas.setZoomScale(CGFloat(target), animated: true)
    }

    func zoomToFit() {
        guard fittedWidth > 0 else { return }
        canvas.setZoomScale(fittedWidth, animated: true)
    }

    func zoomToActualSize() {
        guard fittedWidth > 0 else { return }
        canvas.setZoomScale(CGFloat(ZoomSteps.actualSize(fit: Double(fittedWidth))), animated: true)
    }

    func toggleRuler() {
        guard !isReadOnly else { return }
        canvas.isRulerActive.toggle()
    }
}
