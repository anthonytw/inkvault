import Age
import ArgumentParser
import Foundation
import InkRender
import InkVault

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

struct KeysPaper: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paper",
        abstract: "Write a printable PDF recovery kit for a key (QR code, checked text, instructions).",
        discussion: """
            The kit holds the age identity as a QR code and as text in numbered lines with a checksum
            each, the public key, the vault id and name (with --vault), and step-by-step recovery with
            stock tools (age, gunzip, jq) and with inkvault. THE PRINTED SHEET IS THE KEY: store it
            offline. The PDF is written with mode 0600 and never overwrites a file; delete it once
            printed.

            --passphrase prints the passphrase-wrapped key file (age scrypt, armored) instead of the
            plain key: the vault's keys/<recipient>.key.age when it stores one for this key (its
            passphrase is checked), else a new one locked with a passphrase you choose. Such a sheet
            is useless without the passphrase.

            Without --identity the key comes from the vault's stored key file (needs --vault and its
            passphrase).
            """
    )

    @Option(name: .long, help: ArgumentHelp("Where to write the PDF. Refuses to overwrite.", valueName: "file.pdf"))
    var out: String

    @Flag(name: .long, help: "Print the passphrase-wrapped key file instead of the plain key.")
    var passphrase = false

    @Option(name: .customLong("work-factor"),
            help: ArgumentHelp("scrypt work factor for a new passphrase-wrapped key (15...18).", valueName: "n"))
    var workFactor = 18

    @Option(name: .long, help: ArgumentHelp("Paper size: letter or a4.", valueName: "size"))
    var paper = "letter"

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard ["letter", "a4"].contains(paper.lowercased()) else { throw ValidationError("--paper is letter or a4") }
        guard IdentityFile.writerWorkFactors.contains(workFactor) else {
            throw ValidationError("--work-factor must be between 15 and 18")
        }
    }

    func run() throws {
        let explicit = try access.explicitIdentities()
        guard explicit.count <= 1 else { throw CLIError.usage("give one --identity for a recovery kit") }
        let hasVault = access.vault != nil || !(Env.vars["INKVAULT_VAULT"] ?? "").isEmpty
        let locked = hasVault ? try Vault.open(at: try access.vaultURL()) : nil

        var identity = explicit.first
        let secret: RecoveryKit.Secret
        if passphrase {
            let stored = try locked?.identityFiles() ?? []
            var source: X25519Recipient?
            if let identity {
                source = stored.first { $0 == identity.recipient }
            } else if stored.count == 1 {
                source = stored[0]
            } else {
                throw CLIError.usage(stored.isEmpty
                    ? "no key: pass --identity FILE (or --vault V holding a stored key file)"
                    : "the vault holds several key files; choose one with --identity")
            }
            let pass = try obtainPassphrase(
                envName: access.passphraseEnv,
                prompt: source != nil ? "Passphrase of the vault's key file: " : "New passphrase for the kit: ",
                confirm: source == nil, asError: source == nil ? CLIError.usage : CLIError.cannotDecrypt)
            let wrapped: Data
            if let source, let locked {
                let opened = try locked.readIdentityFile(recipient: source, passphrase: pass)
                if identity == nil { identity = opened }
                wrapped = try locked.identityFileData(recipient: source)
            } else if let identity {
                guard !pass.isEmpty else { throw CLIError.usage("the passphrase is empty") }
                let text = IdentityFile.render(identity, created: Date())
                wrapped = try AgeFile.encrypt(Data(text.utf8), to: [ScryptRecipient(passphrase: pass,
                                                                                  workFactor: workFactor)])
            } else {
                throw CLIError.usage("no key: pass --identity FILE")
            }
            let armored = Armor.isArmored(wrapped) ? wrapped : Armor.encode(wrapped)
            // The sheet must open with this passphrase to this key, or it is worthless.
            let check = try AgeFile.decrypt(armored, with: [ScryptIdentity(passphrase: pass)])
            guard let identity, try IdentityFile.parse(String(decoding: check, as: UTF8.self)).recipient
                    == identity.recipient else {
                throw CLIError.failure("the passphrase-wrapped key does not open to this key")
            }
            secret = .passphraseWrapped(String(decoding: armored, as: UTF8.self))
        } else {
            if identity == nil, let locked { identity = try access.identityFromKeyFiles(of: locked) }
            guard let identity else {
                throw CLIError.cannotDecrypt("no key: pass --identity FILE (or --vault V holding a stored key file)")
            }
            secret = .identity(identity.string)
        }
        guard let identity else { throw CLIError.cannotDecrypt("no key") }

        var info: RecoveryKit.VaultInfo?
        if let locked {
            guard locked.recipients.contains(where: { $0.key == identity.recipient.string }) else {
                throw CLIError.cannotDecrypt("this key is not a recipient of the vault (\(identity.recipient.string))")
            }
            var name = locked.url.lastPathComponent
            if name.hasSuffix(".inkvault") { name.removeLast(".inkvault".count) }
            info = .init(name: name, id: locked.vaultId.uuidString.lowercased(), created: locked.manifest.created,
                         recipientCount: locked.recipients.count)
        }
        var kit = RecoveryKit(secret: secret, recipient: identity.recipient.string, vault: info, printed: Date())
        if paper.lowercased() == "a4" {
            kit.pageWidth = 595.28
            kit.pageHeight = 841.89
        }
        let code = try kit.qrCode()
        try writeNewSecretFile(try kit.pdf(), to: out)

        let variant = passphrase ? "passphrase" : "plain"
        if output.json {
            struct Out: Encodable {
                var path: String; var variant: String; var publicKey: String; var vaultId: String?
                var qrVersion: Int; var qrErrorCorrection: String; var lines: Int
            }
            try output.emitJSON(Out(path: out, variant: variant, publicKey: identity.recipient.string,
                                    vaultId: info?.id, qrVersion: code.version,
                                    qrErrorCorrection: code.errorCorrection == .quartile ? "Q" : "M",
                                    lines: kit.lines.count))
        } else {
            output.info("Wrote \(out) (2 pages, \(variant) key; QR version \(code.version), "
                        + "\(kit.lines.count) checked lines)")
            if !passphrase && !output.quiet {
                printStderr("The PDF holds your secret key: print it, then delete the file (it is not encrypted).")
            }
        }
    }
}

/// Creates `path` with mode 0600 holding `data`, refusing to overwrite.
func writeNewSecretFile(_ data: Data, to path: String) throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    if fd < 0 {
        if errno == EEXIST { throw CLIError.failure("refusing to overwrite \(path)") }
        throw CLIError.failure("cannot create \(path): \(String(cString: strerror(errno)))")
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do { try handle.write(contentsOf: data) } catch {
        throw CLIError.failure("cannot write \(path): \(error.localizedDescription)")
    }
}
