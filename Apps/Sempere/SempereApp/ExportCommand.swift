import SempereRender
import SwiftUI

/// The export actions, in one place: the note list's toolbar and context menu,
/// the note's toolbar and the Catalyst menu bar all build their items from
/// this type, so a title, icon or shortcut changes once.
enum ExportCommand: String, CaseIterable, Identifiable, Sendable {
    case pdf, png, markdown, html

    var id: String { rawValue }

    var format: ShareFormat {
        switch self {
        case .pdf: return .pdf
        case .png: return .png
        case .markdown: return .markdown
        case .html: return .html
        }
    }

    /// The menu item's title ("Export as PDF…").
    var title: String {
        switch self {
        case .pdf: return "PDF…"
        case .png: return "PNG Pages…"
        case .markdown: return "Markdown (Obsidian)…"
        case .html: return "HTML…"
        }
    }

    var systemImage: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .png: return "photo.on.rectangle"
        case .markdown: return "text.document"
        case .html: return "safari"
        }
    }

    /// The submenu's title.
    static let menuTitle = "Export"
    static let menuImage = "square.and.arrow.up"
}

/// "Export ▸ PDF…, PNG Pages…, Markdown…, HTML…" for `ids` (the notes, in the
/// order given). Disabled without notes.
struct ExportMenu: View {
    @Environment(AppModel.self) private var model
    let ids: [UUID]

    var body: some View {
        Menu(ExportCommand.menuTitle, systemImage: ExportCommand.menuImage) {
            ForEach(ExportCommand.allCases) { command in
                Button(command.title, systemImage: command.systemImage) {
                    model.requestExport(command, ids: ids)
                }
            }
        }
        .disabled(ids.isEmpty || model.phase != .unlocked)
    }
}

/// The same actions in the Mac menu bar (Catalyst), for the notes the list has
/// selected (`AppModel.exportTargetIDs`).
struct ExportMenuCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Menu(ExportCommand.menuTitle) {
                ForEach(ExportCommand.allCases) { command in
                    Button(command.title) { model.requestExport(command, ids: model.exportTargetIDs) }
                        .disabled(model.exportTargetIDs.isEmpty || model.phase != .unlocked)
                }
            }
        }
    }
}
