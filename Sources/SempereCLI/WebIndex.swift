import ArgumentParser
import Foundation
import Sempere

/// `sempere vault index`: the file listing a static web server cannot give
/// the web viewer (docs/web-viewer.md "Hosting").
struct VaultIndex: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Write sempere-index.json, the note and revision listing the web viewer reads on a static server.",
        discussion: """
            A plain static web server cannot list folders, so the web viewer (web/, docs/web-viewer.md) reads
            this file instead: {"format": "sempere-index/1", "notes": {"<noteId>": ["<revision file>", ...]}}.
            It holds only names that storage already shows (note ids and revision file names), never
            content, and needs no key. Once it exists it stays current: every sempere command that opens the
            vault rewrites it when the listing changed, and sync webdav rewrites the server's copy. A
            WebDAV server needs no index. --out - prints it instead of writing <vault>/sempere-index.json.
            """
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    @Option(name: .long, help: "Where to write the index (default <vault>/sempere-index.json; - for stdout).")
    var out: String?

    func run() throws {
        let vault = try access.openVault(.ifPossible)
        let notes = try vault.webIndexListing()
        let revisions = notes.values.reduce(0) { $0 + $1.count }
        let data = try WebIndex.encode(notes)
        if out == "-" {
            FileHandle.standardOutput.write(data)
            return
        }
        // Into the vault only if it may be written (format.md §7.3: exit 6).
        if out == nil { try vault.requireWritable() }
        let url = out.map { URL(fileURLWithPath: $0) } ?? vault.webIndexURL
        try data.write(to: url, options: .atomic)
        if output.json {
            try output.emitJSON(Report(path: url.path, notes: notes.count, revisions: revisions))
        } else {
            output.info("Wrote \(url.path): \(notes.count) notes, \(revisions) revisions")
        }
    }

    private struct Report: Encodable {
        var path: String
        var notes: Int
        var revisions: Int
    }
}

/// The vaults this run of `sempere` opened, so that `sempere-index.json`
/// is brought up to date once the command is done (`WebIndex`): one
/// rewrite per command, whatever it wrote, and no command can forget it.
final class OpenedVaults: @unchecked Sendable {
    static let shared = OpenedVaults()
    private let lock = NSLock()
    private var urls: [URL] = []

    func record(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        let u = url.standardizedFileURL
        if !urls.contains(u) { urls.append(u) }
    }

    /// Refreshes the index of every vault opened; a failure is a warning,
    /// never the command's exit status.
    func refreshWebIndexes() {
        lock.lock()
        let all = urls
        urls = []
        lock.unlock()
        for url in all {
            do {
                guard let vault = try? Vault.open(at: url) else { continue }
                try vault.refreshWebIndex()
            } catch {
                printStderr("warning: cannot update \(url.appendingPathComponent(WebIndex.fileName).path): "
                    + CLIError.from(error).message)
            }
        }
    }
}
