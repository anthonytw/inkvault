import Foundation
import Sempere

/// Attachments of the open vault (docs/attachments.md §4, §13): the cache of
/// decrypted blobs the canvas draws from, the lazy, per-kind iCloud download
/// of a note's `att/`, and pasting copied items.
extension AppModel {
    /// The open vault's blob cache, created on first use; nil while no vault
    /// is unlocked. Each blob is fetched through the vault's checks, and in
    /// iCloud Drive downloaded first (only that file) and read under
    /// coordination with `CloudVault.requireBlob`.
    func attachmentCache() -> BlobCache? {
        if let blobCache { return blobCache }
        guard let vault, phase == .unlocked else { return nil }
        let cloud = isCloudVault, hooks = cloudHooks, stall = cloudStallTimeout, poll = cloudPollInterval
        BlobCache.purgeStale(in: blobCacheFolder)
        let cache = BlobCache(root: blobCacheFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)) {
            note, ref, destination in
            try await Self.fetchBlob(ref, of: note, from: vault, to: destination, cloud: cloud, hooks: hooks,
                                     stallTimeout: stall, pollInterval: poll)
        }
        blobCache = cache
        return cache
    }

    /// Writes the verified content of blob `ref` of `note` to `destination`.
    nonisolated static func fetchBlob(_ ref: BlobRef, of note: UUID, from vault: Vault, to destination: URL, cloud: Bool,
                                      hooks: CloudVault.Hooks, stallTimeout: Duration,
                                      pollInterval: Duration) async throws {
        let name = try vault.blobFileName(for: ref)
        if cloud {
            try await CloudVault.downloadBlob(note: note, fileName: name, vault: vault.url, hooks: hooks,
                                              stallTimeout: stallTimeout, pollInterval: pollInterval)
        }
        try await Task.detached(priority: .userInitiated) {
            try CloudVault.coordinatedRead(cloud ? vault.url : nil) {
                if cloud { try CloudVault.requireBlob(note: note, fileName: name, vault: vault.url, hooks: hooks) }
                try BlobCache.writeFile(destination) { write in
                    try vault.streamBlob(note: note, ref) { try write($0) }
                }
            }
        }.value
    }

    /// Deletes the decrypted attachments and forgets copied items (the vault
    /// closed, or changed under them).
    func dropAttachments() {
        if let cache = blobCache { Task { await cache.clear() } }
        blobCache = nil
        itemClipboard.clear()
    }

    /// Asks iCloud for the `image` and `pdf` blobs of `items` (a page of
    /// `note` was shown), without waiting; other kinds come when used
    /// (docs/attachments.md §4). No-op outside iCloud Drive.
    func prefetchBlobs(note: UUID, items: [Item]) {
        guard isCloudVault, let vault else { return }
        let refs = BlobFetchPolicy.prefetch(for: items)
        guard !refs.isEmpty else { return }
        let hooks = cloudHooks
        Task.detached(priority: .utility) {
            let names = refs.compactMap { try? vault.blobFileName(for: $0) }
            CloudVault.requestBlobs(note: note, fileNames: names, vault: vault.url, hooks: hooks)
        }
    }

    /// Makes the blob `ref` of `note` local (iCloud Drive), waiting for it.
    func ensureBlobLocal(_ ref: BlobRef, of note: UUID) async throws {
        guard isCloudVault, let vault else { return }
        let name = try vault.blobFileName(for: ref)
        try await CloudVault.downloadBlob(note: note, fileName: name, vault: vault.url, hooks: cloudHooks,
                                          stallTimeout: cloudStallTimeout, pollInterval: cloudPollInterval)
    }

    /// Pastes the copied items onto `page` of the editor's note, through
    /// `actions` (one delta, one undo step). Blobs from another note are
    /// downloaded and copied first.
    @discardableResult
    func pasteItems(into page: UUID, with actions: ItemActions) async -> [Item] {
        guard let entry = itemClipboard.entry else { return [] }
        let offset = itemClipboard.nextOffset(samePage: entry.note == actions.editor.noteID
                                              && actions.editor.items(on: page).contains { $0.id == entry.items.first?.id })
        let cloud = isCloudVault, hooks = cloudHooks, stall = cloudStallTimeout, poll = cloudPollInterval
        let vault = self.vault
        do {
            return try await actions.paste(entry, on: page, offset: offset) { ref in
                guard cloud, let vault else { return }
                let name = try vault.blobFileName(for: ref)
                try await CloudVault.downloadBlob(note: entry.note, fileName: name, vault: vault.url, hooks: hooks,
                                                  stallTimeout: stall, pollInterval: poll)
            }
        } catch {
            errorMessage = "Could not paste: \(error)"
            return []
        }
    }
}

extension AppModel {
    /// What the canvas's item layer draws from.
    var itemLayerSource: ItemLayerSource {
        ItemLayerSource(cache: attachmentCache(), prefetch: { [weak self] note, items in
            self?.prefetchBlobs(note: note, items: items)
        })
    }

    /// Copy and paste of items for the canvas.
    var itemCommands: ItemCommands {
        ItemCommands(copy: { [weak self] items, note in self?.itemClipboard.copy(items, from: note) },
                     canPaste: { [weak self] in self?.itemClipboard.entry != nil },
                     paste: { [weak self] page, actions in await self?.pasteItems(into: page, with: actions) ?? [] })
    }
}
