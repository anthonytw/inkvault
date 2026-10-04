import Age
import ArgumentParser
import Foundation
import InkVault

struct VaultCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vault",
        abstract: "Create, inspect, verify and re-key a vault.",
        subcommands: [VaultInit.self, VaultInfo.self, VaultRecipients.self, VaultRewrapResume.self, VaultVerify.self]
    )
}

// MARK: - init

struct VaultInit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create a new vault directory (its name must end in .inkvault).",
        discussion: """
            Every note is encrypted to all --recipient keys. With --store-key the matching identity is
            also written passphrase-wrapped to keys/ (the passphrase comes from the variable named by
            --passphrase-env, else $INKVAULT_PASSPHRASE, else the terminal).
            """
    )

    @Argument(help: ArgumentHelp("The new vault directory.", valueName: "path"))
    var path: String

    @Option(name: .long, help: ArgumentHelp("A recipient public key. Repeatable, at least one.", valueName: "age1..."))
    var recipient: [String] = []

    @Option(name: .long, help: ArgumentHelp("A label per recipient, in order. Repeatable.", valueName: "text"))
    var label: [String] = []

    @Option(name: .customLong("store-key"),
            help: ArgumentHelp("Also store this identity, passphrase-wrapped, in keys/.", valueName: "file"))
    var storeKey: String?

    @Option(name: .customLong("passphrase-env"),
            help: ArgumentHelp("Variable holding the passphrase for --store-key.", valueName: "var"))
    var passphraseEnv: String?

    @Option(name: .customLong("work-factor"),
            help: ArgumentHelp("scrypt work factor of the stored key, 15...18 (each step doubles the cost).",
                               valueName: "n"))
    var workFactor = 18

    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard IdentityFile.writerWorkFactors.contains(workFactor) else {
            throw ValidationError("--work-factor must be in \(IdentityFile.writerWorkFactors)")
        }
        guard !recipient.isEmpty else { throw ValidationError("give at least one --recipient age1...") }
        guard label.isEmpty || label.count == recipient.count else {
            throw ValidationError("give no --label, or one per --recipient (\(recipient.count))")
        }
        if passphraseEnv != nil && storeKey == nil { throw ValidationError("--passphrase-env needs --store-key") }
    }

    func run() throws {
        let recipients = try recipient.map(parseRecipient)
        var stored: (X25519Identity, String)?
        if let storeKey {
            let id = try readIdentityFile(storeKey)
            guard recipients.contains(id.recipient) else {
                throw CLIError.usage("\(storeKey) is not one of the --recipient keys")
            }
            stored = (id, try obtainPassphrase(envName: passphraseEnv, prompt: "New key passphrase: ", confirm: true,
                                                 asError: CLIError.failure))
        }
        let vault = try Vault.create(at: URL(fileURLWithPath: path), recipients: recipients, labels: label)
        var keyFile: String?
        if let (id, pass) = stored {
            keyFile = try vault.writeIdentityFile(id, passphrase: pass, workFactor: workFactor).path
        }
        if output.json {
            try output.emitJSON(InitOutput(path: path, vaultId: vault.vaultId.uuidString.lowercased(),
                                           recipients: recipients.map(\.string), keyFile: keyFile))
        } else {
            output.info("Created \(path)\nVault id: \(vault.vaultId.uuidString.lowercased())")
            if let keyFile { output.info("Stored passphrase-wrapped key: \(keyFile)") }
        }
    }

    private struct InitOutput: Encodable {
        var path: String
        var vaultId: String
        var recipients: [String]
        var keyFile: String?
    }
}

// MARK: - info

struct VaultInfo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show the manifest: id, created, recipients, note count, pending rewrap.",
        discussion: "Works without a key; with an identity (or a scripted passphrase) it also checks the rewrap journal."
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.ifPossible)
        let noteCount = try vault.noteIDs().count
        let keyFiles = try vault.identityFiles().map(\.string)
        let info = Info(
            path: vault.url.path, vaultId: vault.vaultId.uuidString.lowercased(), created: vault.manifest.created,
            recipients: vault.recipients.map { .init(key: $0.key, label: $0.label, added: $0.added) },
            notes: noteCount, keyFiles: keyFiles, pendingRewrap: vault.pendingRewrap,
            journalProblem: vault.journalProblem, unlocked: !vault.isLocked)
        if output.json { try output.emitJSON(info); return }
        print("Vault:          \(info.path)")
        print("Vault id:       \(info.vaultId)")
        print("Created:        \(Format.local(info.created))")
        print("Notes:          \(info.notes)")
        print("Recipients:     \(info.recipients.count)")
        for r in info.recipients {
            print("  \(r.key)  \(r.label.isEmpty ? "(no label)" : r.label)  added \(Format.local(r.added))")
        }
        print("Stored keys:    \(keyFiles.isEmpty ? "none" : "\(keyFiles.count) passphrase-wrapped")")
        print("Pending rewrap: \(info.pendingRewrap ? "YES (run `inkvault vault rewrap-resume`)" : "no")")
        if !info.unlocked {
            print("Journal:        not checked (locked; pass --identity to check)")
        } else if let p = info.journalProblem, info.pendingRewrap {
            print("Journal:        PROBLEM: \(p)")
        } else {
            print("Journal:        ok")
        }
    }

    private struct Info: Encodable {
        struct Recipient: Encodable { var key: String; var label: String; var added: Date }
        var path: String
        var vaultId: String
        var created: Date
        var recipients: [Recipient]
        var notes: Int
        var keyFiles: [String]
        var pendingRewrap: Bool
        var journalProblem: String?
        var unlocked: Bool
    }
}

