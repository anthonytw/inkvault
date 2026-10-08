import Sempere
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// How a notebook row in the sidebar starts a drag.
///
/// A drag the sidebar `List` starts itself (SwiftUI's `onDrag` or `draggable`
/// on one of its rows) is handled by the list's collection view while it stays
/// over that list: the rows' drop delegates are never asked (TestFlight build
/// 7: a notebook dropped on another did nothing; `SidebarDropUITests`' trace
/// shows the drag begin and no row validate it, on the iPad and the Mac).
/// Notes dragged in from the note list (another collection view) reach the
/// rows. So a notebook row starts its drag from a `UIDragInteraction` of its
/// own (`uikit`), which the list does not own. That view also carries the
/// row's context menu (`UIContextMenuInteraction`): UIKit coordinates a long
/// press between a drag and a menu only when both are on one view; with
/// SwiftUI's `contextMenu` on the row the menu took the long press on the
/// iPad and the drag never reached a row. `SidebarDropUITests` tries every
/// style (`SEMPERE_DEBUG_NOTEBOOK_DRAG` picks one in debug builds) and
/// requires the shipped one to work.
enum NotebookDragStyle: String, CaseIterable, Sendable {
    /// SwiftUI's `onDrag` on the row.
    case onDrag
    /// A `UIDragInteraction` on a view over the row: the session is not the list's own.
    case uikit
    /// SwiftUI's `draggable` / `dropDestination` (Transferable).
    case transferable

    static let shipped: NotebookDragStyle = .uikit

    static var current: NotebookDragStyle {
        #if DEBUG
        if let v = ProcessInfo.processInfo.environment["SEMPERE_DEBUG_NOTEBOOK_DRAG"], let s = NotebookDragStyle(rawValue: v) {
            return s
        }
        #endif
        return shipped
    }
}

/// A notebook dragged with the Transferable APIs (`NotebookDragStyle.transferable`).
struct NotebookTransfer: Codable, Transferable, Sendable {
    var path: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sempereNotebook)
    }
}

/// One entry of a notebook row's context menu.
struct NotebookRowAction: Identifiable, Sendable {
    let title: String
    let systemImage: String
    let perform: @MainActor @Sendable () -> Void
    var id: String { title }
}

extension View {
    /// Makes a sidebar notebook row draggable (dropped on another notebook it
    /// nests there; on All Notes it goes to the top level) with `menu` as its
    /// context menu, in the current `NotebookDragStyle`.
    func notebookDragSource(_ path: String, menu: [NotebookRowAction]) -> some View {
        modifier(NotebookDragSourceModifier(path: path, menu: menu))
    }
}

private struct NotebookDragSourceModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let path: String
    let menu: [NotebookRowAction]

    func body(content: Content) -> some View {
        switch NotebookDragStyle.current {
        case .onDrag:
            content
                .onDrag { model.beginDrag(.notebook(path), provider: DragPayload.notebook(path).provider()) }
                .contextMenu { menuButtons }
        case .uikit:
            // Leaves the trailing disclosure chevron to the row.
            content.overlay(alignment: .leading) {
                GeometryReader { geo in
                    UIKitDragHandle(model: model, path: path, menu: menu)
                        .frame(width: max(0, geo.size.width - 44), height: geo.size.height)
                }
            }
        case .transferable:
            content.draggable(NotebookTransfer(path: path)).contextMenu { menuButtons }
        }
    }

    @ViewBuilder private var menuButtons: some View {
        ForEach(menu) { action in
            Button(action.title, systemImage: action.systemImage) { action.perform() }
        }
    }
}

/// A clear view over a notebook row (`NotebookDragStyle.uikit`) whose
/// `UIDragInteraction` starts the notebook's drag and whose
/// `UIContextMenuInteraction` shows the row's menu (one view, so UIKit
/// arbitrates the long press: the menu, then a drag when the finger moves).
/// Taps go through to the row (the list's selection is the collection view's).
private struct UIKitDragHandle: UIViewRepresentable {
    let model: AppModel
    let path: String
    let menu: [NotebookRowAction]

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let drag = UIDragInteraction(delegate: context.coordinator)
        drag.isEnabled = true
        view.addInteraction(drag)
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.path = path
        context.coordinator.menu = menu
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, path: path, menu: menu) }

    @MainActor
    final class Coordinator: NSObject, UIDragInteractionDelegate, UIContextMenuInteractionDelegate {
        let model: AppModel
        var path: String
        var menu: [NotebookRowAction]

        init(model: AppModel, path: String, menu: [NotebookRowAction]) {
            self.model = model
            self.path = path
            self.menu = menu
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            let actions = menu
            guard !actions.isEmpty else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(children: actions.map { action in
                    UIAction(title: action.title, image: UIImage(systemName: action.systemImage)) { _ in
                        MainActor.assumeIsolated { action.perform() }
                    }
                })
            }
        }

        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
            let provider = model.beginDrag(.notebook(path), provider: DragPayload.notebook(path).provider())
            let item = UIDragItem(itemProvider: provider)
            item.localObject = path
            return [item]
        }

        func dragInteraction(_ interaction: UIDragInteraction, sessionAllowsMoveOperation session: UIDragSession) -> Bool {
            true
        }
    }
}
