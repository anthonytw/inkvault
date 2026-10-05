import Foundation

/// Loading a vault's notes from iCloud Drive without waiting for all of them.
///
/// Each pass lists the notes' files, sorts the notes into *ready* (every file
/// local, so the summary can be read now) and *pending* (some file is still a
/// placeholder), and asks iCloud for the pending notes' files: the note the
/// user opened first, then the rest, at most `window` notes at a time, so a
/// note opened later is not queued behind hundreds of others. The model keeps
/// passing until nothing is pending (`AppModel.startCloudSync`).
enum ProgressiveLoad {
    /// How many pending notes have their downloads requested at once.
    static let defaultWindow = 16

    struct Pass: Equatable, Sendable {
        /// Every note directory found, in listing order.
        var all: [UUID] = []
        /// Notes whose files are all local.
        var ready: [UUID] = []
        /// Notes with at least one file still to download.
        var pending: [UUID] = []
        /// Notes iCloud reported an error for, with the reason (also in `pending`).
        var failures: [UUID: String] = [:]
        /// Notes whose folder lists no revision file at all (also in `pending`):
        /// iCloud has not listed its contents yet. A note always has at least
        /// one revision, so an empty folder is never an empty note.
        var unlisted: [UUID] = []
        /// Revision files listed, and how many of them are local.
        var files = 0
        var localFiles = 0
    }

    /// One pass over the vault at `root`. Requests downloads (idempotent) for
    /// up to `window` pending notes, `priority` first and notes with a
    /// download error last, and refreshes
    /// out-of-date local files of ready notes (not waited for).
    ///
    /// - Throws: when a folder cannot be listed.
    static func pass(vault root: URL, priority: UUID? = nil, window: Int = defaultWindow,
                     hooks: CloudVault.Hooks = .live) throws -> Pass {
        var pass = Pass()
        var pendingItems: [UUID: [CloudScan.Item]] = [:]
        for group in try CloudScan.noteGroups(inVault: root) {
            guard let id = group.id else { continue }
            pass.all.append(id)
            var missing: [CloudScan.Item] = []
            var stale: [CloudScan.Item] = []
            pass.files += group.items.count
            if group.items.isEmpty {
                // Not listed yet: ask for the folder itself, which makes iCloud
                // list (and fetch) what is in it.
                pass.unlisted.append(id)
                missing.append(CloudScan.Item(url: group.url, placeholder: false))
            }
            for item in group.items {
                switch hooks.state(item) {
                case .missing: missing.append(item)
                case .stale: stale.append(item)
                case .failed(let reason): missing.append(item); pass.failures[id] = reason
                case .current, .gone: pass.localFiles += 1
                }
            }
            pass.localFiles += stale.count
            if missing.isEmpty { pass.ready.append(id) } else {
                pass.pending.append(id)
                pendingItems[id] = missing
            }
            for item in stale { try? hooks.request(item) }
        }
        // Notes iCloud failed on go last, so they cannot hold the window
        // (and every other note) hostage; they are still retried.
        var order = pass.pending.filter { pass.failures[$0] == nil } + pass.pending.filter { pass.failures[$0] != nil }
        if let priority, let i = order.firstIndex(of: priority) { order.insert(order.remove(at: i), at: 0) }
        for id in order.prefix(max(1, window)) {
            for item in pendingItems[id] ?? [] {
                do { try hooks.request(item) } catch { pass.failures[id] = "\(error)" }
            }
        }
        return pass
    }
}
