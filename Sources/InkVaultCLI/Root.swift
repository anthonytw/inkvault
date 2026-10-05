import ArgumentParser

struct InkVaultCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inkvault",
        abstract: "Keys, verification, export and recovery for InkVault vaults.",
        discussion: """
            A vault is a folder of age-encrypted note revisions. This tool manages the keys and the
            vault, checks it, exports notes to PDF, SVG or JSON, and recovers data with nothing but
            an identity file.

            Exit codes: 0 ok, 1 failure, 2 usage error, 3 unhealthy verify or incomplete rewrap,
            4 cannot decrypt (wrong key or passphrase), 5 legacy vault (classic key: migrate first with
            `inkvault vault recipients replace OLD NEW`).

            Environment: INKVAULT_VAULT, INKVAULT_IDENTITY, INKVAULT_PASSPHRASE, XDG_STATE_HOME.
            """,
        version: "0.5.0",
        subcommands: [
            KeysCommand.self, VaultCommand.self, NotesCommand.self, ExportCommand.self,
            RecoverCommand.self, CompactCommand.self, SnapshotCommand.self, ImportCommand.self, SearchCommand.self,
            SyncCommand.self,
        ]
    )
}
