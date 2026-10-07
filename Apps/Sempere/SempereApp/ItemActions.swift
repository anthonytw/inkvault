import Foundation
import Observation
import Sempere

/// Items copied for pasting, in this app only (never the system pasteboard:
/// the plaintext would leave the app). Tied to one open vault: the model
/// empties it when the vault closes or changes keys.
@MainActor
@Observable
final class ItemClipboard {
    /// What was copied: items and the note whose blobs they reference.
    struct Entry: Equatable {
        var note: UUID
        var items: [Item]
    }

    private(set) var entry: Entry?
    /// Pastes since the last copy, so repeated pastes do not stack exactly.
    @ObservationIgnored private(set) var pasteCount = 0

    func copy(_ items: [Item], from note: UUID) {
        let usable = items.filter { $0.validationError == nil }
        entry = usable.isEmpty ? nil : Entry(note: note, items: usable)
        pasteCount = 0
    }

    func clear() {
        entry = nil
        pasteCount = 0
    }

    /// The offset of the next paste: on the same page as the copy, each
    /// paste lands 20 points further down and right.
    func nextOffset(samePage: Bool) -> Double {
        pasteCount += 1
        return samePage ? Double(pasteCount) * 20 : 0
    }
}

/// Item gestures with undo: each change is one delta through the editor and
/// one step on `undoManager` (the canvas's, so the system undo gestures and
/// ⌘Z reach it). Undoing a delete puts the items back under new ids
/// (`NoteEditor.restoreItems`); redoing deletes those.
@MainActor
final class ItemActions {
    let editor: NoteEditor
    weak var undoManager: UndoManager?

    init(editor: NoteEditor, undoManager: UndoManager?) {
        self.editor = editor
        self.undoManager = undoManager
    }

    /// Moves or resizes an item to `frame`.
    func setFrame(_ id: UUID, to frame: Rect, on page: UUID, name: String = "Move") {
        guard let old = editor.setItemFrame(id, to: frame, on: page) else { return }
        register(name) { $0.setFrame(id, to: old, on: page, name: name) }
    }

    /// Sets a text box's text and frame (an edit in its editor).
    func setText(_ id: UUID, to content: TextContent, frame: Rect, on page: UUID) {
        guard let old = editor.setItemText(id, to: content, frame: frame, on: page) else { return }
        register("Typing") { $0.setText(id, to: old.content, frame: old.frame, on: page) }
    }

    /// Adds a new text box. Returns it (nil for an empty one).
    @discardableResult
    func addText(_ content: TextContent, frame: Rect, on page: UUID) -> Item? {
        guard let item = editor.addTextBox(content, frame: frame, on: page) else { return nil }
        return added([item], on: page, name: "Add Text").first
    }

    /// Deletes items. Returns the ones deleted.
    @discardableResult
    func delete(_ ids: [UUID], on page: UUID) -> [Item] {
        let gone = editor.removeItems(ids, from: page)
        guard !gone.isEmpty else { return [] }
        register("Delete") { $0.restore(gone, on: page) }
        return gone
    }

    /// Puts deleted items back (as undo does). Returns the new items.
    @discardableResult
    func restore(_ items: [Item], on page: UUID) -> [Item] {
        let back = editor.restoreItems(items, on: page)
        guard !back.isEmpty else { return [] }
        register("Delete") { $0.delete(back.map(\.id), on: page) }
        return back
    }

    /// Duplicates items on their page. Returns the copies.
    @discardableResult
    func duplicate(_ ids: [UUID], on page: UUID) -> [Item] {
        added(editor.duplicateItems(ids, on: page), on: page, name: "Duplicate")
    }

    /// Draws an item above the others of its layer.
    func bringToFront(_ id: UUID, on page: UUID) {
        guard let old = editor.bringItemToFront(id, on: page) else { return }
        register("Bring to Front") { $0.setZ(id, to: old, on: page) }
    }

    /// Sets an item's order key (undo and redo of `bringToFront`).
    func setZ(_ id: UUID, to z: String, on page: UUID) {
        guard let now = editor.item(id, on: page)?.z, editor.setItemZ(id, to: z, on: page) else { return }
        register("Bring to Front") { $0.setZ(id, to: now, on: page) }
    }

    /// Pastes the clipboard onto the page (copying blobs from another note
    /// first). Returns the new items.
    @discardableResult
    func paste(_ entry: ItemClipboard.Entry, on page: UUID, offset: Double,
               prepare: @escaping @Sendable (BlobRef) async throws -> Void = { _ in }) async throws -> [Item] {
        let pasted = try await editor.pasteItems(entry.items, from: entry.note, on: page, dx: offset, dy: offset,
                                                 prepare: prepare)
        return added(pasted, on: page, name: "Paste")
    }

    /// Registers the undo of adding `items` (removing them; redo restores).
    @discardableResult
    func added(_ items: [Item], on page: UUID, name: String) -> [Item] {
        guard !items.isEmpty else { return [] }
        register(name) { actions in
            let gone = actions.editor.removeItems(items.map(\.id), from: page)
            guard !gone.isEmpty else { return }
            actions.register(name) { $0.added($0.editor.restoreItems(gone, on: page), on: page, name: name) }
        }
        return items
    }

    /// One undo step: `body` runs on the main actor with this object.
    func register(_ name: String, _ body: @escaping @MainActor @Sendable (ItemActions) -> Void) {
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { body(target) }
        }
        undoManager?.setActionName(name)
    }
}
