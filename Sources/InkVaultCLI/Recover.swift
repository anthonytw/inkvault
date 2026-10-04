import Age
import ArgumentParser
import Foundation
import InkVault

struct RecoverCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recover",
        abstract: "Decrypt one revision file and print its JSON (the get-my-data-out command).",
        discussion: """
            Needs only an identity file and the .age file. The inner tag is verified when the vault
            (vault.json) is found in a parent directory and the identity opens it; otherwise
            "UNVERIFIED" is printed to standard error. The JSON goes to standard output exactly as
            `age -d -i KEY FILE | tail -c +38 | gunzip` prints it.
            """
    )

    @Argument(help: ArgumentHelp("The revision file.", valueName: "FILE.age"))
    var file: String

    @Option(name: .customLong("note-id"),
            help: ArgumentHelp("The note id the tag binds to (default: the file's directory name).", valueName: "uuid"))
    var noteId: String?

    @Option(name: .long, help: ArgumentHelp("An age identity file. Repeatable.", valueName: "file"))
    var identity: [String] = []

    @Option(name: .customLong("passphrase-env"),
            help: ArgumentHelp("Variable holding the passphrase of a key file stored in the vault.", valueName: "var"))
    var passphraseEnv: String?

    @Flag(name: .shortAndLong, help: "Do not print the UNVERIFIED notice or other detail.")
    var quiet = false

    @Flag(name: .shortAndLong, help: "Say how the tag was checked.")
    var verbose = false

    func run() throws {
        let url = URL(fileURLWithPath: file)
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw CLIError("cannot read \(file): \(error.localizedDescription)") }

        let access = AccessOptions.make(identity: identity, passphraseEnv: passphraseEnv)
        var ids: [any AgeIdentity] = try access.explicitIdentities()
        let vaultURL = findVault(above: url)
        if ids.isEmpty {
            guard let vaultURL else {
                throw CLIError("no identity: pass --identity FILE", code: CLIError.cannotDecrypt)
            }
            ids = [try access.identityFromKeyFiles(of: try Vault.open(at: vaultURL))]
        }

        var vault: Vault?
        var why = "no vault.json found above the file"
        if let vaultURL {
            do { vault = try Vault.open(at: vaultURL, identities: ids) } catch {
                why = "vault \(vaultURL.path) did not open: \(CLIError.from(error).message)"
            }
        }
        let dirName = url.deletingLastPathComponent().lastPathComponent
        let note = (noteId ?? dirName).lowercased()
        if vault != nil, UUID(uuidString: note) == nil {
            vault = nil
            why = "cannot tell the note id from the path; pass --note-id"
        }

        let result: RecoveredRevision
        do {
            result = try Recovery.decrypt(data, noteId: note, filename: url.lastPathComponent, identities: ids, vault: vault)
        } catch BodyFramingError.tagMismatch {
            throw CLIError("tag mismatch: the file was altered, moved or belongs to another vault (check --note-id)")
        }
        FileHandle.standardOutput.write(result.json)
        if !result.verified {
            if !quiet { printStderr("UNVERIFIED: tag not checked (\(why))") }
        } else if verbose {
            printStderr("tag verified against vault \(vault?.vaultId.uuidString.lowercased() ?? "?")")
        }
    }

    /// The nearest ancestor directory holding `vault.json`.
    private func findVault(above file: URL) -> URL? {
        var dir = file.standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("vault.json").path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}
