import InkRender
import InkVault
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
        if c.pageID != pageID || c.editorID != ObjectIdentifier(editor) {
            c.pageID = pageID
            c.editorID = ObjectIdentifier(editor)
            c.isLoading = true
            host.canvas.drawing = editor.drawing(for: pageID)
            host.canvas.undoManager?.removeAllActions()   // undo must not cross pages or notes
            c.isLoading = false
            host.scrollToTop()
        }
        host.isReadOnly = editor.isReadOnly
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
        var isLoading = false

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isLoading, let editor, let pageID else { return }
            editor.drawingDidChange(pageID: pageID, drawing: canvasView.drawing, tool: canvasView.tool)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            host?.zoomChanged()
        }
    }
}

/// UIKit side of `PageCanvasView`.
final class PageCanvasHost: UIView {
    let canvas = PKCanvasView()
    private let paperView = PaperView()
    private let toolPicker = PKToolPicker()
    private var pageSize = PageSize.letter
    private var paper = Paper.blank
    private var fittedWidth: CGFloat = 0

    var isReadOnly = false {
        didSet {
            guard isReadOnly != oldValue else { return }
            canvas.drawingGestureRecognizer.isEnabled = !isReadOnly
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
        addSubview(canvas)
        toolPicker.addObserver(canvas)
        toolPicker.colorUserInterfaceStyle = .light
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateToolPicker()
    }

    private func updateToolPicker() {
        guard window != nil else { return }
        toolPicker.setVisible(!isReadOnly, forFirstResponder: canvas)
        if !isReadOnly { canvas.becomeFirstResponder() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        fitWidth()
    }

    func apply(paper: Paper, pageSize: PageSize) {
        self.paper = paper
        self.pageSize = Self.displayable(pageSize)
        fitWidth(force: true)
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

    /// Content size and paper follow the zoom. An infinite page always
    /// scrolls at least a screen beyond its stored height.
    func zoomChanged() {
        let z = canvas.zoomScale
        var height = CGFloat(pageSize.height)
        if pageSize.infinite, fittedWidth > 0 { height = max(height, bounds.height / fittedWidth) }
        let size = CGSize(width: CGFloat(pageSize.width), height: height)
        paperView.configure(paper: paper, size: size)
        paperView.setZoom(z)
        canvas.contentSize = CGSize(width: size.width * z, height: size.height * z)
    }
}
