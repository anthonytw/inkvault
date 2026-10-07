import Sempere
import SempereRender
import UIKit

/// Typing in text boxes on the canvas (docs/attachments.md §13 "Text
/// editing on the canvas", task E2). With the text tool on, a tap on a text
/// box edits it and a tap elsewhere starts a new box there; selection mode's
/// "Edit Text" edits the selected box. The box is edited in a `UITextView`
/// (TextKit 1, the layout `TextKitBreaks` uses) laid over the page at the
/// canvas zoom, with a style bar above the keyboard (bold, italic,
/// underline, strikethrough, size, colour, font, alignment, direction);
/// Scribble writes into it like any text field. Ending the edit (Done, a
/// tap outside, another page or note) writes one delta through
/// `ItemActions`: the text with `breaks` from TextKit and the height of its
/// lines (`TextBoxEditing.content`), an empty new box nothing, a box emptied
/// a delete. Nothing is written while typing.
@MainActor
final class TextBoxEditorController: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
    private weak var canvas: UIScrollView?
    private weak var itemLayer: ItemLayerView?
    private let tap = UITapGestureRecognizer()

    var editor: NoteEditor?
    var pageID: UUID?
    /// Undoable item edits (the selection controller's, on the canvas's undo manager).
    var actions: () -> ItemActions? = { nil }
    /// Called when editing starts or ends (the host turns drawing and selection off meanwhile).
    var onEditingChanged: (Bool) -> Void = { _ in }

    /// What is being edited.
    struct Session {
        /// The box edited; nil for a new one.
        var itemID: UUID?
        var pageID: UUID
        /// Its frame (page points); the height follows the text.
        var frame: Rect
        var rotation: Double?
        var original: TextContent?
        var style: TextBoxEditing.BoxStyle
        /// Changed since editing started.
        var dirty = false
    }

    private(set) var session: Session?
    /// The controller editing now, if any: one box is edited at a time, also
    /// across the pages of a paged note (each page has its own controller).
    private static weak var editing: TextBoxEditorController?
    private(set) var textView: UITextView?

    /// The style of the last box edited: the next new box starts with it.
    static var lastStyle = TextBoxEditing.BoxStyle(TextContent(size: 16, color: .black, runs: []))

    var isEditing: Bool { session != nil }

    func attach(to canvas: UIScrollView, itemLayer: ItemLayerView) {
        self.canvas = canvas
        self.itemLayer = itemLayer
        tap.addTarget(self, action: #selector(tapped(_:)))
        tap.delegate = self
        tap.isEnabled = false
        canvas.addGestureRecognizer(tap)
    }

    /// The text tool on or off. Turning it off ends an edit in progress.
    var toolActive = false {
        didSet {
            guard toolActive != oldValue else { return }
            if !toolActive { endEditing() }
            updateTap()
        }
    }

    private func updateTap() { tap.isEnabled = toolActive || isEditing }

    /// The note or page on the canvas changed: an edit in progress is written first.
    func reset(editor: NoteEditor, pageID: UUID) {
        if self.editor !== editor || self.pageID != pageID {
            endEditing()
            self.editor = editor
            self.pageID = pageID
        }
    }

    private var zoom: CGFloat { max(canvas?.zoomScale ?? 1, 0.01) }

    private func pagePoint(_ g: UIGestureRecognizer) -> ItemFrames.Point {
        let p = g.location(in: canvas)
        return ItemFrames.Point(x: Double(p.x / zoom), y: Double(p.y / zoom))
    }

    // MARK: Gestures

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Touches in the text view (or its bar) are the text view's.
        if let tv = textView, let view = touch.view, view.isDescendant(of: tv) { return false }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        if isEditing {
            // A tap outside the box ends the edit; it does not start another box.
            endEditing()
            return
        }
        guard toolActive, let editor, let pageID, editor.canEditItems else { return }
        let p = pagePoint(g)
        let items = editor.items(on: pageID)
        if let hit = TextBoxPlacement.textBox(at: p, in: items, zoom: Double(zoom)) {
            begin(hit)
        } else {
            beginNew(at: p)
        }
    }

    // MARK: Editing

    /// Starts editing the text box `item` of the current page.
    func begin(_ item: Item) {
        guard item.kind == .text, let content = item.text, let pageID, editor?.canEditItems == true else { return }
        endEditing()
        session = Session(itemID: item.id, pageID: pageID, frame: item.frame, rotation: item.rotation, original: content,
                          style: TextBoxEditing.BoxStyle(content))
        itemLayer?.hiddenItem = item.id
        present(TextBoxEditing.attributed(content))
    }

    /// Starts a new box with its top-left corner at `p` (page points).
    func beginNew(at p: ItemFrames.Point) {
        guard let editor, let pageID, editor.canEditItems else { return }
        endEditing()
        let style = Self.lastStyle
        let frame = TextBoxPlacement.newFrame(at: p, pageWidth: editor.pageSize.width, size: style.size)
        session = Session(itemID: nil, pageID: pageID, frame: frame, rotation: nil, original: nil, style: style)
        present(NSAttributedString())
    }

    private func present(_ text: NSAttributedString) {
        guard let canvas, let session else { return }
        if let other = Self.editing, other !== self { other.endEditing() }
        Self.editing = self
        let tv = UITextView(usingTextLayoutManager: false)
        tv.accessibilityIdentifier = "textBoxEditor"
        tv.backgroundColor = UIColor.white.withAlphaComponent(0.85)
        tv.layer.borderColor = UIColor.tintColor.cgColor
        tv.layer.borderWidth = 1 / zoom
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        tv.allowsEditingTextAttributes = true
        tv.overrideUserInterfaceStyle = .light   // text colours are stored as on light paper
        tv.attributedText = text
        tv.typingAttributes = text.length > 0 ? text.attributes(at: text.length - 1, effectiveRange: nil)
            : TextBoxEditing.typingAttributes(session.style)
        tv.delegate = self
        tv.inputAccessoryView = makeStyleBar()
        canvas.addSubview(tv)
        textView = tv
        layoutTextView()
        updateTap()
        onEditingChanged(true)
        tv.becomeFirstResponder()
    }

    /// Ends the edit, writing it unless `commit` is false.
    func endEditing(commit: Bool = true) {
        guard let session, let tv = textView else { return }
        self.session = nil
        textView = nil
        if Self.editing === self { Self.editing = nil }
        tv.delegate = nil
        let text = tv.attributedText ?? NSAttributedString()
        let language = tv.textInputMode?.primaryLanguage
        tv.resignFirstResponder()
        tv.removeFromSuperview()
        itemLayer?.hiddenItem = nil
        updateTap()
        defer { onEditingChanged(false) }
        Self.lastStyle = session.style
        guard commit, session.dirty, let editor, editor.canEditItems, let actions = actions() else { return }
        let written = TextBoxEditing.content(from: text, style: session.style, original: session.original,
                                             keyboardLanguage: language, frame: session.frame)
        if let id = session.itemID {
            if written.content.string.isEmpty {
                actions.delete([id], on: session.pageID)
            } else {
                actions.setText(id, to: written.content, frame: written.frame, on: session.pageID)
            }
        } else {
            actions.addText(written.content, frame: written.frame, on: session.pageID)
        }
    }

    /// Places the text view over the box at the canvas zoom (the zoom changed,
    /// or the text grew).
    func layoutTextView() {
        guard let tv = textView, let session else { return }
        let z = zoom
        let w = CGFloat(session.frame.w)
        let fit = tv.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
        let h = max(CGFloat(session.frame.h), fit, CGFloat(1.2 * session.style.size))
        tv.transform = .identity
        tv.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        tv.center = CGPoint(x: (CGFloat(session.frame.x) + w / 2) * z, y: (CGFloat(session.frame.y) + h / 2) * z)
        tv.transform = CGAffineTransform(rotationAngle: CGFloat((session.rotation ?? 0) * .pi / 180)).scaledBy(x: z, y: z)
        tv.layer.borderWidth = 1 / z
        // Sharp text at any zoom: the text view draws at the zoomed resolution.
        let scale = z * max(tv.traitCollection.displayScale, 1)
        func sharpen(_ v: UIView) {
            v.contentScaleFactor = scale
            v.subviews.forEach(sharpen)
        }
        sharpen(tv)
        canvas?.bringSubviewToFront(tv)
    }

    /// Typing or pasting that would take the box past the format's text
    /// limit (format.md §8.4) is refused as it happens: a box over it could
    /// not be written, and the whole edit would be lost when it closes.
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        Self.fits(textView.text ?? "", replacing: range, with: text)
    }

    /// Whether `current` with `range` (UTF-16) replaced by `text` stays
    /// within `TextContent.Limits.utf8Bytes`. A change that shortens the text always fits.
    nonisolated static func fits(_ current: String, replacing range: NSRange, with text: String) -> Bool {
        guard let r = Range(range, in: current) else { return true }
        let removed = current[r].utf8.count, added = text.utf8.count
        return added <= removed || current.utf8.count - removed + added <= TextContent.Limits.utf8Bytes
    }

    func textViewDidChange(_ textView: UITextView) {
        session?.dirty = true
        layoutTextView()
    }

    // MARK: Style bar

    private func makeStyleBar() -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 600, height: 44))
        bar.accessibilityIdentifier = "textStyleBar"
        func toggle(_ name: String, _ title: String, _ change: TextBoxEditing.Change) -> UIBarButtonItem {
            let item = UIBarButtonItem(image: UIImage(systemName: name), primaryAction: UIAction(title: title) { [weak self] _ in
                self?.apply(change)
            })
            item.accessibilityLabel = title
            return item
        }
        let sizes = UIMenu(title: "Size", children: TextBoxPlacement.sizes.map { s in
            UIAction(title: "\(Int(s)) pt") { [weak self] _ in self?.apply(.size(s)) }
        })
        let colours = UIMenu(title: "Colour", children: TextBoxPlacement.colours.map { c in
            UIAction(title: c.name, image: UIImage(systemName: "circle.fill")?.withTintColor(c.color.uiColor, renderingMode: .alwaysOriginal)) {
                [weak self] _ in self?.apply(.color(c.color))
            }
        })
        let fonts = UIMenu(title: "Font", children: [("Sans Serif", TextContent.Font.sans), ("Serif", .serif), ("Monospaced", .mono)].map { name, f in
            UIAction(title: name) { [weak self] _ in self?.restyle { $0.font = f } }
        })
        let aligns = UIMenu(title: "Alignment", children: [
            ("Start", "text.alignleft", TextContent.Alignment.start), ("Center", "text.aligncenter", .center),
            ("End", "text.alignright", .end),
        ].map { name, image, a in
            UIAction(title: name, image: UIImage(systemName: image)) { [weak self] _ in self?.restyle { $0.align = a == .start ? nil : a } }
        })
        let directions = UIMenu(title: "Direction", children: [
            ("Automatic", TextContent.Direction.auto), ("Left to Right", .ltr), ("Right to Left", .rtl),
        ].map { name, d in
            UIAction(title: name) { [weak self] _ in self?.restyle { $0.dir = d == .auto ? nil : d } }
        })
        bar.items = [
            toggle("bold", "Bold", .bold), toggle("italic", "Italic", .italic), toggle("underline", "Underline", .underline),
            toggle("strikethrough", "Strikethrough", .strikethrough),
            UIBarButtonItem(title: "Size", image: UIImage(systemName: "textformat.size"), menu: sizes),
            UIBarButtonItem(title: "Colour", image: UIImage(systemName: "paintpalette"), menu: colours),
            UIBarButtonItem(title: "Font", image: UIImage(systemName: "textformat"), menu: fonts),
            UIBarButtonItem(title: "Alignment", image: UIImage(systemName: "text.alignleft"), menu: aligns),
            UIBarButtonItem(title: "Direction", image: UIImage(systemName: "arrow.left.arrow.right"), menu: directions),
            .flexibleSpace(),
            UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.endEditing() }),
        ]
        bar.sizeToFit()
        return bar
    }

    /// Applies a style change to the selection, or to what is typed next.
    func apply(_ change: TextBoxEditing.Change) {
        guard let tv = textView, var session else { return }
        let range = tv.selectedRange
        if range.length > 0 {
            let selected = tv.selectedRange
            tv.attributedText = TextBoxEditing.applying(change, to: tv.attributedText, range: range, style: session.style)
            tv.selectedRange = selected
        } else {
            if tv.attributedText.length == 0 {
                // An empty box: the change is the box's own style.
                if case .size(let s) = change { session.style.size = s }
                if case .color(let c) = change { session.style.color = c }
                self.session = session
            }
            let on = !TextBoxEditing.isOn(change, in: tv.attributedText, range: range, typing: tv.typingAttributes)
            tv.typingAttributes = TextBoxEditing.apply(change, on: on, to: tv.typingAttributes, style: session.style)
        }
        self.session?.dirty = true
        layoutTextView()
    }

    /// Changes the box's own style (font, alignment, direction).
    func restyle(_ change: (inout TextBoxEditing.BoxStyle) -> Void) {
        guard let tv = textView, var session else { return }
        let old = session.style
        change(&session.style)
        guard session.style != old else { return }
        let selected = tv.selectedRange
        tv.attributedText = TextBoxEditing.restyled(tv.attributedText, from: old, to: session.style)
        tv.typingAttributes = TextBoxEditing.typingAttributes(session.style)
        tv.selectedRange = selected
        session.dirty = true
        self.session = session
        layoutTextView()
    }
}

