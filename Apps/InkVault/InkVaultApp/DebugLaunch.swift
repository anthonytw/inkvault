#if DEBUG
import Age
import Foundation
import InkVault
import UIKit

/// Debug builds only: open a vault, unlock it and show a note straight from
/// launch environment variables, without the folder picker, so a simulator
/// run can be scripted (`xcrun simctl launch` with `SIMCTL_CHILD_` prefixes):
///
/// - `INKVAULT_DEBUG_VAULT`: path of a `.inkvault` folder.
/// - `INKVAULT_DEBUG_IDENTITY`: path of an age identity file.
/// - `INKVAULT_DEBUG_NOTE`: note id (or a unique prefix of it) to open.
/// - `INKVAULT_DEBUG_SCROLL_Y`: page y (points) to scroll the canvas to.
/// - `INKVAULT_DEBUG_ZOOM`: zoom as a multiple of the fit-width zoom.
/// - `INKVAULT_DEBUG_SNAPSHOT`: path to write a PNG of the canvas to, once shown.
///
/// Release builds compile none of this.
enum DebugLaunch {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Expands a leading `~/` to the app's home (its data container), so a
    /// device launch can name files copied in with `devicectl device copy to`.
    static func expand(_ path: String) -> String {
        path.hasPrefix("~/") ? NSHomeDirectory() + "/" + path.dropFirst(2) : path
    }

    /// True when the launch environment names a vault (or asks for the most
    /// recent one, `INKVAULT_DEBUG_RECENT=1`).
    static var isActive: Bool { environment["INKVAULT_DEBUG_VAULT"] != nil || environment["INKVAULT_DEBUG_RECENT"] != nil }

    /// Page y to scroll to after a note opens, if requested.
    static var scrollY: Double? { environment["INKVAULT_DEBUG_SCROLL_Y"].flatMap(Double.init) }

    /// Opens what the environment names; errors land in `model.errorMessage`.
    @MainActor
    static func run(_ model: AppModel, library: VaultLibrary) async {
        let env = environment
        if env["INKVAULT_DEBUG_RECENT"] != nil {
            await runRecent(model, library: library)
            return
        }
        guard let vaultPath = env["INKVAULT_DEBUG_VAULT"] else { return }
        await model.report {
            let url = URL(fileURLWithPath: expand(vaultPath))
            if let keyPath = env["INKVAULT_DEBUG_IDENTITY"] {
                let text = try String(contentsOfFile: expand(keyPath), encoding: .utf8)
                try await model.openVault(at: url)
                try await model.unlock(identityText: text)
            } else {
                try await model.openVault(at: url)
            }
            if let note = env["INKVAULT_DEBUG_NOTE"]?.lowercased(),
               let match = model.notes.first(where: { $0.id.uuidString.lowercased().hasPrefix(note) }) {
                model.selectedNoteID = match.id
            }
        }
    }

