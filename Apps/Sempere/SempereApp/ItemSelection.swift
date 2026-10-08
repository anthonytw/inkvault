import PencilKit
import Sempere
import UIKit

/// What selecting items does, decided without UIKit (tested): which item a
/// touch picks, whether a drag moves or resizes, and the frame it leads to.
struct ItemSelectionModel {
    /// Handle radius on screen, in points; touches this close to a corner resize.
    static let handleRadius = 22.0
    /// Extra room around an item that still selects it, on screen.
    static let slop = 8.0

    /// The selected item, if any.
    var selected: UUID?

    /// What a drag starting at a page point does.
    enum Drag: Equatable {
        case move(UUID)
        case resize(UUID, ItemFrames.Corner)
    }

    /// The item a tap at `p` (page points) selects, at `zoom`.
    static func hit(_ p: ItemFrames.Point, items: [Item], zoom: Double) -> Item? {
        ItemFrames.item(at: p, in: items, slop: slop / max(zoom, 0.01))
    }

    /// What a drag from `p` does: a corner of the selected item resizes it,
    /// the inside of an item (the selected one first) moves it; nil leaves
    /// the drag to scrolling. A background item (a full-page PDF page) moves
    /// only once it is selected, so dragging over it scrolls.
    func drag(at p: ItemFrames.Point, items: [Item], zoom: Double) -> Drag? {
        let z = max(zoom, 0.01)
        if let id = selected, let item = items.first(where: { $0.id == id }) {
            let corners = ItemFrames.corners(item.frame, rotation: item.rotation)
            let r = Self.handleRadius / z
            if let i = corners.indices.min(by: { Self.distance(corners[$0], p) < Self.distance(corners[$1], p) }),
               Self.distance(corners[i], p) <= r, let corner = ItemFrames.Corner(rawValue: i) {
                return .resize(id, corner)
            }
            if ItemFrames.contains(item.frame, rotation: item.rotation, p, slop: Self.slop / z) { return .move(id) }
        }
        return ItemFrames.item(at: p, in: items, slop: Self.slop / z, includeBackground: false).map { .move($0.id) }
    }

    /// The frame a drag by `dx`, `dy` (page points) gives `item`.
    static func frame(for drag: Drag, item: Item, dx: Double, dy: Double) -> Rect {
        switch drag {
        case .move:
            return ItemFrames.moved(item.frame, dx: dx, dy: dy)
        case .resize(_, let corner):
            // Pictures keep their proportions; text boxes and unknown kinds do not.
            let keep = item.kind == .image || item.kind == .pdfPage
            return ItemFrames.resized(item.frame, rotation: item.rotation, corner: corner, dx: dx, dy: dy, keepAspect: keep)
        }
    }

    static func distance(_ a: ItemFrames.Point, _ b: ItemFrames.Point) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}

/// The selected item's outline and resize handles, in canvas content
/// coordinates, above the ink. Not interactive.
final class ItemSelectionView: UIView {
    private let outline = CAShapeLayer()
    private var handles: [CAShapeLayer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        outline.fillColor = nil
        outline.strokeColor = UIColor.tintColor.cgColor
        outline.lineWidth = 1.5
        outline.lineDashPattern = [6, 4]
        layer.addSublayer(outline)
        for _ in 0..<4 {
            let h = CAShapeLayer()
            h.fillColor = UIColor.white.cgColor
            h.strokeColor = UIColor.tintColor.cgColor
            h.lineWidth = 1.5
            layer.addSublayer(h)
            handles.append(h)
        }
        isHidden = true
        accessibilityIdentifier = "itemSelection"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Outlines `frame` turned by `rotation` at `zoom`; nil hides the selection.
    func show(frame: Rect?, rotation: Double?, zoom: CGFloat, handles showHandles: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let frame else { isHidden = true; return }
        isHidden = false
        let corners = ItemFrames.corners(frame, rotation: rotation).map { CGPoint(x: $0.x * Double(zoom), y: $0.y * Double(zoom)) }
        let path = UIBezierPath()
        path.move(to: corners[0])
        for p in corners.dropFirst() { path.addLine(to: p) }
        path.close()
        outline.path = path.cgPath
        for (h, c) in zip(handles, corners) {
            h.isHidden = !showHandles
            h.path = UIBezierPath(ovalIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)).cgPath
        }
    }
}

