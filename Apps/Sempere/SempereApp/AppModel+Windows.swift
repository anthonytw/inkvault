import Foundation
import Sempere
import SempereRender

/// Note windows (Mac): one note per window, each with its own `NoteEditor`.
///
/// The vault, the device clock and the edit gate stay the model's, shared by
/// every window, so a delta from any window ticks the one clock. A note has
/// at most one editor at a time: while a window shows a note (`claimNote`),
/// the library window's detail pane does not open an editor for it (two
/// editors on one note would each keep their own stroke ledger and write
/// diverging deltas); it shows a placeholder instead.
extension AppModel {

    /// Takes `noteID` for a note window: an editor the library window has open
    /// on it is saved and closed first.
    func claimNote(_ noteID: UUID) async {
        windowClaims.insert(noteID)
        if editor?.noteID == noteID {
            try? await openEditor(for: nil)
        }
    }

    /// Gives `noteID` back (its window closed): saves and closes the window's
    /// editor; the library window opens it again if it is selected. The claim
    /// ends only once the last save is written, so the library never reads
    /// the note before it (and stays if a window took the note again meanwhile).
    func releaseNote(_ noteID: UUID) async {
        let editor = windowEditors.removeValue(forKey: noteID)
        await editor?.close()
        if windowEditors[noteID] == nil { windowClaims.remove(noteID) }
    }

    /// Opens the editor of a note window. Needs an unlocked vault. A second
    /// call for the same note returns the editor already open.
    func openWindowNote(_ noteID: UUID) async throws -> NoteEditor {
        if let open = windowEditors[noteID] { return open }
        guard !isChangingKeys else { throw CancellationError() }   // reopened after the change (`keyEpoch`)
        let gen = generation
        let epoch = keyEpoch
        await closingEditor?.value
        try ensureCurrent(gen)
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        guard notes.contains(where: { $0.id == noteID }) else { throw ModelError.noteNotFound }
        try await downloadNote(noteID)
        let clock = try deviceClockForWriting()
        var verify: (@Sendable () throws -> Void)?
        if isCloudVault, let url = vaultURL {
            let hooks = cloudHooks
            verify = { try CloudVault.requireLocal(note: noteID, vault: url, hooks: hooks) }
        }
        let opened = try await NoteEditor.open(vault: vault, noteID: noteID, clock: clock, debounce: editorDebounce,
                                               recognizer: recognizer, recognitionDelay: recognitionDelay,
                                               coordinated: isCloudVault, verify: verify)
        try ensureCurrent(gen)
        if let open = windowEditors[noteID] {   // a concurrent call won
            Task { await opened.close() }
            return open
        }
        // The window closed meanwhile (no claim: the library may open the note
        // itself), or the keys changed under the vault copy it was opened with.
        guard windowClaims.contains(noteID), !Task.isCancelled, !isChangingKeys, epoch == keyEpoch else {
            Task { await opened.close() }
            throw CancellationError()
        }
        opened.onRecognized = { [weak self] id in
            guard let self else { return }
            Task { try? await self.refresh([id]) }   // search sees the new text
        }
        windowEditors[noteID] = opened
        return opened
    }

    /// Reloads a note window's editor after the note was deleted or restored
    /// (it opens read-only or editable); pending ink is saved first.
    func reopenWindowNote(_ noteID: UUID) async {
        guard let old = windowEditors.removeValue(forKey: noteID) else { return }
        await old.close()
        _ = try? await openWindowNote(noteID)
    }

    /// Saves and closes every note window's editor (the vault is about to
    /// change under them, `AppModel+Keys`).
    func closeWindowEditors() async {
        let all = Array(windowEditors.values)
        windowEditors = [:]
        for editor in all { await editor.close() }
    }

    /// Whether a note window should open a library window now: none is on
    /// screen and none was asked for in the last few seconds (several note
    /// windows restored at launch each ask, before the first one appears).
    func shouldOpenLibraryWindow(now: Date = Date()) -> Bool {
        guard libraryWindowCount == 0 else { return false }
        if let last = libraryWindowRequested, now.timeIntervalSince(last) < 5 { return false }
        libraryWindowRequested = now
        return true
    }

