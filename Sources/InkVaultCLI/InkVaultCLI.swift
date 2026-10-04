import ArgumentParser

@main
struct InkVaultCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inkvault",
        abstract: "Keys, verification, export and recovery for InkVault vaults.",
        version: "0.1.0"
    )
}
