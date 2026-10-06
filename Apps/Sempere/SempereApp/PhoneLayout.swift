import Foundation
import SwiftUI

/// The iPhone is a reader: the three-column split view collapses into one
/// stack (vault, notebooks and tags, note list, note), and a note opens
/// read-first. Everything here is gated on `Platform.isPhone`; the iPad and
/// the Mac keep their layouts. The decisions are plain values so tests can
/// pin them without a view.
enum CompactNavigation {
    /// What going back in the stack leaves selected. A `List(selection:)` pushes
    /// only when its selection *changes*, so a row that stays selected after a
    /// pop could not be tapped again: popping clears the selection of the
    /// column that was left.
    struct Clear: Equatable {
        var note = false
        var sidebar = false
    }

    /// The selections to drop once the stack shows `column`.
    static func clear(whenShowing column: NavigationSplitViewColumn) -> Clear {
        switch column {
        case .detail: return Clear()
        case .content: return Clear(note: true)
        default: return Clear(note: true, sidebar: true)
        }
    }

    /// The column a selection asks for: a note opens the note, a sidebar item
    /// (with no note) the list. Nil: stay where the stack is.
    static func column(note: UUID?, sidebar: SidebarItem?, current: NavigationSplitViewColumn) -> NavigationSplitViewColumn? {
        if note != nil { return current == .detail ? nil : .detail }
        if sidebar != nil, current == .sidebar { return .content }
        return nil
    }
}

extension AppModel {
    /// The iPhone's stack now shows `column` (a back swipe or button): the
    /// selections of the columns it left are dropped (`CompactNavigation.clear`),
    /// so their rows can be tapped again, and a note left behind is saved and
    /// its editor closed (its view went with the pop, so nothing else closes it).
    func didShowCompactColumn(_ column: NavigationSplitViewColumn) async {
        let clear = CompactNavigation.clear(whenShowing: column)
        if clear.sidebar, sidebarSelection != nil { sidebarSelection = nil }
        if clear.note, selectedNoteID != nil {
            selectedNoteID = nil
            await showSelectedNote()
        }
    }
}

/// Reading mode of the note view on an iPhone: panning, zooming and page
/// navigation first; the pencil button turns on annotation with a finger.
enum PhoneReading {
    /// Whether the canvas takes drawing: always off on a phone until the user
    /// switches annotation on; the iPad and the Mac never suspend it.
    static func drawingSuspended(isPhone: Bool, annotating: Bool) -> Bool {
        isPhone && !annotating
    }

    /// The palette is always the short one on a phone (pen, marker, eraser, lasso).
    static func paletteCompact(isPhone: Bool, stored: Bool) -> Bool {
        isPhone || stored
    }

    /// Back in the note list, annotating starts off for the next note.
    static func annotatingAfterNoteChange() -> Bool { false }

    /// The button below a finite page (`PageExtent.Footer`): Next Page on any
    /// page but the last; Add Page on the last only when the note can be written
    /// and is not being read on an iPhone (a tap while reading must not write).
    static func footer(infinite: Bool, isLast: Bool, readOnly: Bool, drawingSuspended: Bool) -> PageExtent.Footer {
        if infinite { return .none }
        if !isLast { return .nextPage }
        return readOnly || drawingSuspended ? .none : .addPage
    }
}

/// The iPhone App Store sizes in pixels (`docs/appstore/screenshots.md`).
enum PhoneScreenshotSize {
    /// 6.9" displays: iPhone 16/17 Pro Max and iPhone 15 Pro Max / 16 Plus.
    static let accepted: [(width: Int, height: Int)] = [(1320, 2868), (1290, 2796)]
}