// MARK: - recipients

struct VaultRecipients: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recipients",
        abstract: "Add or remove a recipient (rewraps every file).",
        subcommands: [RecipientsAdd.self, RecipientsRemove.self]
    )
}

private struct RewrapOutput: Encodable {
    var complete: Bool
    var rewrapped: Int
    var alreadyCurrent: Int
    var failures: [String: String]
}

private func reportRewrap(_ report: Vault.RewrapReport, output: OutputOptions) throws {
    if output.json {
        try output.emitJSON(RewrapOutput(complete: report.isComplete, rewrapped: report.rewrapped.count,
                                         alreadyCurrent: report.alreadyCurrent.count,
                                         failures: report.failures.mapValues { "\($0)" }))
    } else {
        output.info("Rewrapped \(report.rewrapped.count) file(s); \(report.alreadyCurrent.count) already current.")
        if output.verbose { for f in report.rewrapped { print("  rewrapped \(f)") } }
    }
    guard report.isComplete else {
        for (file, why) in report.failures.sorted(by: { $0.key < $1.key }) {
            printError("\(file): \(why)")
        }
        throw CLIError.unhealthy("incomplete: \(report.failures.count) file(s) not rewrapped; fix them, then run "
            + "`inkvault vault rewrap-resume`")
    }
}

struct RecipientsAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Add a recipient and rewrap the vault to it.")

    @Argument(help: ArgumentHelp("The new recipient's public key.", valueName: "age1..."))
    var recipient: String

    @Option(name: .long, help: ArgumentHelp("A label shown in `vault info`.", valueName: "text"))
    var label: String = ""

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let key = try parseRecipient(recipient)
        var vault = try access.openVault(.required)
        try reportRewrap(try vault.addRecipient(key, label: label), output: output)
    }
}

struct RecipientsRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a recipient, rotate the vault secret and rewrap the vault.",
        discussion: "Removing a key does not un-leak what it already decrypted: copies of old files stay readable to it."
    )

    @Argument(help: ArgumentHelp("The recipient to remove.", valueName: "age1..."))
    var recipient: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let key = try parseRecipient(recipient)
        var vault = try access.openVault(.required)
        try reportRewrap(try vault.removeRecipient(key), output: output)
    }
}

struct VaultRewrapResume: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rewrap-resume",
        abstract: "Finish an interrupted recipient change.")

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        var vault = try access.openVault(.required)
        guard vault.pendingRewrap else {
            if output.json {
                try output.emitJSON(RewrapOutput(complete: true, rewrapped: 0, alreadyCurrent: 0, failures: [:]))
            } else {
                output.info("No recipient change is pending.")
            }
            return
        }
        try reportRewrap(try vault.resumeRewrap(), output: output)
    }
}

// MARK: - verify

struct VaultVerify: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Check every file: decrypt, tag, decode, recipient count.",
        discussion: "Exit 0 only if the vault is healthy, 3 otherwise. With -q only problem files are listed."
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let report = vault.verify()
        if output.json {
            try output.emitJSON(Out(report))
        } else {
            for p in report.manifestProblems { print("MANIFEST   vault.json: \(p)") }
            if let j = report.journalProblem { print("JOURNAL    rewrap-journal.json: \(j)") }
            if report.rewrapPending { print("PENDING    a recipient change is unfinished (`inkvault vault rewrap-resume`)") }
            let shown = output.quiet ? report.files.filter { $0.status != .ok } : report.files
            let rows = shown.map { [$0.status.rawValue, $0.path + ($0.detail.map { "  (\($0))" } ?? "")] }
            if !rows.isEmpty { print(Format.table(rows)) }
            let counts = VerifyReport.Status.allCases.compactMap { s in
                report.counts[s].map { "\(s.rawValue): \($0)" }
            }
            print("\(report.files.count) file(s)" + (counts.isEmpty ? "" : " (" + counts.joined(separator: ", ") + ")")
                + (report.isHealthy ? ": healthy" : ": UNHEALTHY"))
        }
        if !report.isHealthy { throw ExitCode(ExitStatus.unhealthy) }
    }

    private struct Out: Encodable {
        struct File: Encodable { var path: String; var status: String; var detail: String? }
        var healthy: Bool
        var manifestProblems: [String]
        var rewrapPending: Bool
        var journalProblem: String?
        var counts: [String: Int]
        var files: [File]

        init(_ r: VerifyReport) {
            healthy = r.isHealthy
            manifestProblems = r.manifestProblems
            rewrapPending = r.rewrapPending
            journalProblem = r.journalProblem
            counts = Dictionary(uniqueKeysWithValues: r.counts.map { ($0.key.rawValue, $0.value) })
            files = r.files.map { File(path: $0.path, status: $0.status.rawValue, detail: $0.detail) }
        }
    }
}
