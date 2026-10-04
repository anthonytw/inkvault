import Foundation

/// Vaults in iCloud Drive (docs/io.md): fetch placeholder files before
/// reading, show progress, and let the user cancel the wait.
extension AppModel {
    /// The URL to coordinate vault reads and writes on: the vault folder
    /// when it is in iCloud Drive, nil otherwise.
    var coordinationURL: URL? {
        isCloudVault ? vaultURL : nil
    }

    /// Downloads every file of the vault at `url` that iCloud Drive holds
    /// only as a placeholder, publishing `cloudProgress` while it waits.
    /// Security-scoped access to `url` must be active.
    ///
    /// - Returns: whether the vault is in iCloud Drive (false: nothing done).
    /// - Throws: `CancellationError` after `cancelCloudDownload()`;
    ///   `CloudVault.CloudError` on a stall or download error.
    func fetchFromICloud(_ url: URL) async throws -> Bool {
        cloudTask?.cancel()
        let task = Task.detached(priority: .userInitiated) {
            try await CloudVault.download(vault: url) { progress in await self.showCloudProgress(progress) }
        }
        cloudTask = task
        defer {
            if cloudTask == task {
                cloudTask = nil
                cloudProgress = nil
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Stops waiting for iCloud; the open or reload that waited fails
    /// silently with `CancellationError`.
    func cancelCloudDownload() {
        cloudTask?.cancel()
        cloudTask = nil
        cloudProgress = nil
    }

    private func showCloudProgress(_ progress: CloudProgress) {
        guard cloudTask != nil else { return }
        cloudProgress = progress
    }
}
