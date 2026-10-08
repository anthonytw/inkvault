import Foundation
import Sempere
import SempereImport
import UniformTypeIdentifiers

/// What a Notability import did, for the alert after it.
struct NotabilityImportSummary: Equatable, Sendable {
    var imported = 0
    var skipped = 0
    var failed = 0
    /// Source names (file names, never note content) of the notes that failed, with why.
    var failures: [String] = []
    /// Nothing to import was found in what was picked.
    var nothingFound = false

    init(_ report: NotabilityImporter.ImportReport) {
        imported = report.imported
        skipped = report.skipped
        failed = report.failed
        nothingFound = report.notes.isEmpty
        failures = report.notes.compactMap { note in
            guard case .failed(let why) = note.status else { return nil }
            return "\((note.source as NSString).lastPathComponent): \(why)"
        }
    }

    var title: String { failed > 0 ? "Import Finished with Errors" : "Notability Import" }

    var message: String {
        if nothingFound { return "No Notability notes (.note or .ntb files, or a zip of them) were found in what you picked." }
        var lines = ["\(imported) note\(imported == 1 ? "" : "s") imported."]
        if skipped > 0 {
            lines.append("\(skipped) skipped (already in the vault, or a copy of a note imported from another file).")
        }
        if failed > 0 {
            lines.append("\(failed) failed:")
            lines += failures.prefix(5)
            if failures.count > 5 { lines.append("…and \(failures.count - 5) more.") }
        }
        return lines.joined(separator: "\n")
    }
}

/// Notability notes and backups into the open vault: the importer the CLI
/// runs (`sempere import notability`, `NotabilityImporter.import`) with its
/// defaults (folder names become tags, attachments imported, image metadata
/// stripped, notes already in the vault skipped), PDF page text from PDFKit.
extension AppModel {
    /// What the importer reads: `.note` and `.ntb` files, folders of them and
    /// zips (Notability's backup; pick every part of a split one).
    static var notabilityTypes: [UTType] {
        var types: [UTType] = [.zip, .folder]
        for ext in ["note", "ntb"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    /// Imports `urls` (security-scoped, from the file picker) into the open
    /// vault, filing every note under `notebook` (nil: Notability's subject).
    ///
    /// Writes through the model's one `DeviceClock` (`withClock`) under the
    /// edit gate, like every other write; in iCloud Drive the writes are one
    /// coordinated write on `notes/`. Existing notes are never overwritten,
    /// so no open editor's note changes. The result is in `notabilitySummary`.
    func importNotability(_ urls: [URL], notebook: String?) async throws {
        guard !urls.isEmpty else { return }
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        try requireWritableVault()   // format.md §7.3
        guard !isImportingNotability else { return }
        isImportingNotability = true
        defer { isImportingNotability = false }
        let gen = generation
        await editGate.acquire()
        defer { editGate.release() }
        try ensureCurrent(gen)
        let clock = try deviceClockForWriting()
        let device = clock.device
        let notes = isCloudVault ? vault.url.appendingPathComponent("notes", isDirectory: true) : nil
        let options = NotabilityImporter.Options(notebook: NotebookPath.canonical(notebook), app: NoteWriter.appName,
                                                 pdfText: PDFKitTextExtractor())
        let scoped = urls.map { $0.startAccessingSecurityScopedResource() }
        defer { for (url, s) in zip(urls, scoped) where s { url.stopAccessingSecurityScopedResource() } }
        let report = try await clock.withClock(save: true) { c in
            try CloudVault.coordinatedWrite(notes) {
                try NotabilityImporter.import(paths: urls, into: vault, device: device, clock: &c, options: options)
            }
        }
        try ensureCurrent(gen)
        let written = report.notes.filter { $0.status == .ok }.compactMap(\.noteId)
        if !written.isEmpty { try await refresh(written) }
        notabilitySummary = NotabilityImportSummary(report)
    }
}