/// Where text boxes go and what the style bar offers (pure, tested).
enum TextBoxPlacement {
    /// Sizes in the size menu.
    static let sizes: [Double] = [10, 12, 14, 16, 18, 24, 32, 48, 72]
    /// Colours in the colour menu.
    static let colours: [(name: String, color: Sempere.Color)] = [
        ("Black", Sempere.Color(r: 0x1A, g: 0x1A, b: 0x1A)), ("Grey", Sempere.Color(r: 0x80, g: 0x80, b: 0x80)),
        ("Red", Sempere.Color(r: 0xD3, g: 0x2F, b: 0x2F)), ("Orange", Sempere.Color(r: 0xEF, g: 0x6C, b: 0x00)),
        ("Green", Sempere.Color(r: 0x2E, g: 0x7D, b: 0x32)), ("Blue", Sempere.Color(r: 0x15, g: 0x65, b: 0xC0)),
        ("Purple", Sempere.Color(r: 0x6A, g: 0x1B, b: 0x9A)),
    ]
    /// Room kept to the page's right edge.
    static let margin = 16.0
    /// Width of a new box, at most (page points).
    static let newBoxWidth = 320.0
    /// Narrowest new box.
    static let minimumWidth = 60.0

    /// A new box's frame for a tap at `p`: its first line there (the tap is
    /// on the line's middle), as wide as `newBoxWidth` or up to the page's
    /// margin, at least `minimumWidth`, one line tall.
    static func newFrame(at p: ItemFrames.Point, pageWidth: Double, size: Double) -> Rect {
        let lineHeight = 1.2 * size
        let room = pageWidth - margin - p.x
        let w = max(minimumWidth, min(newBoxWidth, room.isFinite ? room : 0))
        let x = min(p.x, max(0, pageWidth - w))
        return Rect(x: InkJSON.round3(max(0, x)), y: InkJSON.round3(max(0, p.y - lineHeight / 2)), w: InkJSON.round3(w),
                    h: InkJSON.round3(lineHeight))
    }

    /// The text box a tap at `p` lands on (topmost, with the selection's slop).
    static func textBox(at p: ItemFrames.Point, in items: [Item], zoom: Double) -> Item? {
        let texts = items.filter { $0.kind == .text && $0.text != nil }
        return ItemFrames.item(at: p, in: texts, slop: ItemSelectionModel.slop / max(zoom, 0.01))
    }
}