    /// Opens the most recent vault through its bookmark, as a relaunch does
    /// (the only way a debug run reaches a vault in iCloud Drive, which needs
    /// the picker's security scope). `INKVAULT_DEBUG_PROBE=1` logs how iCloud
    /// presents the files first, `INKVAULT_DEBUG_EVICT=1` evicts the notes'
    /// files from this device beforehand (they stay in iCloud), and
    /// `INKVAULT_DEBUG_OPEN_ALL=N` opens the first N notes one by one and logs
    /// page and stroke counts (never titles or content). Never draws.
    @MainActor
    static func runRecent(_ model: AppModel, library: VaultLibrary) async {
        let env = environment
        guard let entry = library.recents.first else { DebugProbe.log("no recent vault"); return }
        let clock = ContinuousClock()
        let start = clock.now
        func t() -> String { String(format: "t=%.1fs", Double((clock.now - start).components.attoseconds) / 1e18
                                    + Double((clock.now - start).components.seconds)) }
        do {
            let url = try library.resolve(entry)
            let scoped = url.startAccessingSecurityScopedResource()
            DebugProbe.log("\(t()) recent resolved scoped=\(scoped)")
            if let mode = env["INKVAULT_DEBUG_EVICT"] {
                await Task.detached { DebugProbe.evictNotes(url, mode: mode) }.value
                DebugProbe.log("\(t()) evict done")
            }
            if env["INKVAULT_DEBUG_PROBE"] != nil { await Task.detached { DebugProbe.probe(url, label: "before-open") }.value }
            if scoped { url.stopAccessingSecurityScopedResource() }
            try await model.open(recent: entry, library: library)
            DebugProbe.log("\(t()) opened phase=\(model.phase) cloud=\(model.isCloudVault)")
            guard let keyPath = env["INKVAULT_DEBUG_IDENTITY"] else { return }
            let text = try String(contentsOfFile: expand(keyPath), encoding: .utf8)
            try await model.unlock(identityText: text)
            DebugProbe.log("\(t()) unlocked notes=\(model.notes.count) pending=\(model.pendingNoteIDs.count) "
                           + "placeholders=\(model.placeholderNoteIDs.count) syncing=\(model.cloudSyncTask != nil) "
                           + "sync=\(model.cloudSync.map { "\($0.readyNotes)/\($0.notes)" } ?? "nil")")
            let watch = Int(env["INKVAULT_DEBUG_WATCH"] ?? "") ?? 20
            for _ in 0..<watch {
                try await Task.sleep(for: .seconds(1))
                DebugProbe.log("\(t()) notes=\(model.notes.count) pending=\(model.pendingNoteIDs.count) "
                               + "placeholders=\(model.placeholderNoteIDs.count) "
                               + "sync=[\(model.cloudSync.map { "\($0.readyNotes)/\($0.notes) notes \($0.localFiles)/\($0.files) files bar=\($0.isDownloading) problem=\($0.problem != nil)" } ?? "nil")] error=\(model.errorMessage != nil)")
            }
            if let vault = model.vaultURL, env["INKVAULT_DEBUG_PROBE"] != nil { DebugProbe.probe(vault, label: "after-sync") }
            let n = Int(env["INKVAULT_DEBUG_OPEN_ALL"] ?? "") ?? 0
            var empty = 0, mismatched = 0, opened = 0
            for note in model.visibleNotes.prefix(n) {
                model.selectedNoteID = note.id
                let id = String(note.id.uuidString.prefix(8)).lowercased()
                await model.showSelectedNote()
                if let failure = model.editorFailure { DebugProbe.log("\(t()) \(id) shown failure: \(failure.message)") }
                guard let editor = model.editor else { DebugProbe.log("\(t()) \(id) no editor"); continue }
                opened += 1
                let strokes = editor.pages.reduce(0) { $0 + editor.liveStrokes(of: $1.id).count }
                let summary = model.notes.first { $0.id == note.id }
                if strokes == 0 { empty += 1 }
                if strokes != summary?.strokes { mismatched += 1 }
                DebugProbe.log("\(t()) \(id) pages=\(editor.pages.count) strokes=\(strokes) "
                               + "summaryStrokes=\(summary?.strokes ?? -1) listed=\(note.strokes) "
                               + "readOnly=\(editor.isReadOnly) reason=\(editor.readOnlyReason ?? "none")")
            }
            if n > 0 { DebugProbe.log("\(t()) opened=\(opened) empty=\(empty) mismatched=\(mismatched)") }
            if let pick = env["INKVAULT_DEBUG_NOTE"]?.lowercased(),
               let match = model.notes.first(where: { $0.id.uuidString.lowercased().hasPrefix(pick) }) {
                model.selectedNoteID = match.id
            }
        } catch {
            DebugProbe.log("\(t()) failed: \(error)")
            model.errorMessage = "\(error)"
        }
    }

    /// The first layout of a canvas: applies the requested zoom and scroll,
    /// logs the geometry and writes the snapshot, if asked.
    @MainActor
    static func canvasDidLayOut(_ host: PageCanvasHost) {
        let env = environment
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak host] in
            guard let host else { return }
            let canvas = host.canvas
            if let z = env["INKVAULT_DEBUG_ZOOM"].flatMap(Double.init) {
                canvas.zoomScale = canvas.minimumZoomScale * CGFloat(z)
            }
            canvas.setContentOffset(CGPoint(x: 0, y: CGFloat(scrollY ?? 0) * canvas.zoomScale), animated: false)
            NSLog("InkVaultDebug zoom=%f contentSize=%@ offset=%@ bounds=%@", canvas.zoomScale,
                  NSCoder.string(for: canvas.contentSize), NSCoder.string(for: canvas.contentOffset),
                  NSCoder.string(for: host.bounds))
            NSLog("InkVaultDebug footer=%@ hidden=%d title=%@ frame=%@", "\(host.footer)", host.footerButton.isHidden ? 1 : 0,
                  host.footerButton.configuration?.title ?? "-", NSCoder.string(for: host.footerButton.frame))
            guard let path = env["INKVAULT_DEBUG_SNAPSHOT"] else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak host] in
                guard let host else { return }
                let image = UIGraphicsImageRenderer(bounds: host.bounds).image { _ in
                    host.drawHierarchy(in: host.bounds, afterScreenUpdates: true)
                }
                try? image.pngData()?.write(to: URL(fileURLWithPath: expand(path)))
                NSLog("InkVaultDebug snapshot %@", path)
            }
        }
    }
}
#endif
