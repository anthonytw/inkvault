import Crypto
import Foundation
import InkVault

/// What the last successful sync left behind, so the next one can tell which
/// side changed. It lives outside the vault (default `$XDG_STATE_HOME/inkvault/sync/`)
/// and holds no secrets: file names, hashes, ETags and snapshot coverage.
struct SyncState: Codable, Equatable {
    /// Last-synced version of a mutable file.
    struct MutableRecord: Codable, Equatable {
        /// SHA-256 (hex) of the content both sides had.
        var hash: String
        /// The remote ETag (else Last-Modified) at that time.
        var stamp: String?
    }

    /// A revision file both sides had.
    struct FileRecord: Codable, Equatable {
        /// For a snapshot, what it covered, so a later compaction that removed it can be checked.
        var included: Included?
    }

    var version = 1
    var mutable: [String: MutableRecord] = [:]
    /// Keyed `<noteId>/<file name>`.
    var files: [String: FileRecord] = [:]

    /// The default state file for one (remote, local vault) pair.
    static func defaultURL(remote: URL, vault: URL,
                                  environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let base: URL
        if let xdg = environment["XDG_STATE_HOME"], xdg.hasPrefix("/") {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = home.appendingPathComponent(".local/state", isDirectory: true)
        }
        let key = remote.absoluteString + "\n" + vault.standardizedFileURL.path
        let id = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("inkvault/sync/\(id).json")
    }

    /// Nil when there is no state file; throws when it exists but is unreadable.
    static func load(_ url: URL) throws -> SyncState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let state = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw WebDAVError.io("sync state \(url.path) has version \(state.version)") }
        return state
    }

    func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try LocalFS.write(try enc.encode(self), to: url, replacing: true)
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