/// What the selection needs from the app: the clipboard and pasting
/// (`AppModel`), and how to leave selection mode.
struct ItemCommands {
    var copy: @MainActor (_ items: [Item], _ note: UUID) -> Void = { _, _ in }
    var canPaste: @MainActor () -> Bool = { false }
    var paste: @MainActor (_ page: UUID, _ actions: ItemActions) async -> [Item] = { _, _ in [] }
    /// Opens the crop sheet for an image or PDF page; nil: no Crop in the menu.
    var crop: (@MainActor (_ item: Item, _ page: UUID, _ actions: ItemActions) -> Void)?
    /// Plays a video item (format.md §8.2.7); nil: no Play in the menu, and a tap on a clip does nothing.
    var play: (@MainActor (_ item: Item, _ page: UUID) -> Void)?
    /// Opens the equation sheet for a math item; nil: no Edit Equation in the menu.
    var editMath: (@MainActor (_ item: Item, _ page: UUID, _ actions: ItemActions) -> Void)?
}

/// Selecting, moving, resizing and deleting items on the canvas while
/// selection mode is on (`PageCanvasHost.itemSelectionActive`): PencilKit's
/// drawing gesture is off then, a tap selects the topmost item (content
/// before backgrounds), a drag on it moves it, a drag on a corner resizes it,
/// and a tap on the selected item opens its menu. Every gesture ends in one
/// delta and one undo step (`ItemActions`); while it runs, the item layer
/// shows the frame it would get. UIKit calls the edit-menu delegate on the
/// main thread; that protocol is not main-actor isolated, so the conformance is.
@MainActor
final class ItemSelectionController: NSObject, UIGestureRecognizerDelegate, @MainActor UIEditMenuInteractionDelegate {
    private weak var canvas: UIScrollView?
    private weak var itemLayer: ItemLayerView?
    private let overlay = ItemSelectionView()
    private let tap = UITapGestureRecognizer()
    private let pan = UIPanGestureRecognizer()
    /// Outside selection mode: a finger tap on a video item plays it, when fingers do not draw.
    private let videoTap = UITapGestureRecognizer()
    private var menu: UIEditMenuInteraction?
    private var model = ItemSelectionModel()
    private var drag: (ItemSelectionModel.Drag, Item)?

    var editor: NoteEditor?
    var pageID: UUID?
    var commands = ItemCommands()
    /// Opens a text box in its editor ("Edit Text").
    var onEditText: ((Item) -> Void)?
    /// The scroll view that pans the page: the canvas itself, or the paged
    /// stack around it (`PageStackHost`), whose scroll a drag on an item stops.
    weak var scroller: UIScrollView?
    /// Undo and redo of item gestures, on the canvas's undo manager.
    private(set) var actions: ItemActions?

    /// The selected item (tests, menus).
    var selectedID: UUID? { model.selected }