    // MARK: - State restoration

    /// Applies a selection saved with the library window (`RestorableSelection`):
    /// its notebook or tag if the vault still has it (else All Notes), and its
    /// note if the vault still has it. Ignored for another vault.
    @discardableResult
    func restore(_ saved: RestorableSelection) -> Bool {
        guard phase == .unlocked, saved.vault == vault?.vaultId else { return false }
        var item = saved.sidebarItem
        switch item {
        case .notebook(let path):
            let wanted = NotebookPath.canonical(path)
            if !notebooks.contains(where: { NotebookPath.canonical($0) == wanted }) { item = .allNotes }
        case .tag(let tag):
            if !tags.contains(where: { NoteOps.tagKey($0) == NoteOps.tagKey(tag) }) { item = .allNotes }
        case .allNotes, .deleted:
            break
        }
        sidebarSelection = item
        if let id = saved.note, notes.contains(where: { $0.id == id }) { selectedNoteID = id }
        return true
    }

    // MARK: - PDF export

    enum ExportError: Error, Equatable, CustomStringConvertible {
        case unreadableRevisions(Int)

        var description: String {
            switch self {
            case .unreadableRevisions(let n):
                return "\(n) revision(s) of this note could not be read, so it cannot be exported completely."
            }
        }
    }

    /// Renders a note to a PDF in a fresh folder under the temporary
    /// directory and returns its URL (named after the title, `ExportFileName`).
    /// Pending ink of the note, wherever it is open, is saved first so the PDF
    /// shows what is on screen. The file is plaintext: it is for the Finder
    /// drop that asked for it, and `NotePDFExport.purge` removes it later.
    func exportPDF(noteID: UUID) async throws -> URL {
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        let gen = generation
        if editor?.noteID == noteID { await editor?.flush() }
        await windowEditors[noteID]?.flush()
        try ensureCurrent(gen)
        try await downloadNote(noteID)
        try ensureCurrent(gen)
        let coordinate = coordinationURL
        let rendered = try await offMain {
            try CloudVault.coordinatedRead(coordinate) { try NotePDFExport.render(vault: vault, noteID: noteID) }
        }
        try ensureCurrent(gen)
        NotePDFExport.purge(olderThan: 3600)   // folders of earlier runs that never closed a vault
        return try NotePDFExport.write(rendered, in: exportFolder)
    }
}

/// Rendering a note to a PDF file outside the vault (Mac drag and drop).
enum NotePDFExport {
    struct Rendered: Sendable {
        var title: String
        var pdf: Data
    }

    /// The note's PDF. A note with unreadable revisions is refused rather
    /// than exported with pages missing.
    static func render(vault: Vault, noteID: UUID) throws -> Rendered {
        let loaded = try vault.loadNote(noteID)
        guard loaded.failures.isEmpty else { throw AppModel.ExportError.unreadableRevisions(loaded.failures.count) }
        let state = try NoteReducer.reconstruct(loaded.revisions)
        return Rendered(title: state.meta.title, pdf: try PDFWriter.render(note: state))
    }

    /// Folder under the temporary directory holding exported files, one
    /// sub-folder per export so equal titles never collide.
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SempereExport", isDirectory: true)
    }

    /// Writes `rendered` to `<folder>/<uuid>/<title>.pdf`, old exports removed first.
    static func write(_ rendered: Rendered, in folder: URL = NotePDFExport.folder) throws -> URL {
        purge(in: folder)
        let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(ExportFileName.pdf(title: rendered.title))
        try rendered.pdf.write(to: url, options: .atomic)
        return url
    }

    /// Removes exports older than `age` seconds (all of them with 0).
    static func purge(in folder: URL = NotePDFExport.folder, olderThan age: TimeInterval = 600, now: Date = Date()) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if age <= 0 || modified.map({ now.timeIntervalSince($0) > age }) ?? true {
                try? fm.removeItem(at: entry)
            }
        }
    }
}
