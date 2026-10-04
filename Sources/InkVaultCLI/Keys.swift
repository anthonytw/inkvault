import Age
import ArgumentParser
import Foundation
import InkVault

struct KeysCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "Generate, show and export age identities.",
        subcommands: [KeysGenerate.self, KeysShow.self, KeysExport.self]
    )
}

private struct PublicKeyOutput: Encodable {
    var publicKey: String
    var path: String?
}

struct KeysGenerate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Create a new age identity file (mode 0600) and print its public key.",
        discussion: "Without --out the identity is written to standard output and the public key to standard error."
    )

    @Option(name: .long, help: ArgumentHelp("Where to write the identity. Refuses to overwrite.", valueName: "file"))
    var out: String?

    @OptionGroup var output: OutputOptions

    func run() throws {
        let identity = X25519Identity()
        let text = IdentityFile.render(identity, created: Date())
        let key = identity.recipient.string
        guard let out else {
            print(text, terminator: "")
            printStderr("Public key: \(key)")
            return
        }
        try writeNewSecretFile(text, to: out)
        if output.json {
            try output.emitJSON(PublicKeyOutput(publicKey: key, path: out))
        } else if output.quiet {
            print(key)
        } else {
            print("Wrote \(out)\nPublic key: \(key)")
        }
    }
}

struct KeysShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print the public key (age1...) of an identity file."
    )

    @Argument(help: ArgumentHelp("The identity file.", valueName: "file"))
    var file: String

    @OptionGroup var output: OutputOptions

    func run() throws {
        let key = try readIdentityFile(file).recipient.string
        if output.json { try output.emitJSON(PublicKeyOutput(publicKey: key, path: file)) } else { print(key) }
    }
}

struct KeysExport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Decrypt the vault's passphrase-wrapped key file to an identity file.",
        discussion: """
            Moves a key to another device: the passphrase unlocks keys/<recipient>.key.age and the
            plain identity is written to --out (mode 0600) or standard output. This is one of the
            two commands that print a secret key.
            """
    )

    @OptionGroup var access: AccessOptions

    @Option(name: .long, help: ArgumentHelp("Which key file to export (default: the only one).", valueName: "age1..."))
    var recipient: String?

    @Option(name: .long, help: ArgumentHelp("Where to write the identity. Refuses to overwrite.", valueName: "file"))
    var out: String?

    @OptionGroup var output: OutputOptions

    func run() throws {
        let locked = try Vault.open(at: try access.vaultURL())
        var wanted: X25519Recipient?
        if let recipient {
            do { wanted = try X25519Recipient(string: recipient) } catch {
                throw CLIError("not an age recipient: \(recipient)", code: CLIError.usage)
            }
        } else if try locked.identityFiles().count > 1 {
            throw CLIError("the vault holds several key files; choose one with --recipient", code: CLIError.usage)
        }
        let identity = try access.identityFromKeyFiles(of: locked, recipient: wanted)
        let text = IdentityFile.render(identity, created: Date())
        guard let out else {
            print(text, terminator: "")
            return
        }
        try writeNewSecretFile(text, to: out)
        if output.json {
            try output.emitJSON(PublicKeyOutput(publicKey: identity.recipient.string, path: out))
        } else {
            output.info("Wrote \(out)\nPublic key: \(identity.recipient.string)")
        }
    }
}
