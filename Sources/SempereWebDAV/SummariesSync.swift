import Crypto
import Foundation
import Sempere

// MARK: - Published summaries on the server (format.md §12)
//
// The server's `sempere-summaries.sealed` describes what the SERVER holds
// after the sync: one entry per note whose revisions there are exactly the
// local ones (computed from the local vault, which needs the key). It is never
// copied from one side to the other, and only rewritten when its entries
// change; the listing it was last written for is kept in the sync state when
// every note there got an entry, so an unchanged server then costs no request.

extension WebDAVSync {
    func refreshRemoteSummaries(exists: Bool) {
        let name = PublishedSummaries.fileName
        guard exists || options.publishSummaries else { return }
        guard let vault else {
            report.skipped.append(.init(path: name, message: "vault not unlocked (--identity): the server's summaries are not updated"))
            return
        }
        let listing: String
        do {
            listing = SHA256.hash(data: try WebIndex.encode(remoteRevisions)).map { String(format: "%02x", $0) }.joined()
        } catch {
            report.errors.append(.init(path: name, message: Self.describe(error)))
            return
        }
        if exists, state.publishedSummaries == listing { return }
        do {
            var current: [UUID: PublishedSummaries.Entry]?
            if exists, let data = try? client.get([name], maxBytes: PublishedSummaries.maxFileBytes).data {
                current = try? vault.openPublishedSummaries(data)
            }
            let cache = options.summaryCacheDirectory.flatMap { try? SummaryCache(directory: $0, vault: vault) }
            let (entries, _) = try vault.publishedSummaryEntries(for: remoteRevisions, reuse: current ?? [:], cache: cache)
            if current != entries {
                try ensureCollection([])
                guard try client.put([name], try vault.sealPublishedSummaries(entries), condition: .unconditional) else { return }
                report.uploaded.append(name)
            }
            // A note without an entry (unreadable here, or different here) is tried again next run.
            let complete = remoteRevisions.keys.allSatisfy { id in UUID(uuidString: id).map { entries[$0] != nil } ?? true }
            state.publishedSummaries = complete ? listing : nil
        } catch {
            report.errors.append(.init(path: name, message: Self.describe(error)))
        }
    }
}
