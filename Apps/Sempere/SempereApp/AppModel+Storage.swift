import Foundation
import Sempere

/// One blob file no revision of its note refers to.
struct UnusedAttachment: Hashable, Sendable, Identifiable {
    var note: UUID
    var title: String
    var fileName: String
    var kind: BlobKind
    /// Size on disk (encrypted, padded).
    var bytes: Int64

    var id: String { "\(note.uuidString.lowercased())/\(fileName)" }
}

/// What a scan for unused attachments found.
struct UnusedAttachmentReport: Hashable, Sendable {
    var items: [UnusedAttachment] = []
    /// Notes left out, because a revision was unreadable or (iCloud Drive)
    /// not all of the note's files are on this device: nothing can be said about them.
    var skippedNotes = 0

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    /// Listing order: biggest first, then by note and name, so equal sizes are stable.
    static func sorted(_ items: [UnusedAttachment]) -> [UnusedAttachment] {
        items.sorted { ($1.bytes, $0.id) < ($0.bytes, $1.id) }
    }
}

/// Sizes of this device's caches (all of it can be rebuilt from the vault).
struct CacheSizes: Equatable, Sendable {
    var drawings: Int64 = 0
    var attachments: Int64 = 0
    var total: Int64 { drawings + attachments }
}

/// *Storage* in Settings (docs/attachments.md §15).
extension AppModel {
    /// Bytes held by the open vault's drawing cache and decrypted-attachment
    /// cache; both zero while no vault is unlocked or before a cache exists.
    func cacheSizes() async -> CacheSizes {
        var sizes = CacheSizes()
        if let cache = drawingCache {
            sizes.drawings = Int64(await Task.detached(priority: .utility) { cache.totalBytes }.value)
        }
        if let cache = blobCache { sizes.attachments = await cache.totalBytes }
        return sizes
    }

    /// Deletes the drawing cache's files and the decrypted attachments. The
    /// vault, the note list's summary cache and every setting stay as they
    /// are; an open canvas redraws what it shows from the vault.
    func clearCaches() async {
        if let cache = drawingCache { await Task.detached(priority: .utility) { cache.removeAll() }.value }
        if let cache = blobCache { await cache.clear() }
        blobCache = nil
    }

    /// Finds blob files that no revision refers to, note by note: each
    /// note's revisions are read and verified (`Vault.blobInventory`; no blob
    /// is decrypted). A note with an unreadable revision, or in iCloud Drive
    /// with files not on this device, is skipped, because a reference could
    /// hide in what was not read. Deleting is `sempere blobs gc`'s job and
    /// follows the 30-day window (format.md §8.1.6); this only reports.
    func scanUnusedAttachments() async throws -> UnusedAttachmentReport {
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        let gen = generation
        let titles = Dictionary(notes.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let cloud = isCloudVault, hooks = cloudHooks, url = vault.url
        let ids = try await offMain(priority: .utility) { try vault.noteIDs() }
        var report = UnusedAttachmentReport()
        for id in ids {
            try ensureCurrent(gen)
            let found: [BlobInventory.File]? = try? await offMain(priority: .utility) { () throws -> [BlobInventory.File]? in
                if cloud { try CloudVault.requireLocal(note: id, vault: url, hooks: hooks) }
                let inventory = try vault.blobInventory(note: id)
                return inventory.isComplete ? inventory.unreferenced : nil
            }
            guard let found else { report.skippedNotes += 1; continue }
            report.items += found.map {
                UnusedAttachment(note: id, title: titles[id] ?? "", fileName: $0.fileName, kind: $0.kind, bytes: $0.bytes)
            }
        }
        try ensureCurrent(gen)
        report.items = UnusedAttachmentReport.sorted(report.items)
        return report
    }
}