    func attach(to canvas: UIScrollView, itemLayer: ItemLayerView) {
        self.canvas = canvas
        self.itemLayer = itemLayer
        canvas.addSubview(overlay)
        tap.addTarget(self, action: #selector(tapped(_:)))
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        for g in [tap, pan] as [UIGestureRecognizer] {
            g.delegate = self
            g.isEnabled = false
            canvas.addGestureRecognizer(g)
        }
        videoTap.addTarget(self, action: #selector(videoTapped(_:)))
        videoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        videoTap.cancelsTouchesInView = false
        videoTap.delegate = self
        canvas.addGestureRecognizer(videoTap)
        let menu = UIEditMenuInteraction(delegate: self)
        canvas.addInteraction(menu)
        self.menu = menu
    }

    /// Selection mode on or off; off clears the selection.
    func setActive(_ active: Bool) {
        tap.isEnabled = active
        pan.isEnabled = active
        if !active { select(nil) }
    }

    var isActive: Bool { tap.isEnabled }

    /// The note or page on the canvas changed.
    func reset(editor: NoteEditor, pageID: UUID, undoManager: UndoManager?) {
        if self.editor !== editor || self.pageID != pageID || actions?.undoManager !== undoManager {
            self.editor = editor
            self.pageID = pageID
            actions = ItemActions(editor: editor, undoManager: undoManager)
            select(nil)
        }
    }

    private var items: [Item] {
        guard let editor, let pageID else { return [] }
        return editor.items(on: pageID)
    }

    private var zoom: CGFloat { max(canvas?.zoomScale ?? 1, 0.01) }

    private func pagePoint(_ g: UIGestureRecognizer) -> ItemFrames.Point {
        let p = g.location(in: canvas)
        return ItemFrames.Point(x: Double(p.x / zoom), y: Double(p.y / zoom))
    }

    /// Selects `id` (nil: nothing) and redraws the outline.
    func select(_ id: UUID?) {
        model.selected = id
        refresh()
    }

    /// Redraws the outline (the zoom, the item or the selection changed).
    func refresh() {
        overlay.frame = CGRect(origin: .zero, size: canvas?.contentSize ?? .zero)
        canvas?.bringSubviewToFront(overlay)
        guard let id = model.selected, let item = items.first(where: { $0.id == id }) else {
            if model.selected != nil, drag == nil { model.selected = nil }
            overlay.show(frame: nil, rotation: nil, zoom: zoom, handles: false)
            return
        }
        let frame = itemLayer?.shownFrame(of: id) ?? item.frame
        overlay.show(frame: frame, rotation: item.rotation, zoom: zoom, handles: editor?.canEditItems ?? false)
    }

    // MARK: Gestures

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === videoTap { return videoUnderFingerTap(g) != nil }
        guard g === pan else { return true }
        // Only a drag on an item (or a handle) is ours; any other scrolls.
        guard editor?.canEditItems == true else { return false }
        return model.drag(at: pagePoint(g), items: items, zoom: Double(zoom)) != nil
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === videoTap
    }

    /// The video under a finger tap in drawing mode: only when Play is wired, selection mode is
    /// off, and fingers do not draw on this canvas (else the tap is ink).
    private func videoUnderFingerTap(_ g: UIGestureRecognizer) -> Item? {
        guard commands.play != nil, !isActive, let canvas = canvas as? PKCanvasView,
              !ObjectEraserController.fingersDraw(canvas) else { return nil }
        guard let hit = ItemSelectionModel.hit(pagePoint(g), items: items, zoom: Double(zoom)), hit.kind == .video else { return nil }
        return hit
    }

    @objc private func videoTapped(_ g: UITapGestureRecognizer) {
        guard let item = videoUnderFingerTap(g), let pageID else { return }
        commands.play?(item, pageID)
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = pagePoint(g)
        let hit = ItemSelectionModel.hit(p, items: items, zoom: Double(zoom))
        if let hit, hit.id == model.selected {
            presentMenu(at: g.location(in: canvas))
        } else if let hit {
            select(hit.id)
        } else {
            select(nil)
            if commands.canPaste(), editor?.canEditItems == true { presentMenu(at: g.location(in: canvas)) }
        }
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            let start = pagePoint(g)
            let translation = g.translation(in: canvas)
            let origin = ItemFrames.Point(x: start.x - Double(translation.x / zoom), y: start.y - Double(translation.y / zoom))
            guard let d = model.drag(at: origin, items: items, zoom: Double(zoom)) else { return }
            let id: UUID
            switch d { case .move(let i), .resize(let i, _): id = i }
            guard let item = items.first(where: { $0.id == id }) else { return }
            drag = (d, item)
            select(id)
            // A drag on an item moves the item, not the page: stop a scroll that started with it.
            if let scroll = (scroller ?? canvas)?.panGestureRecognizer, scroll.state == .began || scroll.state == .changed {
                scroll.isEnabled = false
                scroll.isEnabled = true
            }
            fallthrough
        case .changed:
            guard let current = drag else { return }
            let (d, item) = current
            let t = g.translation(in: canvas)
            let frame = ItemSelectionModel.frame(for: d, item: item, dx: Double(t.x / zoom), dy: Double(t.y / zoom))
            itemLayer?.preview(item.id, frame: frame)
            refresh()
        case .ended:
            guard let current = drag, let pageID else { return cancelDrag() }
            let (d, item) = current
            let t = g.translation(in: canvas)
            let frame = ItemSelectionModel.frame(for: d, item: item, dx: Double(t.x / zoom), dy: Double(t.y / zoom))
            drag = nil
            itemLayer?.preview(item.id, frame: nil)
            if case .resize = d {
                actions?.setFrame(item.id, to: frame, on: pageID, name: String(localized: "Resize", comment: "Undo action name (Edit menu: Undo …)"))
            } else {
                actions?.setFrame(item.id, to: frame, on: pageID, name: String(localized: "Move", comment: "Undo action name (Edit menu: Undo …)"))
            }
            refresh()
        default:
            cancelDrag()
        }
    }

