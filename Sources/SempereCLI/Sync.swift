import ArgumentParser
import Foundation
import Sempere
import SempereWebDAV

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Mirror a vault with a remote store.",
        subcommands: [SyncWebDAVCommand.self]
    )
}

struct SyncWebDAVCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "webdav",
        abstract: "Sync a vault with a WebDAV folder (no server logic needed).",
        discussion: """
            Uploads revision files the server lacks and downloads the ones the vault lacks; files under
            notes/ are write-once and never overwritten on either side. Each note's attachment blobs
            (notes/<id>/att/) are synced the same way, streamed from and to disk; an interrupted blob
            download continues on the next run. A blob dropped on one side is deleted on the other
            only if no revision of its note references it there (format.md §8.1.6), else copied back. vault.json and
            rewrap-journal.json are compared with the last sync; when both sides changed, both copies
            are kept (vault.conflict-<device>-<time>.json) and the exit code is 3. A deletion
            follows only when compaction allows it, which needs the vault unlocked (--identity, or
            --passphrase-env). Only https is accepted, plus http to localhost. The password
            is never taken from the command line: --password-env names the variable (default
            SEMPERE_WEBDAV_PASSWORD). The vault folder may be new or empty for a first pull.

            A remote vault.json whose device list changed without a valid tag (format.md §2.1) is never
            copied over the local one: it is reported as rejected and the exit code is 6 (checking a changed
            list needs the key: pass --identity or --passphrase-env).

            Exit codes: 0 ok, 1 errors (listed), 3 conflicts to resolve, 6 a rejected vault.json.
            """
    )

    @Argument(help: ArgumentHelp("The WebDAV collection holding the vault (https://host/path/).", valueName: "url"))
    var url: String

    @Option(name: .long, help: ArgumentHelp("User name for HTTP Basic auth.", valueName: "name"))
    var user: String?

    @Option(name: .customLong("password-env"),
            help: ArgumentHelp("Name of the environment variable holding the password.", valueName: "var"))
    var passwordEnv: String?

    @Option(name: .long, help: ArgumentHelp("Name for this device in conflict file names.", valueName: "name"))
    var device: String?

    @Option(name: .customLong("max-blob-mib"),
            help: ArgumentHelp("Largest attachment blob file to transfer, in MiB (default 1088: 1 GiB of content plus padding).",
                               valueName: "n"))
    var maxBlobMiB: Int?

    @Flag(name: .customLong("dry-run"), help: "Only list what would be transferred or deleted.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        guard let remote = URL(string: url) else { throw CLIError.usage("not a URL: \(url)") }
        var options = WebDAVSyncOptions(dryRun: dryRun)
        if let maxBlobMiB {
            guard (1...(1 << 20)).contains(maxBlobMiB) else { throw CLIError.usage("--max-blob-mib must be 1 to 1048576") }
            options.maxBlobBytes = maxBlobMiB << 20
        }
        var credentials: WebDAVCredentials?
        if let user {
            let varName = passwordEnv ?? "SEMPERE_WEBDAV_PASSWORD"
            guard let password = Env.vars[varName] else {
                throw CLIError.usage("environment variable \(varName) is not set (it must hold the WebDAV password)")
            }
            credentials = WebDAVCredentials(user: user, password: password)
        } else if passwordEnv != nil {
            throw CLIError.usage("--password-env needs --user")
        }
        let client: WebDAVClient
        do { client = try WebDAVClient(baseURL: remote, credentials: credentials) } catch {
            throw CLIError.usage(CLIError.from(error).message)
        }

        let dir = try access.vaultURL()
        OpenedVaults.shared.record(dir)   // a first pull creates the vault here
        let hasManifest = FileManager.default.fileExists(atPath: dir.appendingPathComponent("vault.json").path)
        let vault = hasManifest ? try access.openVault(.ifPossible) : nil
        options.deviceLabel = device ?? ProcessInfo.processInfo.hostName
        let sync = WebDAVSync(
            directory: dir, vault: vault, client: client,
            stateURL: WebDAVSync.defaultStateURL(remote: remote, vault: dir, environment: Env.vars),
            options: options)
        let report = try sync.run()

        if output.json {
            try output.emitJSON(report)
        } else {
            printReport(report)
        }
        if !report.errors.isEmpty { throw ExitCode(ExitStatus.failure) }
        if !report.rejected.isEmpty { throw ExitCode(ExitStatus.untrustedRecipients) }
        if !report.conflicts.isEmpty { throw ExitCode(ExitStatus.unhealthy) }
    }

    private func printReport(_ r: SyncReport) {
        let verb = r.dryRun ? "would " : ""
        if !output.quiet {
            for p in r.uploaded { print("\(verb)upload    \(p)") }
            for p in r.downloaded { print("\(verb)download  \(p)") }
            for d in r.deleted { print("\(verb)delete    \(d.path) (\(d.side))") }
            for s in r.skipped where output.verbose { print("skipped    \(s.path): \(s.message)") }
            for p in r.ignored where output.verbose { print("ignored    \(p)") }
        }
        for c in r.conflicts {
            printStderr("conflict: \(c.path): \(c.detail)" + (c.remoteCopy.map { "; server copy kept as \($0)" } ?? ""))
        }
        for e in r.errors { printStderr("error: \(e.path): \(e.message)") }
        for e in r.rejected { printStderr("rejected: \(e.path): \(e.message); the local copy is kept") }
        output.info("\(r.dryRun ? "dry run: " : "")\(r.uploaded.count) uploaded, \(r.downloaded.count) downloaded, "
                    + "\(r.deleted.count) deleted, \(r.conflicts.count) conflicts, \(r.errors.count) errors"
                    + (r.skipped.isEmpty ? "" : ", \(r.skipped.count) skipped (-v)"))
    }
}
