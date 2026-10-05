import Foundation

/// Reading and writing a vault that lives in iCloud Drive (docs/io.md,
/// "iCloud Drive"). Files iCloud has not downloaded are placeholders that a
/// plain directory listing skips, so before reading, every vault file is
/// requested and awaited; reads and writes then go through
/// `NSFileCoordinator` so iCloud sees them. Vaults elsewhere skip all of it.
enum CloudVault {
    enum CloudError: Error, Equatable, CustomStringConvertible {
        /// No file finished downloading for `seconds`.
        case timedOut(CloudProgress, seconds: Int)
        /// iCloud refused or failed to download a file.
        case failed(name: String, reason: String)

        var description: String {
            switch self {
            case let .timedOut(progress, seconds):
                return "iCloud Drive did not deliver the vault's files: \(progress.total - progress.downloaded) of "
                    + "\(progress.total) are still not downloaded after \(seconds) seconds without progress. "
                    + "Check that this iPad is online and signed in to iCloud Drive, then try again."
            case let .failed(name, reason):
                return "iCloud Drive could not download “\(name)”: \(reason)"
            }
        }
    }

    /// True when `url` is in iCloud Drive (or another ubiquitous container).
    static func isUbiquitous(_ url: URL) -> Bool {
        if FileManager.default.isUbiquitousItem(at: url) { return true }
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return (try? fresh.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }

    /// Where one vault file stands, read fresh (resource values are cached per URL).
    static func state(of item: CloudScan.Item) -> CloudItemState {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: item.url.path)
        if !exists {
            return fm.fileExists(atPath: CloudPlaceholder.placeholderURL(for: item.url).path) ? .missing : .gone
        }
        var url = item.url
        url.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                         .ubiquitousItemDownloadingErrorKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return .current }
        if let error = values.ubiquitousItemDownloadingError { return .failed(error.localizedDescription) }
        guard values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus else { return .current }
        switch status {
        case .current: return .current
        case .downloaded: return .stale
        default: return .missing
        }
    }

    /// Makes every file of the vault at `url` local before it is read: asks
    /// iCloud for each file that is a placeholder or out of date, then waits
    /// for the missing ones, reporting progress (only when something is
    /// missing). Out-of-date files are requested but not waited for.
    ///
    /// Cancel the calling task to stop waiting (throws `CancellationError`).
    ///
    /// - Returns: false at once, touching nothing, when the vault is not in iCloud.
    /// - Throws: `CloudError.timedOut` when no file completes for
    ///   `stallTimeout`, `CloudError.failed` when iCloud reports an error,
    ///   or the listing error when a folder cannot be read.
    static func download(vault url: URL, stallTimeout: Duration = .seconds(90),
                                     pollInterval: Duration = .milliseconds(400),
                                     progress: @Sendable (CloudProgress) async -> Void) async throws -> Bool {
        guard isUbiquitous(url) else { return false }
        let items = try CloudScan.items(inVault: url)
        var pending: [CloudScan.Item] = []
        for item in items {
            let state = state(of: item)
            if state == .current || state == .gone { continue }
            do { try FileManager.default.startDownloadingUbiquitousItem(at: item.url) } catch {
                throw CloudError.failed(name: item.url.lastPathComponent, reason: error.localizedDescription)
            }
            if state != .stale { pending.append(item) }
        }
        let total = pending.count
        guard total > 0 else { return true }
        await progress(CloudProgress(total: total, downloaded: 0))
        let clock = ContinuousClock()
        var lastProgress = clock.now
        while !pending.isEmpty {
            try await Task.sleep(for: pollInterval)
            var still: [CloudScan.Item] = []
            for item in pending {
                switch state(of: item) {
                case .failed(let reason):
                    throw CloudError.failed(name: item.url.lastPathComponent, reason: reason)
                case .missing:
                    still.append(item)
                case .current, .stale, .gone:
                    break
                }
            }
            if still.count < pending.count { lastProgress = clock.now }
            pending = still
            let now = CloudProgress(total: total, downloaded: total - pending.count)
            await progress(now)
            if !pending.isEmpty, clock.now - lastProgress > stallTimeout {
                throw CloudError.timedOut(now, seconds: Int(stallTimeout.components.seconds))
            }
        }
        return true
    }

    /// Runs `body` inside a coordinated read of `url` (nil: no coordination,
    /// for vaults outside iCloud).
    static func coordinatedRead<T>(_ url: URL?, _ body: () throws -> T) throws -> T {
        guard let url else { return try body() }
        var result: Result<T, any Error>?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &error) { _ in
            result = Result { try body() }
        }
        return try finish(result, error, url)
    }

    /// Runs `body` inside a coordinated write of `url` (nil: no
    /// coordination), so iCloud uploads what `body` adds there.
    static func coordinatedWrite<T>(_ url: URL?, _ body: () throws -> T) throws -> T {
        guard let url else { return try body() }
        var result: Result<T, any Error>?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { _ in
            result = Result { try body() }
        }
        return try finish(result, error, url)
    }

    private static func finish<T>(_ result: Result<T, any Error>?, _ error: NSError?, _ url: URL) throws -> T {
        if let result { return try result.get() }
        throw error ?? CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
}
