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
    /// `NoteEditor.canvasGeneration`: a change reloads the drawing even when
    /// the page id stays the same.
    var generation = 0

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
        if c.pageID != pageID || c.editorID != ObjectIdentifier(editor) || c.generation != generation {
            c.pageID = pageID
            c.editorID = ObjectIdentifier(editor)
            c.generation = generation
            c.isLoading = true
            host.cancelErasing()   // an erase in progress belongs to the old page
            host.canvas.drawing = editor.drawing(for: pageID)
            host.canvas.undoManager?.removeAllActions()   // undo must not cross pages or notes
            c.isLoading = false
            host.inkDidChange()
            host.scrollToTop()
            #if DEBUG
            if DebugLaunch.isActive {
                let d = host.canvas.drawing
                NSLog("SempereDebug loaded strokes=%d bounds=%@ pageSize=%@", d.strokes.count,
                      NSCoder.string(for: d.bounds), "\(pageSize)")
            }
            #endif
        }
        host.isReadOnly = editor.isReadOnly
        let index = editor.pages.firstIndex { $0.id == pageID }
        let isLast = index == editor.pages.count - 1
        host.footer = pageSize.infinite ? .none
            : (isLast ? (editor.isReadOnly ? .none : .addPage) : .nextPage)
        host.footerAction = { [weak editor] in
            guard let editor else { return }
            if isLast { editor.addPage() } else if let index { editor.selectPage(index + 1) }
        }
        host.paletteCompact = paletteCompact
        host.paletteVisible = paletteVisible
        host.apply(paper: paper, pageSize: pageSize)
    }

    static func dismantleUIView(_ host: PageCanvasHost, coordinator: Coordinator) {
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
        var isLoading = false

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
final class PageCanvasHost: UIView, PKToolPickerObserver {
    let canvas = PKCanvasView()
    private let paperView = PaperView()
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

    var isReadOnly = false {
        didSet {
            guard isReadOnly != oldValue else { return }
            updateEraser()
            updateToolPicker()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Ink colours are stored as drawn on light paper; never invert them.
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawingPolicy = .default
        canvas.alwaysBounceVertical = true
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.insertSubview(paperView, at: 0)
        footerButton.isHidden = true
        footerButton.addAction(UIAction { [weak self] _ in self?.footerAction?() }, for: .primaryActionTriggered)
        canvas.addSubview(footerButton)
        addSubview(canvas)
        toolPicker.addObserver(canvas)
        toolPicker.addObserver(self)
        toolPicker.colorUserInterfaceStyle = .light
        objectEraser.attach(to: self, canvas: canvas)
    }

    /// Remembers the eraser mode the user picks, for the next canvas, and
    /// hands the object eraser to `ObjectEraserController`.
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        if let eraser = toolPicker.selectedToolItem as? PKToolPickerEraserItem {
            EraserPreference.save(eraser.eraserTool.eraserType)
        }
        updateEraser()
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
        let ours = !isReadOnly && objectEraserSelected
        objectEraser.setActive(ours)
        canvas.drawingGestureRecognizer.isEnabled = !isReadOnly && !ours
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
        let show = !isReadOnly && paletteVisible
        toolPicker.setVisible(show, forFirstResponder: canvas)
        if !isReadOnly { canvas.becomeFirstResponder() }
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
        let height = PageExtent.scrollHeight(pageSize: pageSize, inkMaxY: inkMaxY,
                                             viewportHeight: Double(bounds.height / z),
                                             footerHeight: footer == .none ? 0 : Double(PageExtent.footerScreenHeight / z))
        let paperHeight = pageSize.infinite ? height : pageSize.height
        let size = CGSize(width: CGFloat(pageSize.width), height: CGFloat(paperHeight))
        paperView.configure(paper: paper, size: size, sheetHeight: PaperRenderer.sheetHeight(for: pageSize))
        paperView.setZoom(z)
        canvas.contentSize = CGSize(width: size.width * z, height: CGFloat(height) * z)
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
