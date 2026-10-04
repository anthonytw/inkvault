import Age
import ArgumentParser
import Foundation
import InkVault

struct RecoverCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recover",
        abstract: "Decrypt one revision file and print its JSON (the get-my-data-out command).",
        discussion: """
            Needs only an identity file and the .age file. The inner tag is verified when a vault is
            known (--vault, else a vault.json found in a parent directory of the file, else
            $INKVAULT_VAULT) and the identity opens it; otherwise "UNVERIFIED" is printed to standard
            error. The JSON goes to standard output exactly as
            `age -d -i KEY FILE | tail -c +38 | gunzip` prints it.
            """
    )

    @Argument(help: ArgumentHelp("The revision file.", valueName: "FILE.age"))
    var file: String

    @Option(name: .customLong("note-id"),
            help: ArgumentHelp("The note id the tag binds to (default: the file's directory name).", valueName: "uuid"))
    var noteId: String?

    @Flag(name: .customLong("no-verify"),
          help: "On a tag mismatch print the body anyway, with a warning, and exit 3 (for damaged vaults).")
    var noVerify = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if output.json { throw ValidationError("recover prints the revision's own JSON; --json does not apply") }
    }

    func run() throws {
        let url = URL(fileURLWithPath: file)
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw CLIError.failure("cannot read \(file): \(error.localizedDescription)")
        }

        var ids: [any AgeIdentity] = try access.explicitIdentities()
        let vaultURL = access.vault.map { URL(fileURLWithPath: $0) } ?? findVault(above: url)
            ?? Env.vars["INKVAULT_VAULT"].map { URL(fileURLWithPath: $0) }
        if ids.isEmpty {
            guard let vaultURL else { throw CLIError.cannotDecrypt("no key: pass --identity FILE") }
            ids = [try access.identityFromKeyFiles(of: try Vault.open(at: vaultURL))]
        }

        var vault: Vault?
        var why = "no vault found: pass --vault or keep the file inside its vault"
        if let vaultURL {
            do { vault = try Vault.open(at: vaultURL, identities: ids) } catch {
                why = "vault \(vaultURL.path) did not open: \(CLIError.from(error).message)"
            }
        }
        let note = (noteId ?? url.deletingLastPathComponent().lastPathComponent).lowercased()
        if vault != nil, UUID(uuidString: note) == nil {
            vault = nil
            why = "cannot tell the note id from the path; pass --note-id"
        }

        let result: RecoveredRevision
        do {
            result = try Recovery.decrypt(data, noteId: note, filename: url.lastPathComponent, identities: ids,
                                          vault: vault, onMismatch: noVerify ? .allowMismatch : .fail)
        } catch BodyFramingError.tagMismatch {
            throw CLIError.failure("tag mismatch: the file was altered, moved or belongs to another vault "
                + "(check --note-id; use --no-verify to print the body anyway for damaged vaults)")
        }
        FileHandle.standardOutput.write(result.json)
        if result.tagMismatch {
            printStderr("WARNING: tag mismatch, content may be tampered or from another vault")
            throw ExitCode(ExitStatus.unhealthy)
        }
        if !result.verified {
            if !output.quiet { printStderr("UNVERIFIED: tag not checked (\(why))") }
        } else if output.verbose {
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
