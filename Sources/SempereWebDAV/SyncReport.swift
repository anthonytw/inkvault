import Foundation

/// What one sync did, or with `dryRun` what it would do.
public struct SyncReport: Codable, Hashable, Sendable {
    /// A deletion and the side it happened on.
    public struct Deletion: Codable, Hashable, Sendable {
        /// `"local"` or `"remote"`.
        public var side: String
        /// Path relative to the vault root.
        public var path: String
    }

    /// A mutable file that changed on both sides.
    public struct Conflict: Codable, Hashable, Sendable {
        public var path: String
        /// The remote version, kept next to the local one as this file in the
        /// vault root; nil in a dry run or when an identical copy already existed.
        public var remoteCopy: String?
        public var detail: String
    }

    /// A path and a one-line message.
    public struct Issue: Codable, Hashable, Sendable {
        public var path: String
        public var message: String
    }

    public var dryRun = false
    /// Paths (relative to the vault root) sent to the server.
    public var uploaded: [String] = []
    /// Paths written locally.
    public var downloaded: [String] = []
    public var deleted: [Deletion] = []
    public var conflicts: [Conflict] = []
    public var errors: [Issue] = []
    /// Things that could not be decided and were left alone (e.g. a deletion
    /// that could not be checked against the compaction rules).
    public var skipped: [Issue] = []
    /// Remote entries whose names are not vault files; never downloaded.
    public var ignored: [String] = []
    /// Push-only runs: files the server holds that the local vault does not
    /// and that no compaction explains (never synced before, e.g. injected by
    /// the server). Listed whether or not `--delete-extraneous` removed them.
    public var extraneous: [String] = []
    /// Push-only runs: mutable files (`vault.json`, `rewrap-journal.json`)
    /// whose different server copy was replaced by the local one. Also in `uploaded`.
    public var overwritten: [String] = []

    public init(dryRun: Bool = false) { self.dryRun = dryRun }

    /// `text` with control characters escaped as `\u{XX}`, so a name or
    /// header chosen by the server cannot drive the terminal it is printed on.
    static func printable(_ text: String) -> String {
        var out = ""
        for u in text.unicodeScalars {
            if u.properties.generalCategory == .control {
                out += "\\u{" + String(u.value, radix: 16, uppercase: true) + "}"
            } else {
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// True when nothing was transferred, deleted or reported.
    public var isEmpty: Bool {
        uploaded.isEmpty && downloaded.isEmpty && deleted.isEmpty && conflicts.isEmpty && errors.isEmpty
            && extraneous.isEmpty && overwritten.isEmpty
    }
}