    private func cancelDrag() {
        if let current = drag { itemLayer?.preview(current.1.id, frame: nil) }
        drag = nil
        refresh()
    }

    // MARK: Menu

    private func presentMenu(at point: CGPoint) {
        menu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        var elements: [UIMenuElement] = []
        let editable = editor?.canEditItems == true
        if let id = model.selected, let pageID, let editor, let item = editor.item(id, on: pageID) {
            if item.kind == .video, let play = commands.play {
                elements.append(UIAction(title: String(localized: "Play"), image: UIImage(systemName: "play.fill")) { _ in play(item, pageID) })
            }
            elements.append(UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.commands.copy([item], editor.noteID)
            })
            if editable, item.kind == .text, item.text != nil, let edit = onEditText {
                elements.append(UIAction(title: String(localized: "Edit Text"), image: UIImage(systemName: "character.cursor.ibeam")) { [weak self] _ in
                    self?.select(nil)
                    edit(item)
                })
            }
            if editable {
                elements.append(UIAction(title: String(localized: "Duplicate"), image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                    guard let self, let new = self.actions?.duplicate([id], on: pageID).first else { return }
                    self.select(new.id)
                })
                if let editMath = commands.editMath, item.kind == .math, item.math != nil, let actions {
                    elements.append(UIAction(title: "Edit Equation…", image: UIImage(systemName: "function")) { [weak self] _ in
                        self?.select(nil)
                        editMath(item, pageID, actions)
                    })
                }
                if let crop = commands.crop, item.cropBounds != nil, let actions {
                    elements.append(UIAction(title: String(localized: "Crop…"), image: UIImage(systemName: "crop")) { _ in
                        crop(item, pageID, actions)
                    })
                }
                elements.append(UIAction(title: String(localized: "Bring to Front"), image: UIImage(systemName: "square.3.layers.3d.top.filled")) {
                    [weak self] _ in
                    self?.actions?.bringToFront(id, on: pageID)
                    self?.refresh()
                })
                elements.append(UIAction(title: String(localized: "Delete"), image: UIImage(systemName: "trash"), attributes: .destructive) {
                    [weak self] _ in
                    self?.deleteSelection()
                })
            }
        }
        if editable, commands.canPaste() {
            elements.append(UIAction(title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.pasteClipboard()
            })
        }
        return elements.isEmpty ? nil : UIMenu(children: elements)
    }

    /// Deletes the selected item (one delta, undoable).
    func deleteSelection() {
        guard let id = model.selected, let pageID else { return }
        actions?.delete([id], on: pageID)
        select(nil)
    }

    /// Pastes the clipboard onto this page and selects the first pasted item.
    func pasteClipboard() {
        guard let pageID, let actions else { return }
        let paste = commands.paste
        Task { [weak self] in
            let pasted = await paste(pageID, actions)
            if let first = pasted.first { self?.select(first.id) }
        }
    }
}
