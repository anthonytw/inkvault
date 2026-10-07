import Foundation
import Sempere
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Notes dragged inside the app (their ids; declared in `SempereInfo.plist`).
    static let sempereNotes = UTType(exportedAs: "io.github.anthonytw.sempere.notes", conformingTo: .data)
    /// A notebook dragged inside the app (its path).
    static let sempereNotebook = UTType(exportedAs: "io.github.anthonytw.sempere.notebook", conformingTo: .data)
}

/// What a drag inside the app carries. Registered with `.ownProcess`
/// visibility only: ids and paths never go to another app.
enum DragPayload: Equatable, Sendable {
    case notes([UUID])
    case notebook(String)

    /// Most ids or path bytes decoded from a drop (a hostile provider cannot make us read more).
    static let maxNotes = 100_000
    static let maxPathBytes = 4096

    var type: UTType {
        switch self {
        case .notes: return .sempereNotes
        case .notebook: return .sempereNotebook
        }
    }

    var data: Data {
        switch self {
        case .notes(let ids): return (try? JSONEncoder().encode(ids.map { $0.uuidString.lowercased() })) ?? Data()
        case .notebook(let path): return Data(path.utf8)
        }
    }

    /// The payload in `data`, nil when it is empty or malformed.
    static func decode(_ data: Data, as type: UTType) -> DragPayload? {
        if type == .sempereNotes {
            guard data.count <= maxNotes * 48,   // a quoted uuid and a comma are 40 bytes
                  let names = try? JSONDecoder().decode([String].self, from: data), names.count <= maxNotes else { return nil }
            let ids = names.compactMap { UUID(uuidString: $0) }
            return ids.isEmpty ? nil : .notes(ids)
        }
        if type == .sempereNotebook {
            guard data.count <= maxPathBytes, let path = String(data: data, encoding: .utf8),
                  let canonical = NotebookPath.canonical(path) else { return nil }
            return .notebook(canonical)
        }
        return nil
    }

    /// An item provider for a drag: the payload for this app only, plus whatever `extra` registers.
    func provider(extra: (NSItemProvider) -> Void = { _ in }) -> NSItemProvider {
        let provider = NSItemProvider()
        let bytes = data
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(bytes, nil)
            return nil
        }
        extra(provider)
        return provider
    }
}

/// Where a drop lands in the sidebar: a notebook, or the top level (the
/// "All Notes" row).
enum DropTarget: Hashable, Sendable {
    case topLevel
    case notebook(String)

    /// The target a sidebar row stands for; nil for rows that take no drops
    /// (tags, Recently Deleted, Recently Recognized).
    init?(_ item: SidebarItem) {
        switch item {
        case .allNotes: self = .topLevel
        case .notebook(let path): self = NotebookPath.canonical(path).map(DropTarget.notebook) ?? .topLevel
        case .tag, .deleted, .recentlyRecognized: return nil
        }
    }

    /// The notebook path notes dropped here get; nil: none.
    var path: String? {
        if case .notebook(let p) = self { return NotebookPath.canonical(p) }
        return nil
    }
}

/// The rules of dropping notes and notebooks on the sidebar (pure, tested).
enum SidebarDrop {
    /// Whether `payload` dropped on `target` would change something and is allowed.
    ///
    /// - Notes: allowed when at least one of them (live ones only; ids not in `notes` are
    ///   ignored, they may not be listed yet) is not in that notebook already.
    /// - A notebook: allowed when it can move there (never into itself or a
    ///   notebook inside it, `NotebookPath.moved`) and is not there already.
    static func accepts(_ payload: DragPayload, on target: DropTarget, notes: [NoteSummary]) -> Bool {
        switch payload {
        case .notes(let ids):
            let wanted = Set(ids)
            return notes.contains { wanted.contains($0.id) && !$0.deleted && NotebookPath.canonical($0.notebook) != target.path }
        case .notebook(let path):
            guard let moved = NotebookPath.moved(path, into: target.path) else { return false }
            return moved != NotebookPath.canonical(path)
        }
    }

    /// The undo menu title of a drop.
    static func actionName(_ payload: DragPayload) -> String {
        switch payload {
        case .notes(let ids): return ids.count == 1 ? "Move Note" : "Move Notes"
        case .notebook: return "Move Notebook"
        }
    }
}

/// Where the notes were before a move, to put them back (undo).
struct NotebookMoveRecord: Equatable, Sendable {
    var previous: [UUID: String?]
    var actionName: String
}

/// The delegate of one sidebar row: validates and highlights while a drag is over it,
/// and makes the move (one commit) when it is dropped.
///
/// A drag started in the app (every drag of these types: their providers are
/// `.ownProcess`) is moved from the model's `draggedPayload`, never from the
/// item provider: on iPadOS 26 the provider `onDrag` returns can be released
/// before the drop (TestFlight build 6: releasing over a notebook did nothing).
/// The model holds the provider too (`beginDrag`); decoding it is only the
/// fallback for a drag the model does not know.
@MainActor
struct SidebarDropDelegate: DropDelegate {
    let model: AppModel
    let target: DropTarget
    /// The undo manager of the window the row is in: the drop's undo goes there.
    let undoManager: UndoManager?

    private static let types: [UTType] = [.sempereNotes, .sempereNotebook]

    func validateDrop(info: DropInfo) -> Bool {
        model.draggedPayload != nil || info.hasItemsConforming(to: Self.types)
    }

    func dropEntered(info: DropInfo) { model.setDropTarget(model.acceptsDrop(on: target) ? target : nil) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let allowed = model.acceptsDrop(on: target)
        model.setDropTarget(allowed ? target : nil)
        return DropProposal(operation: allowed ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) {
        if model.dropTarget == target { model.setDropTarget(nil) }
    }

    func performDrop(info: DropInfo) -> Bool {
        model.setDropTarget(nil)
        let model = model, target = target, undo = UndoBox(undoManager)
        if model.draggedPayload != nil {
            guard let payload = model.takeDrop(on: target) else { return false }
            Task { @MainActor in await model.move(payload, to: target, undoManager: undo.manager) }
            return true
        }
        for type in Self.types {
            guard let provider = info.itemProviders(for: [type]).first else { continue }
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                let payload = data.flatMap { DragPayload.decode($0, as: type) }
                Task { @MainActor in
                    model.endDrag()
                    guard let payload else { return }
                    await model.move(payload, to: target, undoManager: undo.manager)
                }
            }
            return true
        }
        return false
    }
}

/// Carries a window's undo manager across an item provider's callback (it is
/// only read on the main actor); weak, so a closed window's is not kept.
private final class UndoBox: @unchecked Sendable {
    weak var manager: UndoManager?
    init(_ manager: UndoManager?) { self.manager = manager }
}

extension View {
    /// Makes a sidebar row take dropped notes and notebooks, highlighted while a drag over it would be accepted.
    func sidebarDropTarget(_ item: SidebarItem) -> some View {
        modifier(SidebarDropRow(item: item))
    }
}

private struct SidebarDropRow: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let item: SidebarItem

    func body(content: Content) -> some View {
        if let target = DropTarget(item) {
            let highlighted = model.dropTarget == target
            content
                .background(highlighted ? SwiftUI.Color.accentColor.opacity(0.25) : SwiftUI.Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if highlighted { RoundedRectangle(cornerRadius: 8).stroke(SwiftUI.Color.accentColor, lineWidth: 2) }
                }
                .onDrop(of: [.sempereNotes, .sempereNotebook],
                        delegate: SidebarDropDelegate(model: model, target: target, undoManager: undoManager))
        } else {
            content
        }
    }
}
