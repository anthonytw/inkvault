import Sempere
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// How a notebook row in the sidebar starts a drag.
///
/// A drag the sidebar `List` starts itself (SwiftUI's `onDrag` on one of its
/// rows) is handled by the list's collection view while it stays over that
/// list: the rows' drop delegates are never asked (TestFlight build 7: a
/// notebook dropped on another did nothing; `SidebarDropUITests`' trace shows
/// the drag begin and no row validate it). Notes dragged in from the note
/// list (another collection view) reach the rows. Which source works is
/// measured by `SidebarDropUITests` (`SEMPERE_DEBUG_NOTEBOOK_DRAG` picks one
/// in debug builds).
enum NotebookDragStyle: String, CaseIterable, Sendable {
    /// SwiftUI's `onDrag` on the row.
    case onDrag
    /// A `UIDragInteraction` on a view over the row: the session is not the list's own.
    case uikit
    /// SwiftUI's `draggable` / `dropDestination` (Transferable).
    case transferable

    static let shipped: NotebookDragStyle = .onDrag

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

extension View {
    /// Makes a sidebar notebook row draggable, in the current `NotebookDragStyle`.
    func notebookDragSource(_ path: String) -> some View {
        modifier(NotebookDragSourceModifier(path: path))
    }
}

private struct NotebookDragSourceModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let path: String

    func body(content: Content) -> some View {
        switch NotebookDragStyle.current {
        case .onDrag:
            content.onDrag {
                // Dropped on another notebook it nests there; on All Notes it goes to the top level.
                model.beginDrag(.notebook(path), provider: DragPayload.notebook(path).provider())
            }
        case .uikit:
            // Leaves the trailing disclosure chevron to the row.
            content.overlay(alignment: .leading) {
                GeometryReader { geo in
                    UIKitDragHandle(model: model, path: path)
                        .frame(width: max(0, geo.size.width - 44), height: geo.size.height)
                }
            }
        case .transferable:
            content.draggable(NotebookTransfer(path: path))
        }
    }
}

/// A clear view whose `UIDragInteraction` starts a notebook drag
/// (`NotebookDragStyle.uikit`); taps and the context menu go through to the row.
private struct UIKitDragHandle: UIViewRepresentable {
    let model: AppModel
    let path: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let drag = UIDragInteraction(delegate: context.coordinator)
        drag.isEnabled = true
        view.addInteraction(drag)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.path = path
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, path: path) }

    @MainActor
    final class Coordinator: NSObject, UIDragInteractionDelegate {
        let model: AppModel
        var path: String

        init(model: AppModel, path: String) {
            self.model = model
            self.path = path
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
